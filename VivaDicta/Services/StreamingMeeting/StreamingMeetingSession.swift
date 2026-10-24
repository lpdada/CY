import Foundation
import os

/// One streaming meeting session: mic -> WebSocket -> server-side
/// voiceprint diarization -> speaker-labelled segments.
///
/// This deliberately contains NO volume-based speaker logic. The old
/// `MeetingNotesSession` labels A/B by a mean-RMS threshold; here the
/// speaker labels come only from the server's voiceprint clustering
/// (`speaker_label` on interim/final frames, corrected later by
/// `speaker_update` frames). Nothing in this file measures audio level
/// for diarization: `StreamingAudioCapture`'s level meter is not read
/// at all.
///
/// Segment identity is the server's `segment_id`, never the row number.
/// An interim frame creates or updates the segment with that id in
/// place; the matching final frame replaces its text and speaker in
/// place; a `speaker_update` frame rewrites the speaker of the listed
/// segment ids in place. The array order never changes except by
/// append, so the list never jumps or re-sorts under the user.
///
/// Display names are a separate layer: `speaker_label` on a segment
/// never changes because the user renamed someone. Renames live in
/// `speakerNames` and are resolved at display/save time only, so a
/// rename needs no re-clustering and applies to every segment with
/// that label at once.
@MainActor
@Observable
final class StreamingMeetingSession {
    struct Segment: Identifiable {
        /// Stable identity: the server's `segment_id`.
        let segmentID: String
        var id: String { segmentID }
        var text: String
        /// Raw server label ("A", "B", ...), or nil while unassigned.
        /// Never edited by renaming; see `displayName(for:)`.
        var speakerLabel: String?
        /// Provisional until the matching final frame arrives.
        var isProvisional: Bool
        var speakerStatus: StreamingSpeakerStatus
        var confidence: Double?
        var start: Double
        var end: Double
        var corrected: Bool
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
    }

    /// How long `start` waits for the server's ready frame (contract:
    /// 5 seconds). The probe uses the same budget via a watchdog task.
    private static let readyTimeoutPolls = 50
    private static let readyPollIntervalMilliseconds = 100
    private static let maxSpeakers = 10

    var isRunning = false
    var segments: [Segment] = []
    var status = ""
    var language: Language = .chinese
    var asrModelName = "sensevoice"
    /// Nil until probed; false means the view must show the old path.
    private(set) var streamingAvailable: Bool?
    /// Server error code from the last failed probe, if any
    /// (notably `streaming_unsupported_language` for Japanese).
    private(set) var lastProbeErrorCode: String?
    /// True when the server explicitly refused this language with
    /// `streaming_unsupported_language` during `start`.
    private(set) var streamingUnsupportedLanguage = false
    /// Display-name overrides, keyed by raw server label. Set only
    /// through `renameSpeaker(oldLabel:newName:)`; segment labels
    /// themselves are never rewritten by a rename.
    private(set) var speakerNames: [String: String] = [:]
    private(set) var startedAt: Date?

    var hasSelfHostedKey: Bool {
        guard let key = SelfHostedTranscriptionConfig.apiKey else { return false }
        return !key.isEmpty
    }

    /// Speaker labels in first-appearance order, for the rename picker.
    /// Derived from the segments, so it can never go stale.
    var knownSpeakerLabels: [String] {
        var seen: [String] = []
        for segment in segments {
            guard let label = segment.speakerLabel, !seen.contains(label) else { continue }
            seen.append(label)
        }
        return seen
    }

    /// Optional translation hook, set by the view. When present, every
    /// final segment is handed to it (finals only, never interims);
    /// the translation session enforces that again on its side.
    var translationSession: StreamingTranslationSession?

