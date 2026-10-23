import AVFoundation
import CloudTranscription
import Foundation
import os
import Presets
import TranscriptionCore

/// One self-hosted sentence-translation session: mic -> silence chunking
/// -> self-hosted ASR -> AI translation -> bilingual list, with optional
/// TTS readout of each translation.
///
/// The pipeline is three tasks by design. The chunker task only ever does
/// synchronous work (RMS + WAV writes), so it never stalls the capture
/// stream, which drops audio when its ~1s buffer fills. An ASR task
/// drains completed chunks and appends pairs in spoken order, while a
/// separate translation task fills translations in the same order, so
/// originals show up as soon as recognition finishes instead of waiting
/// behind the previous translation. If processing falls behind, the lag
/// grows instead of audio being lost. A failed chunk never kills the
/// session: real ASR failures surface as a status line, translation
/// failures attach to their pair, and the next chunk still runs.
/// Empty ASR results (silence, too short, noise) are skipped silently:
/// they are not failures. While TTS is reading a translation aloud,
/// mic buffers are dropped, so the speaker output is not re-transcribed
/// into a repeat of earlier content.
@MainActor
@Observable
final class SelfHostedTranslationSession {
    struct Pair: Identifiable {
        let id = UUID()
        let original: String
        var translation: String?
        var isTranslating = true
        var error: String?
    }

    enum Language: String, CaseIterable {
        case chinese = "zh"
        case japanese = "ja"
        case english = "en"

        var displayName: String {
            switch self {
            case .chinese: "中文"
            case .japanese: "日语"
            case .english: "英语"
            }
        }

        var translationName: String {
            switch self {
            case .chinese: "Chinese"
            case .japanese: "Japanese"
            case .english: "English"
            }
        }

        var ttsCode: String {
            switch self {
            case .chinese: "zh-CN"
            case .japanese: "ja-JP"
            case .english: "en-US"
            }
        }
    }

    var isRunning = false
    var pairs: [Pair] = []
    var status = ""
    var sourceLanguage: Language = .chinese
    var targetLanguage: Language = .japanese {
        didSet {
            ttsVoiceID = ServerTTSVoiceSelection.voiceID(forLanguageCode: targetLanguage.rawValue)
        }
    }
    var asrModelName = "sensevoice"
    var ttsEnabled = true
    /// Server voices offered by GET /v1/voices (empty until fetched, or
    /// when the server is unreachable: the picker then shows only the
    /// system default and readout keeps working).
    var serverVoices: [ServerTTSVoice] = []
    /// Non-nil when the last voice-list fetch failed; shown as a footnote
    /// under the voice picker. Never blocks readout.
    var serverVoicesError: String?
    /// The server voice id chosen for the current target language, or nil
    /// for the system default voice. Persisted per language.
    var ttsVoiceID: String? {
        didSet {
            ServerTTSVoiceSelection.setVoiceID(ttsVoiceID, forLanguageCode: targetLanguage.rawValue)
        }
    }
    var summary: String?
    var isSummarizing = false
    private(set) var startedAt: Date?

    var hasSelfHostedKey: Bool {
        guard let key = SelfHostedTranscriptionConfig.apiKey else { return false }
        return !key.isEmpty
    }

    private let aiService: AIService
    private let store = TranslationSessionStore()
    private let logger = Logger(category: .selfHostedTranslation)
    private let synthesizer = AVSpeechSynthesizer()
    /// Server-voice playback queue: sentences play in order, never
    /// overlapping, mirroring AVSpeechSynthesizer's own queueing.
    private let serverPlayer = AVQueuePlayer()
    private var ttsTempFiles: [URL] = []
    private var isServerAudioPlaying: Bool { serverPlayer.timeControlStatus == .playing }
    private var capture: StreamingAudioCapture?
    private var chunkerTask: Task<Void, Never>?
    private var asrTask: Task<Void, Never>?
    private var translationTask: Task<Void, Never>?
    private var sessionWAVURL: URL?

    init(aiService: AIService) {
        self.aiService = aiService
        ttsVoiceID = ServerTTSVoiceSelection.voiceID(forLanguageCode: targetLanguage.rawValue)
    }

