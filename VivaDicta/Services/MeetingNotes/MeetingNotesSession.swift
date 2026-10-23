import CloudTranscription
import Foundation
import os
import TranscriptionCore

/// One live meeting-notes session: mic -> silence chunking -> the user's
/// own ASR server -> speaker-labelled segments, with an optional AI
/// summary afterwards in a chosen language (Japanese / Chinese / English).
///
/// Speaker labels are a VOLUME heuristic, not voice identification.
/// The phone holder sits closest to the mic and sounds loudest (A);
/// everyone farther away sounds quieter (B). A chunk whose mean speech
/// RMS clears nearThresholdRMS is A, otherwise B. It mislabels when a
/// far speaker shouts, the holder whispers, or two far speakers talk
/// (both become B) — that is the documented limit of this approach.
/// Stopped sessions auto-save to Documents/MeetingNotes.
@MainActor
@Observable
final class MeetingNotesSession {
    struct Segment: Identifiable {
        let id = UUID()
        let speaker: String
        let text: String
    }

    /// Chunk + the mean speech RMS the chunker measured for it, carried
    /// together so the ASR task classifies the speaker without racing
    /// the chunker for its last-chunk energy reading.
    private struct ChunkItem {
        let url: URL
        let meanSpeechRMS: Float
    }

    /// Fixed near/far boundary on mean speech RMS. Chunks at or above
    /// this are the holder (A); below it, the far speaker (B). Starting
    /// heuristic: holder speech into a hand-held phone is several times
    /// louder than speech from across a table. Tune from real-device
    /// feedback if A/B flips the wrong way in practice.
    private let nearThresholdRMS: Float = 0.12

    var isRunning = false
    var segments: [Segment] = []
    var status = ""
    var asrModelName = "sensevoice"
    var summaryLanguage: MeetingSummarizer.Language = .chinese
    var summary: String?
    var isSummarizing = false
    private(set) var startedAt: Date?

    var hasSelfHostedKey: Bool {
        guard let key = SelfHostedTranscriptionConfig.apiKey else { return false }
        return !key.isEmpty
    }

    private let aiService: AIService
    private let store = MeetingRecordStore()
    private let logger = Logger(category: .selfHostedTranslation)
    private var capture: StreamingAudioCapture?
    private var chunkerTask: Task<Void, Never>?
    private var asrTask: Task<Void, Never>?
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
        segments = []
        summary = nil
        startedAt = Date()
        status = "正在记录…"
        isRunning = true

        let sessionWAV = FileManager.default.temporaryDirectory
            .appending(path: "meeting-session-\(UUID().uuidString).wav")
        sessionWAVURL = sessionWAV
        let capture = StreamingAudioCapture()
        self.capture = capture
        let stream = capture.makeStream()
        do {
            try await capture.start(writingTo: sessionWAV)
        } catch {
            logger.logError("会议记录：录音启动失败：\(error.localizedDescription)")
            status = "录音启动失败：\(error.localizedDescription)"
            isRunning = false
            return
        }

        let chunker = SentenceAudioChunker()
        let (chunkStream, chunkContinuation) = AsyncStream<ChunkItem>.makeStream()
        chunkerTask = Task {
            for await pcm in stream {
                if let url = chunker.feed(pcm) {
                    chunkContinuation.yield(ChunkItem(url: url, meanSpeechRMS: chunker.lastChunkMeanSpeechRMS))
                }
            }
            if let url = chunker.flush() {
                chunkContinuation.yield(ChunkItem(url: url, meanSpeechRMS: chunker.lastChunkMeanSpeechRMS))
            }
            chunkContinuation.finish()
        }
        asrTask = Task {
            for await item in chunkStream {
                await transcribeChunk(item)
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
        if let url = sessionWAVURL {
            try? FileManager.default.removeItem(at: url)
        }
        sessionWAVURL = nil
        if let record = makeRecord(), !record.segments.isEmpty {
            status = store.save(record) ? "已停止，记录已保存" : "已停止，记录保存失败"
        } else {
            status = "已停止"
        }
    }

    /// The current session as a savable record, or nil before start.
    func makeRecord() -> MeetingRecord? {
        guard let startedAt else { return nil }
        let segmentRecords = segments
            .filter { !$0.text.isEmpty }
            .map { MeetingSegmentRecord(speaker: $0.speaker, text: $0.text) }
        return MeetingRecord(
            startedAt: startedAt,
            asrModelName: asrModelName,
            segments: segmentRecords,
            summary: summary,
            summaryLanguage: summary?.isEmpty == false ? summaryLanguage.rawValue : nil
        )
    }

    /// One-tap AI summary in the chosen language. Re-saves the record
    /// afterwards so the summary persists in history.
    func summarize() async {
        guard !isSummarizing, !segments.isEmpty, let record = makeRecord() else { return }
        isSummarizing = true
        defer { isSummarizing = false }
        do {
            summary = try await MeetingSummarizer.summarize(
                segments: record.segments,
                language: summaryLanguage,
                aiService: aiService
            )
            if let updated = makeRecord() {
                _ = store.save(updated)
            }
        } catch {
            logger.logError("会议记录：总结失败：\(error.localizedDescription)")
            status = "总结失败：\(error.localizedDescription)"
        }
    }

    /// ASR stage: one chunk -> one speaker-labelled segment, or nothing
    /// when the chunk carries nothing worth showing.
    private func transcribeChunk(_ item: ChunkItem) async {
        defer { try? FileManager.default.removeItem(at: item.url) }
        let service = SelfHostedTranscriptionService(
            config: .init(
                baseURL: SelfHostedTranscriptionConfig.serverURL,
                apiKey: SelfHostedTranscriptionConfig.apiKey ?? "",
                modelName: asrModelName
            )
        )
        let text: String
        do {
            text = try await service.transcribe(audioURL: item.url).text
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch CloudTranscriptionError.noTranscriptionReturned {
            // No speech recognized in this chunk (silence, too short,
            // noise): not a failure, skip silently, same as translation.
            return
        } catch {
            logger.logError("会议记录：转写失败：\(error.localizedDescription)")
            status = "转写失败：\(error.localizedDescription)"
            return
        }
        guard !text.isEmpty else { return }
        let speaker = item.meanSpeechRMS >= nearThresholdRMS ? "A" : "B"
        segments.append(Segment(speaker: speaker, text: text))
    }
}
