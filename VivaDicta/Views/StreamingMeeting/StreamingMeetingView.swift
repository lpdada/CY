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
                StreamingMeetingControlsView(session: session, showingRename: $showingRename)
                if !session.status.isEmpty {
                    Text(session.status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                StreamingMeetingSegmentListView(session: session, translationSession: translationSession)
            }
            .padding()
            .onChange(of: session.language) { _, newLanguage in
                // Re-probe on language switch (not while running: the
                // picker is disabled then, so this only fires idle).
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
    @Binding var showingRename: Bool

    var body: some View {
        VStack(spacing: 12) {
            Picker("语言", selection: $session.language) {
                ForEach(StreamingMeetingSession.Language.allCases, id: \.self) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .pickerStyle(.segmented)
            .disabled(session.isRunning)

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
                            translation: translationSession.translation(for: segment.segmentID)?.translation,
                            isTranslating: translationSession.translation(for: segment.segmentID)?.isTranslating ?? false
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
