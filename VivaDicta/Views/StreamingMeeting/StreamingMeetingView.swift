import SwiftUI

/// Streaming meeting notes: server-side voiceprint diarization over
/// WebSocket, interim text first, finals correcting in place.
///
/// Routing: on appear the view probes streaming availability (one
/// connect + auth + ready wait, no audio). While the probe is pending
/// it shows a spinner; if the probe fails, it shows the existing
/// `MeetingNotesView` unchanged (referenced only, never modified)
/// under a one-line fallback note, and the streaming UI never starts.
/// Stopping a streaming session saves through the old
/// `MeetingRecord` / `MeetingRecordStore` shape, so the old history
/// view reads streaming records too.
///
/// View-splitting rule: every sub-view below is its own struct, never
/// a computed property on another view.
///
/// Layout (2026-10 redesign, same language as 自建翻译): the controls
/// that used to stack above the transcript now live in one collapsible
/// bar, the transcript owns the rest of the screen, and start/stop plus
/// the secondary actions sit in a single bottom row. Bindings, disabled
/// rules, probes and export behaviour are unchanged.
struct StreamingMeetingView: View {
    @Environment(AppState.self) private var appState

    @State private var session: StreamingMeetingSession?
    @State private var translationSession: StreamingTranslationSession?
    @State private var streamingAvailable: Bool?

    var body: some View {
        Group {
            if streamingAvailable == false {
                StreamingMeetingFallbackView()
            } else if let session, let translationSession {
                StreamingMeetingContentView(
                    session: session,
                    translationSession: translationSession,
                    streamingAvailable: $streamingAvailable
                )
            } else {
                ProgressView()
            }
        }
        .task {
            if session == nil {
                let meeting = StreamingMeetingSession()
                let translation = StreamingTranslationSession(aiService: appState.aiService)
                meeting.translationSession = translation
                meeting.aiService = appState.aiService
                session = meeting
                translationSession = translation
            }
            if streamingAvailable == nil, let session {
                streamingAvailable = await session.checkStreamingAvailable(language: session.language)
            }
        }
    }
}

/// Fallback branch: the old view, untouched, plus the one-line note.
/// This struct intentionally has no NavigationStack of its own:
/// `MeetingNotesView` brings its own.
struct StreamingMeetingFallbackView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("流式不可用，已回落旧版")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top)
            MeetingNotesView()
        }
    }
}

struct StreamingMeetingContentView: View {
    @Bindable var session: StreamingMeetingSession
    @Bindable var translationSession: StreamingTranslationSession
    /// Written back to the parent so a language switch that turns out
    /// unsupported (e.g. Japanese) routes to the fallback view too,
    /// not just the initial probe.
    @Binding var streamingAvailable: Bool?

    @Environment(\.dismiss) private var dismiss

    @State private var showingRename = false
    @State private var showingSummary = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                StreamingMeetingSettingsBar(
                    session: session,
                    translationSession: translationSession,
                    showingRename: $showingRename
                )
                StreamingMeetingSegmentListView(
                    session: session,
                    translationSession: translationSession
                )
                StreamingMeetingAudioBar(session: session)
                StreamingMeetingBottomBar(
                    session: session,
                    showingSummary: $showingSummary
                )
            }
            .background(Color(.systemGroupedBackground))
            .onChange(of: session.language) { _, newLanguage in
                // Re-probe on language switch (not while running: the
                // picker is disabled then, so this only fires idle).
                // Translation source follows the session language;
                // automatic mode leaves the source out of the prompt.
                translationSession.sourceLanguage = StreamingTranslationSession.Language(rawValue: newLanguage.rawValue) ?? .automatic
                Task {
                    streamingAvailable = await session.checkStreamingAvailable(language: newLanguage)
                }
            }
            .navigationTitle("流式会议记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        // Stop first so a running session finalises and
                        // saves instead of being abandoned on dismiss;
                        // stop() is a no-op when not running.
                        Task {
                            await session.stop()
                            dismiss()
                        }
                    }
                }
            }
            .sheet(isPresented: $showingRename) {
                StreamingSpeakerRenameView(session: session)
            }
            .sheet(isPresented: $showingSummary) {
                StreamingMeetingSummarySheet(session: session)
            }
        }
    }
}

