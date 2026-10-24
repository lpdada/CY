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

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                StreamingMeetingControlsView(session: session, translationSession: translationSession, showingRename: $showingRename)
                if !session.status.isEmpty {
                    Text(session.status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if session.isSummarizing {
                    HStack(spacing: 6) {
                        ProgressView()
                        Text("总结中…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                if let summary = session.summary {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("总结（\(session.summaryLanguage.displayName)）")
                            .font(.headline)
                        SummarySectionsView(text: summary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                StreamingMeetingSegmentListView(session: session, translationSession: translationSession)
            }
            .padding()
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
        }
    }
}

struct StreamingMeetingControlsView: View {
    @Bindable var session: StreamingMeetingSession
    @Bindable var translationSession: StreamingTranslationSession
    @Binding var showingRename: Bool

    @State private var showingHistory = false
    @State private var isSharing = false
    @State private var shareItems: [Any] = []

    var body: some View {
        VStack(spacing: 12) {
            Picker("语言", selection: $session.language) {
                ForEach(StreamingMeetingSession.Language.allCases, id: \.self) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .pickerStyle(.segmented)
            .disabled(session.isRunning)

            if session.language == .automatic {
                Text("自动档用多语模型记录中、日、英混合发言；行首语种标签按文字脚本推断，仅供参考")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Text("说话人由服务器声纹区分（A、B、C…动态扩展），临时文本先出、定稿再纠")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                if session.isRunning {
                    Button("停止", role: .destructive) {
                        Task { await session.stop() }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("开始记录") {
                        Task { await session.start() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!session.hasSelfHostedKey)
                }
                Button("说话人改名") {
                    showingRename = true
                }
                .buttonStyle(.bordered)
                .disabled(session.knownSpeakerLabels.isEmpty)
            }

            // Translation switch (on by default, preserving the
            // previous always-on behavior) plus its target language.
            // Switching on backfills finals that have no translation
            // yet; changing the target re-translates everything.
            Toggle("翻译", isOn: $translationSession.isEnabled)
            if translationSession.isEnabled {
                Picker("翻译目标语言", selection: $translationSession.targetLanguage) {
                    ForEach([StreamingTranslationSession.Language.chinese,
                             StreamingTranslationSession.Language.japanese,
                             StreamingTranslationSession.Language.english], id: \.self) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .pickerStyle(.segmented)
            }

            Picker("总结语言", selection: $session.summaryLanguage) {
                ForEach(MeetingSummarizer.Language.allCases, id: \.self) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .pickerStyle(.segmented)
            .disabled(session.isRunning || session.isSummarizing)

            HStack(spacing: 12) {
                Button("总结") {
                    Task { await session.summarize() }
                }
                .buttonStyle(.bordered)
                .disabled(session.segments.isEmpty || session.isRunning || session.isSummarizing)
                Menu("分享") {
                    Button("导出 TXT") { share(format: .txt) }
                    Button("导出 PDF") { share(format: .pdf) }
                    Button("导出 HTML") { share(format: .html) }
                }
                .buttonStyle(.bordered)
                .disabled(session.segments.isEmpty || session.isRunning)
                Button("历史") {
                    showingHistory = true
                }
                .buttonStyle(.bordered)
                .disabled(session.aiService == nil)
            }
        }
        .onChange(of: translationSession.isEnabled) { _, enabled in
            if enabled {
                session.retranslateAllFinals()
            }
        }
        .onChange(of: translationSession.targetLanguage) { _, _ in
            translationSession.reset()
            session.retranslateAllFinals()
        }
        .sheet(isPresented: $showingHistory) {
            if let aiService = session.aiService {
                MeetingHistoryView(aiService: aiService)
            }
        }
        .sheet(isPresented: $isSharing) {
            ActivityView(activityItems: shareItems)
        }
    }

    /// Shares the current session as a saved record (same exporter
    /// the history view uses). Only after stop: sharing mid-session
    /// would snapshot a moving transcript.
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
                LazyVStack(alignment: .leading, spacing: 12) {
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
            }
            .onChange(of: session.segments.count) { _, _ in
                if let lastID = session.segments.last?.id {
                    withAnimation {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
        }
    }
}

struct StreamingMeetingSegmentRowView: View {
    let segment: StreamingMeetingSession.Segment
    let displayName: String
    /// Script-heuristic language tag, only in automatic mode
    /// (nil otherwise); indicative only, see detectLanguage.
    let detectedLanguageName: String?
    let translation: String?
    let isTranslating: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(segment.speakerLabel ?? "?")
                    .font(.footnote)
                    .bold()
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(color(for: segment.speakerLabel))
                    .clipShape(Circle())
                Text(displayName)
                    .font(.footnote)
                    .bold()
                if let detectedLanguageName {
                    Text(detectedLanguageName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if segment.isProvisional {
                    Text("临时")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if segment.speakerStatus == .uncertain {
                    Text("不确定")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Text(segment.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(segment.isProvisional ? .secondary : .primary)
                .opacity(segment.isProvisional ? 0.7 : 1)
            if let translation, !translation.isEmpty {
                Text(translation)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if isTranslating {
                Text("翻译中…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
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
