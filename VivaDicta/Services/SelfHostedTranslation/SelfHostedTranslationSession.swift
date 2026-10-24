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
/// Conversation mode (on by default): the two pickers are languages A
/// and B, not a fixed source -> target. Each transcribed sentence is
/// detected client-side from its script (the ASR server returns text
/// only, no language field) and translated to the other language, so
/// two people speaking different languages can talk through one mic.
/// A sentence that cannot be decided (mixed script, digits only, or a
/// third language) keeps the previous sentence's direction instead of
/// flipping the session back and forth.
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
        /// The direction this sentence was actually translated in.
        /// In conversation mode these differ per sentence; in fixed
        /// mode they always equal the session's source/target.
        var sourceLanguage: Language
        var targetLanguage: Language
        var translation: String?
        var isTranslating = true
        var error: String?
    }

    enum Language: String, CaseIterable {
        case chinese = "zh"
        case english = "en"
        case japanese = "ja"
        case korean = "ko"
        case french = "fr"
        case spanish = "es"
        case portuguese = "pt"
        case russian = "ru"
        case vietnamese = "vi"

        var displayName: String {
            switch self {
            case .chinese: "中文"
            case .english: "英语"
            case .japanese: "日语"
            case .korean: "韩语"
            case .french: "法语"
            case .spanish: "西班牙语"
            case .portuguese: "葡萄牙语"
            case .russian: "俄语"
            case .vietnamese: "越南语"
            }
        }

        var translationName: String {
            switch self {
            case .chinese: "Chinese"
            case .english: "English"
            case .japanese: "Japanese"
            case .korean: "Korean"
            case .french: "French"
            case .spanish: "Spanish"
            case .portuguese: "Portuguese"
            case .russian: "Russian"
            case .vietnamese: "Vietnamese"
            }
        }

        var ttsCode: String {
            switch self {
            case .chinese: "zh-CN"
            case .english: "en-US"
            case .japanese: "ja-JP"
            case .korean: "ko-KR"
            case .french: "fr-FR"
            case .spanish: "es-ES"
            case .portuguese: "pt-BR"
            case .russian: "ru-RU"
            case .vietnamese: "vi-VN"
            }
        }

        /// Whether the language is normally written in Latin script.
        /// Used by conversation-mode detection: pure Latin text can
        /// only decide the pair when exactly one side is Latin-script.
        var usesLatinScript: Bool {
            switch self {
            case .english, .french, .spanish, .portuguese, .vietnamese:
                true
            case .chinese, .japanese, .korean, .russian:
                false
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
    /// Conversation mode: translate each sentence to the other of the
    /// two picked languages, detected per sentence. Off restores the
    /// old fixed source -> target behaviour.
    var isConversationMode = true
    /// Last decisively detected language, used as the sticky fallback
    /// for sentences detection cannot decide. Reset on start().
    private var lastSpokenLanguage: Language?
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
    /// Bumped by stopReadout(): a server synthesis already in flight
    /// when the voice changes must not queue its stale old-voice audio
    /// after the switch. speakViaServer checks this before inserting.
    private var readoutGeneration = 0
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
        lastSpokenLanguage = nil
        status = "正在聆听…"
        isRunning = true

        let sessionWAV = FileManager.default.temporaryDirectory
            .appending(path: "translation-session-\(UUID().uuidString).wav")
        sessionWAVURL = sessionWAV
        let capture = StreamingAudioCapture()
        self.capture = capture
        capture.onInterruption = { [weak self] event in
            guard let self, isRunning else { return }
            switch event {
            case .began:
                status = "音频被打断，等待恢复…"
            case .resumed:
                status = "正在聆听…"
            case .endedWithoutResume:
                status = "音频打断后未能自动恢复，请点停止后重新开始"
            }
        }
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
        readoutGeneration += 1
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
            .map {
                TranslationPairRecord(
                    original: $0.original,
                    translation: $0.translation,
                    sourceLanguage: $0.sourceLanguage.rawValue,
                    targetLanguage: $0.targetLanguage.rawValue
                )
            }
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
        let (detected, target) = direction(for: text)
        let index = pairs.count
        pairs.append(Pair(original: text, sourceLanguage: detected, targetLanguage: target))
        return index
    }

    /// The translation direction for one transcribed sentence. In
    /// fixed mode this is always the session's source -> target. In
    /// conversation mode the detected language translates to the other
    /// picked language; an undecidable sentence keeps the previous
    /// direction so one mixed sentence cannot flip the whole session.
    private func direction(for text: String) -> (Language, Language) {
        guard isConversationMode else { return (sourceLanguage, targetLanguage) }
        let detected: Language
        if let decided = Self.detectLanguage(of: text, first: sourceLanguage, second: targetLanguage) {
            detected = decided
            lastSpokenLanguage = decided
        } else if let last = lastSpokenLanguage, last == sourceLanguage || last == targetLanguage {
            detected = last
        } else {
            detected = sourceLanguage
        }
        let target = detected == sourceLanguage ? targetLanguage : sourceLanguage
        return (detected, target)
    }

    /// Script-based language detection between two candidate languages.
    /// Returns nil when the text cannot decide the pair, so the caller
    /// can fall back instead of guessing. Each rule only fires when
    /// its language is actually in the pair:
    /// - kana is decisive for Japanese; Hangul for Korean; Cyrillic
    ///   for Russian — none of these scripts appear in the other
    ///   languages on offer;
    /// - pure Latin text decides only when the pair holds exactly one
    ///   Latin-script language (e.g. Chinese + French); a French +
    ///   Spanish pair cannot be told apart from script alone;
    /// - pure CJK text: when the pair is Chinese + Japanese it is
    ///   treated as Chinese, because spoken Japanese almost always
    ///   carries kana (particles, okurigana, です/ます) while Chinese
    ///   has none — a truly kana-less Japanese utterance is usually a
    ///   bare noun, and translating it as if Chinese into Japanese
    ///   normally returns the same word;
    /// - mixed scripts (code-switching), digits or punctuation only,
    ///   and a third language outside the pair all return nil.
    private static func detectLanguage(of text: String, first: Language, second: Language) -> Language? {
        let pair = [first, second]
        var kanaCount = 0
        var hangulCount = 0
        var cyrillicCount = 0
        var cjkCount = 0
        var latinCount = 0
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if (0x3040...0x309F).contains(value) || (0x30A0...0x30FF).contains(value)
                || (0xFF66...0xFF9D).contains(value) {
                kanaCount += 1
            } else if (0xAC00...0xD7A3).contains(value) || (0x1100...0x11FF).contains(value)
                || (0x3130...0x318F).contains(value) {
                hangulCount += 1
            } else if (0x0400...0x04FF).contains(value) {
                cyrillicCount += 1
            } else if (0x4E00...0x9FFF).contains(value) || (0x3400...0x4DBF).contains(value) {
                cjkCount += 1
            } else if (0x41...0x5A).contains(value) || (0x61...0x7A).contains(value) {
                latinCount += 1
            }
        }
        if kanaCount > 0 {
            return pair.contains(.japanese) ? .japanese : nil
        }
        if hangulCount > 0 {
            return pair.contains(.korean) ? .korean : nil
        }
        if cyrillicCount > 0 {
            return pair.contains(.russian) ? .russian : nil
        }
        if cjkCount == 0, latinCount > 0 {
            let latinLanguages = pair.filter { $0.usesLatinScript }
            return latinLanguages.count == 1 ? latinLanguages[0] : nil
        }
        if latinCount == 0, cjkCount > 0 {
            if pair.contains(.chinese), pair.contains(.japanese) {
                return .chinese
            }
            let cjkLanguages = pair.filter { $0 == .chinese || $0 == .japanese }
            return cjkLanguages.count == 1 ? cjkLanguages[0] : nil
        }
        return nil
    }

    /// Translation stage: fills one pair's translation in spoken order.
    /// The direction comes from the pair itself, so a conversation-mode
    /// sentence translates back to the other language even though the
    /// next sentence may go the opposite way.
    private func translatePair(_ index: Int) async {
        guard index < pairs.count else { return }
        let text = pairs[index].original
        let pairSource = pairs[index].sourceLanguage
        let pairTarget = pairs[index].targetLanguage
        do {
            let preset = Self.translationPreset(from: pairSource, to: pairTarget)
            let (translated, _) = try await aiService.generateVariation(text: text, preset: preset)
            let cleaned = translated.trimmingCharacters(in: .whitespacesAndNewlines)
            pairs[index].translation = cleaned
            pairs[index].isTranslating = false
            if ttsEnabled, !cleaned.isEmpty {
                speak(cleaned, language: pairTarget)
            }
        } catch {
            logger.logError("自建翻译：翻译失败：\(error.localizedDescription)")
            pairs[index].isTranslating = false
            pairs[index].error = "翻译失败：\(error.localizedDescription)"
        }
    }

    /// Called when the user picks a different readout voice while
    /// readout is on: the switch must take effect at once, not after
    /// the old voice finishes the queue. If the most recent sentence
    /// was read in the changed language, stops anything still playing
    /// in the old voice (queued server audio is cleared; in-flight
    /// synthesis is discarded via readoutGeneration) and immediately
    /// re-reads that sentence in the new voice, so the switch is
    /// audible without waiting for the next sentence. If the most
    /// recent sentence was in the other direction, nothing audible
    /// changes right now (that direction's voice was not touched) and
    /// the next sentence in the changed language uses the new voice,
    /// since speak() always reads the fresh store value. No-op when
    /// readout is off or the session is not running: a voice picked
    /// on the setup screen simply applies to the next session's
    /// sentences.
    func voiceSelectionChanged(for language: Language) {
        guard ttsEnabled, isRunning else { return }
        guard let last = pairs.last, last.targetLanguage == language,
              let translation = last.translation,
              !translation.isEmpty, !last.isTranslating else { return }
        stopReadout()
        speak(translation, language: language)
    }

    /// Stops the current readout and clears queued audio. Does not
    /// touch ttsTempFiles: they are cleaned up by stop().
    private func stopReadout() {
        synthesizer.stopSpeaking(at: .immediate)
        serverPlayer.removeAllItems()
        readoutGeneration += 1
    }

    /// Readout in the translation's own language. The server voice is
    /// looked up per language (a Chinese voice cannot read Japanese
    /// well, and vice versa); in fixed mode this equals the picker's
    /// voice for the session target, in conversation mode it follows
    /// each sentence's direction.
    private func speak(_ text: String, language: Language) {
        if let voiceID = ServerTTSVoiceSelection.voiceID(forLanguageCode: language.rawValue) {
            Task { await speakViaServer(text, voiceID: voiceID, language: language) }
        } else {
            speakViaSystem(text, language: language)
        }
    }

    private func speakViaSystem(_ text: String, language: Language) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language.ttsCode)
        utterance.rate = 0.5
        synthesizer.speak(utterance)
    }

    /// Server-voice readout: one sentence at a time through the queue
    /// player, so sentences never overlap. Any failure (server down,
    /// bad voice, bad audio) falls back to the system voice for this
    /// sentence instead of dropping it.
    private func speakViaServer(_ text: String, voiceID: String, language: Language) async {
        guard let apiKey = SelfHostedTranscriptionConfig.apiKey, !apiKey.isEmpty else {
            speakViaSystem(text, language: language)
            return
        }
        let generation = readoutGeneration
        let client = ServerTTSClient(baseURL: SelfHostedTranscriptionConfig.serverURL, apiKey: apiKey)
        do {
            let audio = try await client.synthesize(
                text: text,
                voiceID: voiceID,
                languageCode: language.rawValue
            )
            // Voice changed mid-synthesis: drop this stale audio
            // instead of queueing old-voice sound after the switch.
            guard generation == readoutGeneration else { return }
            let url = FileManager.default.temporaryDirectory
                .appending(path: "tts-\(UUID().uuidString).wav")
            try audio.write(to: url)
            ttsTempFiles.append(url)
            serverPlayer.insert(AVPlayerItem(url: url), after: nil)
            serverPlayer.play()
        } catch {
            guard generation == readoutGeneration else { return }
            logger.logError("自建翻译：服务器语音失败，回落系统语音：\(error.localizedDescription)")
            speakViaSystem(text, language: language)
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