/// One-line settings bar: recording language · translation target, with
/// a chevron that expands the segmented pickers in place. Collapsed by
/// default so the transcript gets the screen; the whole row is the hit
/// target, the chevron is only the affordance.
struct StreamingMeetingSettingsBar: View {
    @Bindable var session: StreamingMeetingSession
    @Bindable var translationSession: StreamingTranslationSession
    @Binding var showingRename: Bool

    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.22)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    Text(summaryLine)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .layoutPriority(1)

                    if session.language == .automatic {
                        miniTag("多语", tint: .purple)
                    }

                    if translationSession.isEnabled {
                        Image(systemName: "character.bubble.fill")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                            .accessibilityHidden(true)
                    }

                    Spacer(minLength: 4)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Color.secondary.opacity(0.12), in: Circle())
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "收起会议设置" : "展开会议设置")

            if isExpanded {
                expandedControls
            }
        }
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
        // 挂在外层：面板收起时开关也不存在，但状态变化仍需触发回填。
        .onChange(of: translationSession.isEnabled) { _, enabled in
            if enabled {
                session.retranslateAllFinals()
            }
        }
        .onChange(of: translationSession.targetLanguage) { _, _ in
            translationSession.reset()
            session.retranslateAllFinals()
        }
    }

    private var expandedControls: some View {
        VStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text("记录语言")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("记录语言", selection: $session.language) {
                    ForEach(StreamingMeetingSession.Language.allCases, id: \.self) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(session.isRunning)
            }

            if session.language == .automatic {
                Text("自动档用多语模型记录中、日、英混合发言；行首语种标签按文字脚本推断，仅供参考")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Translation switch (on by default, preserving the
            // previous always-on behavior) plus its target language.
            // Switching on backfills finals that have no translation
            // yet; changing the target re-translates everything.
            HStack {
                Text("翻译译文")
                    .font(.subheadline)
                Spacer()
                Toggle("翻译译文", isOn: $translationSession.isEnabled)
                    .labelsHidden()
            }
            if translationSession.isEnabled {
                VStack(alignment: .leading, spacing: 5) {
                    Text("翻译目标语言")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("翻译目标语言", selection: $translationSession.targetLanguage) {
                        ForEach([StreamingTranslationSession.Language.chinese,
                                 StreamingTranslationSession.Language.japanese,
                                 StreamingTranslationSession.Language.english], id: \.self) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("总结语言")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("总结语言", selection: $session.summaryLanguage) {
                    ForEach(MeetingSummarizer.Language.allCases, id: \.self) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(session.isRunning || session.isSummarizing)
            }

            if session.hasPolished {
                Button {
                    session.clearPolish()
                } label: {
                    HStack {
                        Text("还原原文")
                            .font(.subheadline)
                        Spacer()
                        Text("已润色 \(polishedCount) 段")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(session.isRunning || session.isPolishing)
            }

            Button {
                showingRename = true
            } label: {
                HStack {
                    Text("说话人改名")
                        .font(.subheadline)
                    Spacer()
                    Text("\(session.knownSpeakerLabels.count) 人")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .disabled(session.knownSpeakerLabels.isEmpty)

            Text("说话人由服务器声纹区分（A、B、C…动态扩展），临时文本先出、定稿再纠")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.top, 2)
        .padding(.bottom, 12)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var polishedCount: Int {
        session.segments.filter { $0.polishedText?.isEmpty == false }.count
    }

    private var summaryLine: String {
        let source = session.language.displayName
        guard translationSession.isEnabled else {
            return "\(source) · 不翻译"
        }
        return "\(source) · 译成\(translationSession.targetLanguage.displayName)"
    }

    private func miniTag(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

/// Bottom row: one 52pt record button, the status line, and the three
/// secondary actions as round icon buttons (总结 / 分享 / 历史).
struct StreamingMeetingBottomBar: View {
    @Bindable var session: StreamingMeetingSession
    @Binding var showingSummary: Bool

    @State private var showingHistory = false
    @State private var isSharing = false
    @State private var shareItems: [Any] = []

    var body: some View {
        HStack(spacing: 12) {
            recordButton

            VStack(alignment: .leading, spacing: 2) {
                if session.isPolishing {
                    HStack(spacing: 5) {
                        ProgressView()
                            .controlSize(.mini)
                        Text(session.polishTotal > 0
                             ? "润色中 \(session.polishDone)/\(session.polishTotal)"
                             : "润色中…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else if session.isSummarizing {
                    HStack(spacing: 5) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("总结中…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else if session.isRunning, !session.status.isEmpty {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(.green)
                            .frame(width: 8, height: 8)
                            .shadow(color: .green.opacity(0.4), radius: 3)
                        Text(session.status)
                            .font(.footnote.weight(.semibold))
                            .lineLimit(1)
                    }
                } else if session.summary != nil {
                    Button {
                        showingSummary = true
                    } label: {
                        Label("已有总结 · 查看", systemImage: "text.append")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                } else if !session.status.isEmpty {
                    Text(session.status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if !session.hasSelfHostedKey {
                    Text("未配置自建服务器")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("待开始")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 4)

            iconButton("wand.and.stars", label: "润色") {
                Task { await session.polish() }
            }
            .disabled(session.segments.isEmpty || session.isRunning
                      || session.isPolishing || session.isSummarizing)

            iconButton("doc.text", label: "总结") {
                Task { await session.summarize() }
            }
            .disabled(session.segments.isEmpty || session.isRunning || session.isSummarizing || session.isPolishing)

            Menu {
                Button("导出 TXT") { share(format: .txt) }
                Button("导出 PDF") { share(format: .pdf) }
                Button("导出 HTML") { share(format: .html) }
                if let audioURL = session.audioURL {
                    Divider()
                    Button("分享录音（WAV）") { shareFile(audioURL) }
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(Color.secondary.opacity(0.12), in: Circle())
            }
            .disabled(session.segments.isEmpty || session.isRunning)
            .accessibilityLabel("分享")

            iconButton("clock.arrow.circlepath", label: "历史") {
                showingHistory = true
            }
            .disabled(session.aiService == nil)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(.bar)
        .sheet(isPresented: $showingHistory) {
            if let aiService = session.aiService {
                MeetingHistoryView(aiService: aiService)
            }
        }
        .sheet(isPresented: $isSharing) {
            ActivityView(activityItems: shareItems)
        }
    }

    private var recordButton: some View {
        Button {
            Task {
                if session.isRunning {
                    await session.stop()
                } else {
                    await session.start()
                }
            }
        } label: {
            Image(systemName: session.isRunning ? "stop.fill" : "mic.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(session.isRunning ? Color.red : Color.blue, in: Circle())
                .shadow(
                    color: (session.isRunning ? Color.red : Color.blue).opacity(0.28),
                    radius: 8,
                    y: 3
                )
        }
        .buttonStyle(.plain)
        .disabled(!session.isRunning && (!session.hasSelfHostedKey || session.isPolishing))
        .opacity(!session.isRunning && (!session.hasSelfHostedKey || session.isPolishing) ? 0.45 : 1)
        .accessibilityLabel(session.isRunning ? "停止记录" : "开始记录")
    }

    private func iconButton(
        _ systemName: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 36, height: 36)
                .background(Color.secondary.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// Shares the current session as a saved record (same exporter
    /// the history view uses). Only after stop: sharing mid-session
    /// would snapshot a moving transcript.
    private func shareFile(_ url: URL) {
        shareItems = [url]
        isSharing = true
    }

    private func share(format: MeetingRecordExporter.Format) {
        guard let record = session.makeRecord(), !record.segments.isEmpty else { return }
        do {
            let url = try MeetingRecordExporter.fileURL(for: record, format: format)
            shareItems = [url]
            isSharing = true
        } catch {
            session.status = "导出失败：\(error.localizedDescription)"
        }
    }
}

struct StreamingMeetingSegmentListView: View {
    @Bindable var session: StreamingMeetingSession
    @Bindable var translationSession: StreamingTranslationSession

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if session.segments.isEmpty {
                        emptyState
                    }
                    ForEach(session.segments) { segment in
                        StreamingMeetingSegmentRowView(
                            segment: segment,
                            displayName: session.displayName(for: segment.speakerLabel),
                            detectedLanguageName: session.language == .automatic ? segment.detectedLanguage.displayName : nil,
                            translation: translationSession.isEnabled ? translationSession.translation(for: segment.segmentID)?.translation : nil,
                            isTranslating: translationSession.isEnabled && (translationSession.translation(for: segment.segmentID)?.isTranslating ?? false)
                        )
                        .id(segment.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .scrollIndicators(.hidden)
            .onChange(of: session.segments.count) { _, _ in
                if let lastID = session.segments.last?.id {
                    withAnimation {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: session.hasSelfHostedKey ? "waveform" : "server.rack")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(session.hasSelfHostedKey ? "点下方麦克风开始记录" : "先配置自建服务器")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 70)
    }
}


/// The session's audio: a live level strip while recording, then a
/// player for the single WAV that runs from start to stop. One file per
/// meeting, saved next to the record, so it survives app restarts.
struct StreamingMeetingAudioBar: View {
    let session: StreamingMeetingSession

    private var bars: [Float] {
        Array(session.waveform.suffix(48))
    }

    var body: some View {
        if session.isRunning || session.audioURL != nil {
            VStack(spacing: 4) {
                HStack(spacing: 10) {
                    playButton

                    waveform

                    Text(timeLabel)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }

                if !session.isRunning, session.audioDuration > 0 {
                    Slider(
                        value: Binding(
                            get: { session.playbackTime },
                            set: { session.seekAudio(to: $0) }
                        ),
                        in: 0...max(session.audioDuration, 0.1)
                    )
                    .controlSize(.mini)
                    .tint(.accentColor)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.thinMaterial)
        }
    }

    private var playButton: some View {
        Button {
            session.toggleAudioPlayback()
        } label: {
            Image(systemName: iconName)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color(.secondarySystemBackground)))
        }
        .buttonStyle(.plain)
        .disabled(session.isRunning || session.audioURL == nil)
        .opacity(session.isRunning || session.audioURL == nil ? 0.5 : 1)
        .accessibilityLabel(session.isPlayingAudio ? "暂停录音" : "播放录音")
    }

    private var iconName: String {
        if session.isRunning { return "waveform" }
        return session.isPlayingAudio ? "pause.fill" : "play.fill"
    }

    private var waveform: some View {
        GeometryReader { geometry in
            let count = max(bars.count, 1)
            let barWidth = max(1.5, (geometry.size.width - CGFloat(count - 1) * 1.5) / CGFloat(count))
            HStack(alignment: .center, spacing: 1.5) {
                ForEach(Array(bars.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(Color.accentColor.opacity(session.isRunning ? 0.85 : 0.5))
                        .frame(width: barWidth,
                               height: max(2, CGFloat(level) * geometry.size.height))
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(height: 22)
    }

    private var timeLabel: String {
        if session.isRunning {
            return Self.format(session.elapsed)
        }
        guard session.audioDuration > 0 else { return "" }
        return "\(Self.format(session.playbackTime)) / \(Self.format(session.audioDuration))"
    }

    private static func format(_ time: TimeInterval) -> String {
        let total = Int(time.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// One segment as a card: speaker badge + name on top, the transcript
/// text as the main content, the translation (when on) as a small
/// secondary line underneath.
struct StreamingMeetingSegmentRowView: View {
    let segment: StreamingMeetingSession.Segment
    let displayName: String
    /// Script-heuristic language tag, only in automatic mode
    /// (nil otherwise); indicative only, see detectLanguage.
    let detectedLanguageName: String?
    let translation: String?
    let isTranslating: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(segment.speakerLabel ?? "?")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(color(for: segment.speakerLabel))
                    .clipShape(Circle())
                Text(displayName)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                if let detectedLanguageName {
                    Text(detectedLanguageName)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                        .foregroundStyle(.secondary)
                }
                if segment.isProvisional {
                    Text("临时")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if segment.speakerStatus == .uncertain {
                    Text("不确定")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.orange)
                }
                Spacer(minLength: 0)
            }
            if let polished = segment.polishedText, !polished.isEmpty {
                // 润色稿在前，原文以一行小字保留：润色只改可读性，
                // 用户仍能对照 ASR 原样记录。
                Text(polished)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .font(.body)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                (Text("原文 · ").foregroundStyle(.tertiary)
                 + Text(segment.text).foregroundStyle(.secondary))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .font(.caption)
            } else {
                Text(segment.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .font(.body)
                    .lineSpacing(2)
                    .foregroundStyle(segment.isProvisional ? .secondary : .primary)
                    .opacity(segment.isProvisional ? 0.7 : 1)
                    .textSelection(.enabled)
            }
            if let translation, !translation.isEmpty {
                Text(translation)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if isTranslating {
                HStack(spacing: 5) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("翻译中…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.white, in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.04), radius: 4, y: 1)
    }

    /// Deterministic badge colour from the label (sum of scalars, not
    /// `hashValue`, which is randomised per launch and would recolour
    /// every row on restart).
    private func color(for label: String?) -> Color {
        let palette: [Color] = [.blue, .orange, .green, .purple, .pink]
        guard let label else { return .gray }
        let sum = label.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palette[sum % palette.count]
    }
}

/// Summary in a sheet: it used to sit above the transcript and eat the
/// space the transcript now needs.
struct StreamingMeetingSummarySheet: View {
    @Bindable var session: StreamingMeetingSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Group {
                    if let summary = session.summary {
                        SummarySectionsView(text: summary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("总结（\(session.summaryLanguage.displayName)）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

/// Rename sheet: pick a label seen in this session, set its display
/// name. Only the session's display map changes; segment labels are
/// untouched, so all rows with that label show the new name at once
/// with no re-clustering. An empty name clears the rename.
struct StreamingSpeakerRenameView: View {
    @Bindable var session: StreamingMeetingSession
    @Environment(\.dismiss) private var dismiss

    @State private var selectedLabel = ""
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            Form {
                Picker("说话人", selection: $selectedLabel) {
                    ForEach(session.knownSpeakerLabels, id: \.self) { label in
                        Text(session.displayName(for: label)).tag(label)
                    }
                }
                TextField("显示名（留空恢复默认）", text: $newName)
                Button("保存") {
                    session.renameSpeaker(oldLabel: selectedLabel, newName: newName)
                    dismiss()
                }
                .disabled(selectedLabel.isEmpty)
            }
            .navigationTitle("说话人改名")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear {
                if selectedLabel.isEmpty, let first = session.knownSpeakerLabels.first {
                    selectedLabel = first
                    newName = session.customName(for: first) ?? ""
                }
            }
            .onChange(of: selectedLabel) { _, newLabel in
                newName = session.customName(for: newLabel) ?? ""
            }
        }
    }
}