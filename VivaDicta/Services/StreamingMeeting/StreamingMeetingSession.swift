import AVFoundation
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
        /// Script-heuristic language tag for automatic mode (the
        /// server frames carry no language field). Set on every
        /// interim/final update; indicative only, recording itself
        /// is unaffected because the multilingual model hears audio.
        var detectedLanguage: Language
        var confidence: Double?
        var start: Double
        var end: Double
        var corrected: Bool
        /// AI-polished version of `text` (same content, readable
        /// punctuation/wording). Nil until the user taps 润色; `text`
        /// always keeps the raw ASR output.
        var polishedText: String? = nil
    }

    enum Language: String, CaseIterable {
        case chinese = "zh"
        case japanese = "ja"
        case english = "en"
        /// Automatic: the client sends "auto" and the server records
        /// with its multilingual model (Chinese, Japanese, English and
        /// more in one session). Needs the server to accept "auto";
        /// until then the probe fails and the view falls back, exactly
        /// like any other unsupported language.
        case automatic = "auto"

        var displayName: String {
            switch self {
            case .chinese: "中文"
            case .japanese: "日语"
            case .english: "英语"
            case .automatic: "自动"
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
    /// Set by the view from the app state, like `translationSession`.
    /// Summary is unavailable until this is set.
    var aiService: AIService?
    var summaryLanguage: MeetingSummarizer.Language = .chinese
    var summary: String?
    var isSummarizing = false
    /// AI polish (the same `AIService.enhance` path the keyboard and
    /// dictation use) runs over the finals, keeping every sentence.
    var isPolishing = false
    var polishDone = 0
    var polishTotal = 0
    var hasPolished: Bool {
        segments.contains { ($0.polishedText?.isEmpty == false) }
    }
    /// Id of the record saved by `stop()` / server-end, so a later
    /// summary re-saves the same record instead of minting a duplicate
    /// history entry (every `makeRecord()` call otherwise mints a new id).
    private var savedRecordID: UUID?
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
    /// Live level meter (0...1) and a rolling envelope for the audio bar.
    /// Purely visual: diarization never reads it.
    private(set) var audioLevel: Float = 0
    private(set) var waveform: [Float] = []
    /// Seconds recorded in this session (meter ticks at 10 Hz).
    private(set) var elapsed: TimeInterval = 0
    private var meterTask: Task<Void, Never>?
    /// The one WAV from start to stop, persisted with the record.
    private(set) var audioFileName: String?
    private var player: AVAudioPlayer?
    private(set) var isPlayingAudio = false
    private(set) var playbackTime: TimeInterval = 0
    private(set) var audioDuration: TimeInterval = 0
    private var playbackTask: Task<Void, Never>?
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
        summary = nil
        stopPlayback()
        waveform = []
        audioLevel = 0
        elapsed = 0
        audioFileName = nil
        audioDuration = 0
        playbackTime = 0
        isPolishing = false
        polishDone = 0
        polishTotal = 0
        savedRecordID = nil
        streamingUnsupportedLanguage = false
        lastProbeErrorCode = nil
        translationSession?.reset()
        // Translation source follows the session language (in
        // automatic mode the prompt carries no source language, so
        // the AI detects it per segment). Previously this stayed
        // fixed on Chinese even for a Japanese session.
        translationSession?.sourceLanguage = StreamingTranslationSession.Language(rawValue: language.rawValue) ?? .automatic
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
        capture.onInterruption = { [weak self] event in
            guard let self, isRunning else { return }
            switch event {
            case .began:
                status = "音频被打断，等待恢复…"
            case .resumed:
                status = "正在记录（流式）…"
            case .endedWithoutResume:
                status = "音频打断后未能自动恢复，请点停止后重新开始"
            }
        }
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
        startMeter()
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
        stopMeter()
        if var record = makeRecord(), !record.segments.isEmpty {
            record.audioFileName = persistSessionAudio(recordID: record.id)
            audioFileName = record.audioFileName
            savedRecordID = record.id
            loadAudioDuration()
            status = store.save(record) ? "已停止，记录已保存" : "已停止，记录保存失败"
        } else {
            discardSessionAudio()
            status = "已停止"
        }
    }

    /// One-tap AI summary in the chosen language, mirroring the old
    /// meeting session's `summarize()`. It runs after stop (or while
    /// idle with unsaved segments): if the session was already saved,
    /// the summary re-saves that same record id, so history shows one
    /// entry with a summary instead of a second, summary-less copy.
    func summarize() async {
        guard !isSummarizing, !segments.isEmpty, let aiService else {
            if self.aiService == nil, !segments.isEmpty, !isSummarizing {
                status = "总结需要 AI 服务，当前未配置"
            }
            return
        }
        guard let record = makeRecord() else { return }
        isSummarizing = true
        defer { isSummarizing = false }
        do {
            summary = try await MeetingSummarizer.summarize(
                segments: record.segments,
                language: summaryLanguage,
                aiService: aiService
            )
            if let savedRecordID, let updated = makeRecord(id: savedRecordID) {
                _ = store.save(updated)
            }
        } catch {
            logger.logError("流式会议：总结失败：\(error.localizedDescription)")
            status = "总结失败：\(error.localizedDescription)"
        }
    }

    /// Polishes every final segment with the same AI pipeline the
    /// keyboard and dictation use (`AIService.enhance`, i.e. the active
    /// mode's prompt). Content is kept, only the wording/punctuation is
    /// cleaned up — unlike `summarize()`, which condenses.
    ///
    /// Runs one segment per request, sequentially: `enhance` is a chat
    /// completion, and a meeting can hold dozens of finals. Each result
    /// is written into `segment.polishedText` as soon as it lands, so
    /// the list fills in progressively and a later cancel keeps what
    /// already finished. Failures leave that segment on the raw text
    /// and are reported in `status` instead of aborting the run.
    func polish() async {
        guard !isPolishing, !isRunning, let aiService else {
            if aiService == nil, !segments.isEmpty {
                status = "润色需要 AI 服务，当前未配置"
            }
            return
        }
        guard aiService.isProperlyConfigured(requirePreset: false) else {
            status = "润色需要先在 AI 设置里配置好模型"
            return
        }
        let targets = segments.indices.filter {
            !segments[$0].isProvisional && !segments[$0].text.isEmpty
        }
        guard !targets.isEmpty else {
            status = "还没有定稿的段落可以润色"
            return
        }
        isPolishing = true
        polishDone = 0
        polishTotal = targets.count
        defer {
            isPolishing = false
            polishTotal = 0
        }

        var failed = 0
        var requests = 0
        for batch in Self.makePolishBatches(targets, segments: segments) {
            if Task.isCancelled { break }
            let numbered = batch.enumerated().map { offset, index in
                "[\(offset + 1)] \(segments[index].text)"
            }.joined(separator: "\n")
            do {
                let reply = try await aiService.enhanceBatch(
                    numbered, systemMessage: Self.polishSystemPrompt)
                var parsed = Self.parseNumberedPolish(reply, count: batch.count)
                if batch.count == 1, parsed[1] == nil {
                    // 只有一段时，模型常直接答正文、不带编号，整段回复即可。
                    parsed[1] = reply
                }
                for (offset, index) in batch.enumerated() {
                    if let polished = Self.cleanPolished(parsed[offset + 1]),
                       !polished.isEmpty {
                        segments[index].polishedText = polished
                    } else {
                        // 模型漏了/改坏了这一行：保留原文，不猜。
                        failed += 1
                    }
                }
            } catch is CancellationError {
                break
            } catch {
                failed += batch.count
                logger.logError("流式会议：润色批次失败（\(batch.count) 段）：\(error.localizedDescription)")
            }
            requests += 1
            polishDone += batch.count
        }

        if let savedRecordID, let updated = makeRecord(id: savedRecordID) {
            _ = store.save(updated)
        }
        if failed == 0 {
            status = "已润色 \(polishDone) 段（\(requests) 次请求）"
        } else if polishDone == failed {
            status = "润色失败，\(failed) 段保留原文"
        } else {
            status = "润色完成，\(failed) 段失败（保留原文）"
        }
    }

    /// One request per batch. The limits are output-side, not input-side:
    /// the model must echo every line back, and past ~2000 characters of
    /// output it starts dropping or merging lines (which we then have to
    /// keep raw). 25 lines / 2000 characters keeps a 30-minute meeting
    /// (roughly 6000–9000 characters) at 4–6 requests, while staying
    /// inside that safe output size.
    static let polishBatchSize = 25
    static let polishBatchCharacters = 2000

    /// Splits the finals into batches without breaking order. A single
    /// oversized line gets its own batch rather than being truncated.
    static func makePolishBatches(_ indices: [Int], segments: [Segment]) -> [[Int]] {
        var batches: [[Int]] = []
        var current: [Int] = []
        var characters = 0
        for index in indices {
            let length = segments[index].text.count
            if !current.isEmpty,
               current.count >= polishBatchSize || characters + length > polishBatchCharacters {
                batches.append(current)
                current = []
                characters = 0
            }
            current.append(index)
            characters += length
        }
        if !current.isEmpty {
            batches.append(current)
        }
        return batches
    }

    /// Parses `[n] text` lines back into 1-based slots. Continuation
    /// lines without a number belong to the previous slot; a missing
    /// slot simply stays absent so the caller keeps the raw text.
    static func parseNumberedPolish(_ reply: String, count: Int) -> [Int: String] {
        var result: [Int: String] = [:]
        for rawLine in reply.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // 只认带编号的行。无编号的行一律忽略：宁可这一段保留原文，
            // 也不能把它拼到上一段去（实测模型折行时会那样串段）。
            if let (number, text) = numberedLine(line), number >= 1, number <= count {
                result[number] = text
            }
        }
        return result
    }

    /// 去掉模型爱加的包裹符号（引号、反引号、行首的「润色：」）。
    static func cleanPolished(_ text: String?) -> String? {
        guard var value = text?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        for marker in ["润色：", "润色:", "Polish:", "润色后的文本："] where value.hasPrefix(marker) {
            value.removeFirst(marker.count)
            value = value.trimmingCharacters(in: .whitespaces)
        }
        while let first = value.first, ["\"", "“", "「", "`", "*"].contains(String(first)) {
            value.removeFirst()
        }
        while let last = value.last, ["\"", "”", "」", "`", "*"].contains(String(last)) {
            value.removeLast()
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func numberedLine(_ line: String) -> (Int, String)? {
        var text = line
        // 容忍 "- [1] …"、"• [1] …"、"**[1]** …" 这类列表装饰。
        for prefix in ["- ", "* ", "• ", "**"] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        guard text.hasPrefix("["), let close = text.firstIndex(of: "]") else { return nil }
        let digits = text[text.index(after: text.startIndex)..<close]
        guard let number = Int(digits.trimmingCharacters(in: .whitespaces)) else { return nil }
        var rest = String(text[text.index(after: close)...])
            .trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("：") || rest.hasPrefix(":") {
            rest.removeFirst()
        }
        rest = rest.replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespaces)
        return (number, rest)
    }

    /// 固定润色提示词：不套用当前「模式」的预设，因为预设可能是总结/翻译，
    /// 那会把多行压缩或改写语言，破坏逐段映射。
    static let polishSystemPrompt = """
    你是会议记录润色助手。用户给你若干行带编号的语音转写文本，可能中、日、英混排。

    逐行只做三件事：补全标点并合理断句；去掉口头语、语气词和重复；修正明显的同音字错别字。

    绝对不要：合并或拆分任何一行；删减信息；总结或概括；翻译（中文行输出中文，日语行输出日语，英语行输出英语）。

    输出格式：行数与输入完全相同，每行以 [编号] 开头，空一格后接润色后的文本；每段必须保持一行，不要折行。
    只输出这些行，不要解释、标题、代码块或多余空行。
    """

    /// Drops every polished version, restoring the raw transcript.
    func clearPolish() {
        for index in segments.indices {
            segments[index].polishedText = nil
        }
        status = "已还原原文"
        if let savedRecordID, let updated = makeRecord(id: savedRecordID) {
            _ = store.save(updated)
        }
    }

    // MARK: - Audio：整场一个 WAV，从开始到结束

    /// Persisted audio for this session (nil before stop, or if the
    /// recording failed).
    var audioURL: URL? {
        guard let audioFileName else { return nil }
        return store.audioURL(fileName: audioFileName)
    }

    /// Ticks the level meter at 10 Hz while recording: feeds the live
    /// waveform and the elapsed-time label. Purely visual.
    private func startMeter() {
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, self.isRunning else { return }
                let level = self.capture?.currentAudioLevel ?? 0
                self.audioLevel = level
                self.elapsed += 0.1
                self.waveform.append(level)
                if self.waveform.count > 900 {
                    self.waveform.removeFirst(self.waveform.count - 900)
                }
            }
        }
    }

    private func stopMeter() {
        meterTask?.cancel()
        meterTask = nil
        audioLevel = 0
    }

    /// Moves the session WAV next to its JSON so history keeps the audio.
    private func persistSessionAudio(recordID: UUID) -> String? {
        guard let url = sessionWAVURL else { return nil }
        let name = store.importAudio(from: url, recordID: recordID)
        if name == nil {
            try? FileManager.default.removeItem(at: url)
        }
        sessionWAVURL = nil
        return name
    }

    private func discardSessionAudio() {
        if let url = sessionWAVURL {
            try? FileManager.default.removeItem(at: url)
        }
        sessionWAVURL = nil
    }

    /// Reads the duration without starting playback.
    private func loadAudioDuration() {
        guard let url = audioURL else {
            audioDuration = 0
            return
        }
        audioDuration = (try? AVAudioPlayer(contentsOf: url))?.duration ?? 0
    }

    func toggleAudioPlayback() {
        if let player, player.isPlaying {
            player.pause()
            playbackTask?.cancel()
            playbackTask = nil
            isPlayingAudio = false
            return
        }
        if player == nil, let url = audioURL {
            // 录音刚结束时 session 还是 playAndRecord，切到 playback 才能出声。
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .default, options: [.duckOthers])
            try? session.setActive(true)
            player = try? AVAudioPlayer(contentsOf: url)
            player?.prepareToPlay()
            audioDuration = player?.duration ?? audioDuration
        }
        guard let player else { return }
        if player.currentTime >= player.duration - 0.05 {
            player.currentTime = 0
        }
        player.play()
        isPlayingAudio = true
        playbackTask?.cancel()
        playbackTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, let player = self.player, player.isPlaying else { return }
                self.playbackTime = player.currentTime
            }
        }
    }

    func seekAudio(to time: TimeInterval) {
        if player == nil, let url = audioURL {
            player = try? AVAudioPlayer(contentsOf: url)
            player?.prepareToPlay()
            audioDuration = player?.duration ?? audioDuration
        }
        guard let player else { return }
        let clamped = min(max(0, time), max(0, audioDuration))
        player.currentTime = clamped
        playbackTime = clamped
    }

    func stopPlayback() {
        player?.stop()
        player = nil
        playbackTask?.cancel()
        playbackTask = nil
        isPlayingAudio = false
        playbackTime = 0
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
    func makeRecord(id: UUID? = nil) -> MeetingRecord? {
        guard let startedAt else { return nil }
        let segmentRecords = segments
            .filter { !$0.text.isEmpty }
            // 润色过的段用润色稿入档（润色只改可读性、不删内容）；
            // 原文仍留在 segment.text 里供界面「原文」行显示。
            .map { MeetingSegmentRecord(speaker: displayName(for: $0.speakerLabel),
                                        text: $0.polishedText ?? $0.text) }
        return MeetingRecord(
            id: id ?? UUID(),
            startedAt: startedAt,
            asrModelName: asrModelName,
            segments: segmentRecords,
            summary: summary,
            summaryLanguage: summary?.isEmpty == false ? summaryLanguage.rawValue : nil
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

    /// Script heuristic for the per-row language tag in automatic
    /// mode. Kana means Japanese; CJK ideographs without kana mean
    /// Chinese; Latin letters mean English. Pure-kanji Japanese
    /// misreads as Chinese, and anything else defaults to Chinese:
    /// the tag is indicative only, never fed back into recognition.
    static func detectLanguage(for text: String) -> Language {
        for scalar in text.unicodeScalars {
            if (0x3040...0x309F).contains(scalar.value) || (0x30A0...0x30FF).contains(scalar.value) {
                return .japanese
            }
        }
        for scalar in text.unicodeScalars {
            if (0x4E00...0x9FFF).contains(scalar.value) {
                return .chinese
            }
        }
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if (0x41...0x5A).contains(value) || (0x61...0x7A).contains(value) {
                return .english
            }
        }
        return .chinese
    }

    /// Re-translates every final segment that has no translation yet.
    /// Used when translation is switched on mid-session, or after the
    /// target language changes (the caller resets first, so every
    /// final re-translates to the new target). Each segment runs as
    /// its own task, like the live forward, so a slow translation
    /// never stalls the caller.
    func retranslateAllFinals() {
        guard let translationSession, translationSession.isEnabled else { return }
        for segment in segments where !segment.isProvisional && !segment.text.isEmpty {
            if let existing = translationSession.translation(for: segment.segmentID),
               !existing.translation.isEmpty {
                continue
            }
            Task { await translationSession.handleFinalSegment(segment) }
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
                segments[index].detectedLanguage = Self.detectLanguage(for: text)
                segments[index].start = start
                segments[index].end = end
            } else {
                segments.append(Segment(
                    segmentID: segmentID,
                    text: text,
                    speakerLabel: speakerLabel,
                    isProvisional: true,
                    speakerStatus: .provisional,
                    detectedLanguage: Self.detectLanguage(for: text),
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
                segments[index].polishedText = nil  // 文本变了，旧润色稿作废
                segments[index].speakerLabel = speakerLabel
                segments[index].isProvisional = false
                segments[index].speakerStatus = status
                segments[index].detectedLanguage = Self.detectLanguage(for: text)
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
                    detectedLanguage: Self.detectLanguage(for: text),
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
        stopMeter()
        discardSessionAudio()
    }

    private func finishAfterServerEnd(savedStatus: String) async {
        isRunning = false
        await capture?.stop()
        await forwardTask?.value
        forwardTask = nil
        capture = nil
        stopMeter()
        if var record = makeRecord(), !record.segments.isEmpty {
            record.audioFileName = persistSessionAudio(recordID: record.id)
            audioFileName = record.audioFileName
            savedRecordID = record.id
            loadAudioDuration()
            status = store.save(record) ? savedStatus : savedStatus + "，但记录保存失败"
        } else {
            discardSessionAudio()
            status = "服务器已结束会话"
        }
    }
}