    /// Fetches the server voice list for the picker. Never throws to the
    /// UI: on failure the picker just shows the system default.
    func refreshServerVoices() async {
        guard let apiKey = SelfHostedTranscriptionConfig.apiKey, !apiKey.isEmpty else { return }
        let client = ServerTTSClient(baseURL: SelfHostedTranscriptionConfig.serverURL, apiKey: apiKey)
        do {
            serverVoices = try await client.fetchVoices()
            serverVoicesError = nil
        } catch is CancellationError {
            // View dismissed mid-fetch: not a failure.
        } catch {
            logger.logError("自建翻译：服务器声音列表加载失败：\(error.localizedDescription)")
            serverVoicesError = "服务器声音加载失败"
        }
    }

    func start() async {
        guard !isRunning else { return }
        guard hasSelfHostedKey else {
            status = "先配置自建服务器的 API Key"
            return
        }
        pairs = []
        summary = nil
        startedAt = Date()
        status = "正在聆听…"
        isRunning = true

        let sessionWAV = FileManager.default.temporaryDirectory
            .appending(path: "translation-session-\(UUID().uuidString).wav")
        sessionWAVURL = sessionWAV
        let capture = StreamingAudioCapture()
        self.capture = capture
        let stream = capture.makeStream()
        do {
            try await capture.start(writingTo: sessionWAV)
        } catch {
            logger.logError("自建翻译：录音启动失败：\(error.localizedDescription)")
            status = "录音启动失败：\(error.localizedDescription)"
            isRunning = false
            return
        }

        let chunker = SentenceAudioChunker()
        let (chunkStream, chunkContinuation) = AsyncStream<URL>.makeStream()
        chunkerTask = Task {
            for await pcm in stream {
                // 朗读译文时跳过拾音：否则喇叭里的译文会被话筒重新
                // 收进来，再转录、再翻译、再朗读，形成“重复前面
                // 说过的内容”的回路。朗读结束后的说话不受影响。
                if synthesizer.isSpeaking || isServerAudioPlaying {
                    continue
                }
                if let url = chunker.feed(pcm) {
                    chunkContinuation.yield(url)
                }
            }
            if let url = chunker.flush() {
                chunkContinuation.yield(url)
            }
            chunkContinuation.finish()
        }
        let (translationStream, translationContinuation) = AsyncStream<Int>.makeStream()
        asrTask = Task {
            for await url in chunkStream {
                if let index = await transcribeChunk(url) {
                    translationContinuation.yield(index)
                }
            }
            translationContinuation.finish()
        }
        translationTask = Task {
            for await index in translationStream {
                await translatePair(index)
            }
        }
    }

    func stop() async {
        guard isRunning else { return }
        isRunning = false
        status = "正在收尾…"
        await capture?.stop()
        await chunkerTask?.value
        chunkerTask = nil
        await asrTask?.value
        asrTask = nil
        await translationTask?.value
        translationTask = nil
        synthesizer.stopSpeaking(at: .immediate)
        serverPlayer.removeAllItems()
        for url in ttsTempFiles {
            try? FileManager.default.removeItem(at: url)
        }
        ttsTempFiles = []
        if let url = sessionWAVURL {
            try? FileManager.default.removeItem(at: url)
        }
        sessionWAVURL = nil
        if let record = makeRecord(), !record.pairs.isEmpty {
            status = store.save(record) ? "已停止，记录已保存" : "已停止，记录保存失败"
        } else {
            status = "已停止"
        }
    }

    /// The current session as a savable record, or nil before start.
    func makeRecord() -> TranslationSessionRecord? {
        guard let startedAt else { return nil }
        let pairRecords = pairs
            .filter { !$0.original.isEmpty }
            .map { TranslationPairRecord(original: $0.original, translation: $0.translation) }
        return TranslationSessionRecord(
            startedAt: startedAt,
            sourceLanguage: sourceLanguage.rawValue,
            targetLanguage: targetLanguage.rawValue,
            asrModelName: asrModelName,
            pairs: pairRecords,
            summary: summary
        )
    }

