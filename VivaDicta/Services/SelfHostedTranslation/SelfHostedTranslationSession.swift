import AVFoundation
import CloudTranscription
import Foundation
import os
import Presets

/// One self-hosted sentence-translation session: mic -> silence chunking
/// -> self-hosted ASR -> AI translation -> bilingual list, with optional
/// TTS readout of each translation.
///
/// The pipeline is two tasks by design. The chunker task only ever does
/// synchronous work (RMS + WAV writes), so it never stalls the capture
/// stream, which drops audio when its ~1s buffer fills. A second task
/// drains completed chunks serially through ASR + translation, so pairs
/// always append in spoken order; if processing falls behind, the lag
/// grows instead of audio being lost. A failed chunk never kills the
/// session: ASR failures surface as a status line, translation failures
/// attach to their pair, and the next chunk still runs.
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
    var targetLanguage: Language = .japanese
    var asrModelName = "sensevoice"
    var ttsEnabled = true

    var hasSelfHostedKey: Bool {
        guard let key = SelfHostedTranscriptionConfig.apiKey else { return false }
        return !key.isEmpty
    }

    private let aiService: AIService
    private let logger = Logger(category: .selfHostedTranslation)
    private let synthesizer = AVSpeechSynthesizer()
    private var capture: StreamingAudioCapture?
    private var chunkerTask: Task<Void, Never>?
    private var processorTask: Task<Void, Never>?
    private var sessionWAVURL: URL?

    init(aiService: AIService) {
        self.aiService = aiService
    }

    func start() async {
        guard !isRunning else { return }
        guard hasSelfHostedKey else {
            status = "先配置自建服务器的 API Key"
            return
        }
        pairs = []
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
                if let url = chunker.feed(pcm) {
                    chunkContinuation.yield(url)
                }
            }
            if let url = chunker.flush() {
                chunkContinuation.yield(url)
            }
            chunkContinuation.finish()
        }
        processorTask = Task {
            for await url in chunkStream {
                await process(url)
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
        await processorTask?.value
        processorTask = nil
        synthesizer.stopSpeaking(at: .immediate)
        if let url = sessionWAVURL {
            try? FileManager.default.removeItem(at: url)
        }
        sessionWAVURL = nil
        status = "已停止"
    }

    private func process(_ url: URL) async {
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
        } catch {
            logger.logError("自建翻译：转写失败：\(error.localizedDescription)")
            status = "转写失败：\(error.localizedDescription)"
            return
        }
        guard !text.isEmpty else { return }
        let index = pairs.count
        pairs.append(Pair(original: text))
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
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: targetLanguage.ttsCode)
        utterance.rate = 0.5
        synthesizer.speak(utterance)
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