    private let store = MeetingRecordStore()
    private let logger = Logger(category: .selfHostedTranslation)
    private var capture: StreamingAudioCapture?
    private var client: StreamingWebSocketClient?
    private var eventTask: Task<Void, Never>?
    private var forwardTask: Task<Void, Never>?
    private var sessionWAVURL: URL?
    private var connectionReady = false
    private var connectionError: StreamingError?
    /// Set by the `session_end` handler so the single after-loop
    /// cleanup below can tell a clean server ending apart from a
    /// transport failure. The handler itself must NOT finish the
    /// session: the after-loop cleanup is the one and only finisher,
    /// otherwise a session could be saved twice (each `makeRecord()`
    /// mints a new record id).
    private var serverEndedCleanly = false

    /// Probe: one WebSocket connect + auth + wait for ready, no audio.
    /// True only when the ready frame arrives within 5 seconds. Any
    /// error frame, transport failure, or timeout means unavailable,
    /// and the caller must not start a streaming session.
    func checkStreamingAvailable(language: Language) async -> Bool {
        guard let apiKey = SelfHostedTranscriptionConfig.apiKey, !apiKey.isEmpty else {
            streamingAvailable = false
            return false
        }
        lastProbeErrorCode = nil
        let probeClient = StreamingWebSocketClient()
        let stream = await probeClient.connect(
            serverURL: SelfHostedTranscriptionConfig.serverURL,
            apiKey: apiKey,
            language: language.rawValue,
            maxSpeakers: Self.maxSpeakers
        )
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(5))
            await probeClient.disconnect()
        }
        var available = false
        probeLoop: for await event in stream {
            switch event {
            case .ready:
                available = true
                break probeLoop
            case .failed(let error):
                lastProbeErrorCode = error.serverCode
                break probeLoop
            case .sessionEnded:
                break probeLoop
            default:
                continue
            }
        }
        watchdog.cancel()
        await probeClient.disconnect()
        streamingAvailable = available
        return available
    }

    func start() async {
        guard !isRunning else { return }
        guard hasSelfHostedKey else {
            status = "先配置自建服务器的 API Key"
            return
        }
        segments = []
        speakerNames = [:]
        streamingUnsupportedLanguage = false
        lastProbeErrorCode = nil
        translationSession?.reset()
        startedAt = Date()
        status = "正在连接流式服务器…"
        connectionReady = false
        connectionError = nil
        serverEndedCleanly = false

        let wsClient = StreamingWebSocketClient()
        client = wsClient
        let stream = await wsClient.connect(
            serverURL: SelfHostedTranscriptionConfig.serverURL,
            apiKey: SelfHostedTranscriptionConfig.apiKey ?? "",
            language: language.rawValue,
            maxSpeakers: Self.maxSpeakers
        )
        eventTask = Task {
            for await event in stream {
                handleEvent(event)
            }
            // The stream ended (session_end, disconnect, or transport
            // failure). If the session is still marked running, the
            // server went away: stop the mic and save what we have.
            // This is the ONLY finisher for server-side endings (the
            // `session_end` handler only sets the flag below), so a
            // session is saved at most once. `stop()` already cleared
            // `isRunning`, so its own await of this task cannot
            // re-enter here.
            if isRunning {
                await finishAfterServerEnd(savedStatus: serverEndedCleanly
                    ? "服务器已结束会话，记录已保存"
                    : "连接已断开，记录已保存")
            }
        }

        // Ready wait: the event task above owns the stream, so this
        // polls the flags it sets instead of consuming the stream a
        // second time. 50 x 100 ms = the contract's 5 second budget.
        var polls = 0
        while !connectionReady, connectionError == nil, polls < Self.readyTimeoutPolls {
            try? await Task.sleep(for: .milliseconds(Self.readyPollIntervalMilliseconds))
            polls += 1
        }
        if let error = connectionError {
            let unsupported = error.serverCode == "streaming_unsupported_language"
            await failStart(
                unsupported ? "流式暂不支持该语言（\(error.serverCode ?? "")），请用旧版记录" : "流式连接失败：\(error.message)",
                unsupportedLanguage: unsupported
            )
            return
        }
        if !connectionReady {
            await failStart("流式服务器 5 秒内未就绪", unsupportedLanguage: false)
            return
        }

        // Audio path: reuse StreamingAudioCapture's stream verbatim.
        // Verified in StreamingAudioCapture.swift: `sampleRate` is
        // 16_000, `captureFormat` is pcmFormatInt16, 1 channel,
        // interleaved — exactly the 16 kHz mono PCM16 the contract's
        // binary frames carry. No second recorder is started.
        let sessionWAV = FileManager.default.temporaryDirectory
            .appending(path: "streaming-meeting-\(UUID().uuidString).wav")
        sessionWAVURL = sessionWAV
        let capture = StreamingAudioCapture()
        self.capture = capture
        let audioStream = capture.makeStream()
        do {
            try await capture.start(writingTo: sessionWAV)
        } catch {
            logger.logError("流式会议：录音启动失败：\(error.localizedDescription)")
            await failStart("录音启动失败：\(error.localizedDescription)", unsupportedLanguage: false)
            return
        }
        forwardTask = Task {
            for await pcm in audioStream {
                await wsClient.sendAudioChunk(pcm)
            }
        }
        isRunning = true
        status = "正在记录（流式）…"
    }

    func stop() async {
        guard isRunning else { return }
        isRunning = false
        status = "正在收尾…"
        await capture?.stop()
        await forwardTask?.value
        forwardTask = nil
        capture = nil
        // Ask the server to finalise, then give it up to 2 seconds to
        // send its session_end (and any last finals) before closing
        // the socket. The watchdog's disconnect finishes the event
        // stream, so awaiting the event task below always terminates.
        await client?.sendEnd()
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(2))
            await client?.disconnect()
        }
        await eventTask?.value
        watchdog.cancel()
        await client?.disconnect()
        eventTask = nil
        client = nil
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

    /// The current session as a savable record, reusing the old
    /// `MeetingRecord` / `MeetingRecordStore` shape unchanged: the
    /// store writes to the same Documents/MeetingNotes directory, so
    /// the old history view reads streaming records too. One deliberate
    /// difference from the old path: `speaker` stores the display name
    /// (rename, or the raw label, or "待确认" while unassigned) rather
    /// than the raw label, so a renamed history entry stays readable.
    /// (The "?" badge is view-only; the record keeps "待确认".)
    /// Provisional segments are saved as-is with their interim text.
    func makeRecord() -> MeetingRecord? {
        guard let startedAt else { return nil }
        let segmentRecords = segments
            .filter { !$0.text.isEmpty }
            .map { MeetingSegmentRecord(speaker: displayName(for: $0.speakerLabel), text: $0.text) }
        return MeetingRecord(
            startedAt: startedAt,
            asrModelName: asrModelName,
            segments: segmentRecords,
            summary: nil,
            summaryLanguage: nil
        )
    }

    /// Display name for a raw server label: the user's rename wins,
    /// otherwise the label itself; nil (unassigned) shows as "待确认".
    /// The badge in the row uses "?" for nil instead; see the view.
    func displayName(for label: String?) -> String {
        guard let label else { return "待确认" }
        return speakerNames[label] ?? label
    }

    /// The user's custom name for a label, if one was set, for the
    /// rename sheet's text field. Nil means "no rename yet".
    func customName(for label: String) -> String? {
        speakerNames[label]
    }

    /// Renames one speaker everywhere at once. Only the display map
    /// changes: segment `speakerLabel` values are untouched, so this
    /// never depends on (or triggers) re-clustering. An empty name
    /// clears the rename and restores the raw label display.
    func renameSpeaker(oldLabel: String, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            speakerNames.removeValue(forKey: oldLabel)
        } else {
            speakerNames[oldLabel] = trimmed
        }
    }

    /// Excel-style label for a speaker index: 0 -> A, 25 -> Z,
    /// 26 -> AA, 27 -> AB, and so on. The server normally assigns
    /// labels itself; this is the shared rule for any locally derived
    /// label list so dynamic speakers past 26 stay unambiguous.
    static func label(forSpeakerIndex index: Int) -> String {
        let letters = ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M",
                       "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z"]
        var value = index + 1
        var result = ""
        while value > 0 {
            value -= 1
            result = letters[value % 26] + result
            value /= 26
        }
        return result
    }

    // MARK: - Private

    private func handleEvent(_ event: StreamingWebSocketClient.Event) {
        switch event {
        case .ready:
            connectionReady = true
        case .failed(let error):
            if !connectionReady {
                connectionError = error
            } else {
                logger.logError("流式会议：服务器错误：\(error.message)")
                status = "流式错误：\(error.message)"
            }
        case .interimSegment(let segmentID, let text, let speakerLabel, let start, let end):
            guard connectionReady else { return }
            if let index = segments.firstIndex(where: { $0.segmentID == segmentID }) {
                segments[index].text = text
                segments[index].speakerLabel = speakerLabel
                segments[index].isProvisional = true
                segments[index].speakerStatus = .provisional
                segments[index].start = start
                segments[index].end = end
            } else {
                segments.append(Segment(
                    segmentID: segmentID,
                    text: text,
                    speakerLabel: speakerLabel,
                    isProvisional: true,
                    speakerStatus: .provisional,
                    confidence: nil,
                    start: start,
                    end: end,
                    corrected: false
                ))
            }
        case .finalSegment(let segmentID, let text, let speakerLabel, let status, let confidence, let start, let end, let corrected):
            guard connectionReady else { return }
            if let index = segments.firstIndex(where: { $0.segmentID == segmentID }) {
                // In-place replacement: same row, same position, new
                // text and speaker. Never append a second row.
                segments[index].text = text
                segments[index].speakerLabel = speakerLabel
                segments[index].isProvisional = false
                segments[index].speakerStatus = status
                segments[index].confidence = confidence
                segments[index].start = start
                segments[index].end = end
                segments[index].corrected = corrected
            } else {
                segments.append(Segment(
                    segmentID: segmentID,
                    text: text,
                    speakerLabel: speakerLabel,
                    isProvisional: false,
                    speakerStatus: status,
                    confidence: confidence,
                    start: start,
                    end: end,
                    corrected: corrected
                ))
            }
            if let segment = segments.first(where: { $0.segmentID == segmentID }) {
                // Finals only: interims never reach translation.
                // A detached Task keeps a slow translation from
                // stalling the event loop; the translation session
                // drops stale results if a corrected final supersedes.
                if let translationSession {
                    Task { await translationSession.handleFinalSegment(segment) }
                }
            }
        case .speakerUpdated(_, let updated):
            guard connectionReady else { return }
            // Authoritative source is the per-segment list, applied by
            // segment_id. The `remap` dictionary explains the change
            // (old label -> new label) but is not applied blindly to
            // every segment carrying the old label: only the listed
            // segments move, so unrelated rows never flicker.
            for item in updated {
                guard let index = segments.firstIndex(where: { $0.segmentID == item.segmentID }) else { continue }
                segments[index].speakerLabel = item.speakerLabel
            }
        case .sessionEnded:
            // Only flag it. The client already finished the stream,
            // so the event loop exits right after this and its
            // after-loop cleanup finishes (and saves) exactly once.
            guard isRunning else { return }
            serverEndedCleanly = true
        }
    }

    private func failStart(_ message: String, unsupportedLanguage: Bool) async {
        streamingUnsupportedLanguage = unsupportedLanguage
        status = message
        isRunning = false
        await client?.disconnect()
        await eventTask?.value
        eventTask = nil
        client = nil
        capture = nil
        if let url = sessionWAVURL {
            try? FileManager.default.removeItem(at: url)
        }
        sessionWAVURL = nil
    }

    private func finishAfterServerEnd(savedStatus: String) async {
        isRunning = false
        await capture?.stop()
        await forwardTask?.value
        forwardTask = nil
        capture = nil
        if let url = sessionWAVURL {
            try? FileManager.default.removeItem(at: url)
        }
        sessionWAVURL = nil
        if let record = makeRecord(), !record.segments.isEmpty {
            status = store.save(record) ? savedStatus : savedStatus + "，但记录保存失败"
        } else {
            status = "服务器已结束会话"
        }
    }
}