    /// One-tap AI summary: key points, a short summary, and fixes for
    /// obvious transcription or translation mistakes in the record.
    func summarize() async {
        guard !isSummarizing, !pairs.isEmpty, let record = makeRecord() else { return }
        isSummarizing = true
        defer { isSummarizing = false }
        do {
            summary = try await TranslationSummarizer.summarize(record: record, aiService: aiService)
        } catch {
            logger.logError("自建翻译：总结失败：\(error.localizedDescription)")
            status = "总结失败：\(error.localizedDescription)"
        }
    }

    /// ASR stage: one chunk -> one pair with its original text, or nil
    /// when the chunk carries nothing worth showing. Runs ahead of
    /// translation, so originals appear as soon as recognition finishes.
    private func transcribeChunk(_ url: URL) async -> Int? {
        defer { try? FileManager.default.removeItem(at: url) }
        let service = SelfHostedTranscriptionService(
            config: .init(
                baseURL: SelfHostedTranscriptionConfig.serverURL,
                apiKey: SelfHostedTranscriptionConfig.apiKey ?? "",
                modelName: asrModelName
            )
        )
        let text: String
        do {
            text = try await service.transcribe(audioURL: url).text
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch CloudTranscriptionError.noTranscriptionReturned {
            // 服务端对这段音频没有识别出内容（静音、过短、杂音）：
            // 不是故障，静默跳过，不刷“转写失败”，也不占一个 pair。
            return nil
        } catch {
            logger.logError("自建翻译：转写失败：\(error.localizedDescription)")
            status = "转写失败：\(error.localizedDescription)"
            return nil
        }
        guard !text.isEmpty else { return nil }
        let index = pairs.count
        pairs.append(Pair(original: text))
        return index
    }

    /// Translation stage: fills one pair's translation in spoken order.
    private func translatePair(_ index: Int) async {
        guard index < pairs.count else { return }
        let text = pairs[index].original
        do {
            let preset = Self.translationPreset(from: sourceLanguage, to: targetLanguage)
            let (translated, _) = try await aiService.generateVariation(text: text, preset: preset)
            let cleaned = translated.trimmingCharacters(in: .whitespacesAndNewlines)
            pairs[index].translation = cleaned
            pairs[index].isTranslating = false
            if ttsEnabled, !cleaned.isEmpty {
                speak(cleaned)
            }
        } catch {
            logger.logError("自建翻译：翻译失败：\(error.localizedDescription)")
            pairs[index].isTranslating = false
            pairs[index].error = "翻译失败：\(error.localizedDescription)"
        }
    }

    private func speak(_ text: String) {
        if let voiceID = ttsVoiceID {
            Task { await speakViaServer(text, voiceID: voiceID) }
        } else {
            speakViaSystem(text)
        }
    }

    private func speakViaSystem(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: targetLanguage.ttsCode)
        utterance.rate = 0.5
        synthesizer.speak(utterance)
    }

    /// Server-voice readout: one sentence at a time through the queue
    /// player, so sentences never overlap. Any failure (server down,
    /// bad voice, bad audio) falls back to the system voice for this
    /// sentence instead of dropping it.
    private func speakViaServer(_ text: String, voiceID: String) async {
        guard let apiKey = SelfHostedTranscriptionConfig.apiKey, !apiKey.isEmpty else {
            speakViaSystem(text)
            return
        }
        let client = ServerTTSClient(baseURL: SelfHostedTranscriptionConfig.serverURL, apiKey: apiKey)
        do {
            let audio = try await client.synthesize(
                text: text,
                voiceID: voiceID,
                languageCode: targetLanguage.rawValue
            )
            let url = FileManager.default.temporaryDirectory
                .appending(path: "tts-\(UUID().uuidString).wav")
            try audio.write(to: url)
            ttsTempFiles.append(url)
            serverPlayer.insert(AVPlayerItem(url: url), after: nil)
            serverPlayer.play()
        } catch {
            logger.logError("自建翻译：服务器语音失败，回落系统语音：\(error.localizedDescription)")
            speakViaSystem(text)
        }
    }

    private static func translationPreset(from: Language, to: Language) -> Preset {
        Preset(
            id: "selfHostedTranslation",
            name: "翻译",
            icon: "translate",
            category: "Translate",
            promptInstructions: "Translate the following text from \(from.translationName) to \(to.translationName). Output only the translation, without any explanation, notes, or quotation marks.",
            useSystemTemplate: false
        )
    }
}
