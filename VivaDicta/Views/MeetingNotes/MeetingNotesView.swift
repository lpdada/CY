import SwiftUI

/// Live meeting notes: mic -> silence chunking -> the user's own ASR
/// server -> speaker-labelled segments (A = near / phone holder,
/// B = far / other speaker, by a volume heuristic), with an optional AI
/// summary afterwards in a chosen language. Stopped sessions auto-save
/// to Documents/MeetingNotes; open 历史 for past records.
struct MeetingNotesView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var session: MeetingNotesSession?
    @State private var hasSelfHostedKey = SelfHostedTranscriptionConfig.apiKey != nil
    @State private var showingConfig = false

    private var selfHostedModels: [CloudModel] {
        TranscriptionModelProvider.allCloudModels.filter { $0.provider == .selfHosted }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let session {
                    MeetingNotesContentView(
                        session: session,
                        aiService: appState.aiService,
                        selfHostedModels: selfHostedModels,
                        hasSelfHostedKey: hasSelfHostedKey,
                        onConfigureKey: { showingConfig = true }
                    )
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("会议记录")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .onAppear {
                if session == nil {
                    session = MeetingNotesSession(aiService: appState.aiService)
                }
                hasSelfHostedKey = SelfHostedTranscriptionConfig.apiKey != nil
            }
            .sheet(isPresented: $showingConfig) {
                if let model = selfHostedModels.first {
                    CloudModelConfigurationView(model: model, aiService: appState.aiService) { _ in
                        hasSelfHostedKey = SelfHostedTranscriptionConfig.apiKey != nil
                    }
                }
            }
        }
    }
}

private struct MeetingNotesContentView: View {
    @Bindable var session: MeetingNotesSession
    let aiService: AIService
    let selfHostedModels: [CloudModel]
    let hasSelfHostedKey: Bool
    let onConfigureKey: () -> Void

    @State private var showingHistory = false
    @State private var isSharing = false
    @State private var shareItems: [Any] = []

    var body: some View {
        VStack(spacing: 16) {
            controls
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
            segmentsList
            startStopButton
            actionRow
        }
        .padding()
        .sheet(isPresented: $showingHistory) {
            MeetingHistoryView(aiService: aiService)
        }
        .sheet(isPresented: $isSharing) {
            ActivityView(activityItems: shareItems)
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            Picker("转写模型", selection: $session.asrModelName) {
                ForEach(selfHostedModels) { model in
                    Text(model.displayName).tag(model.name)
                }
            }
            .pickerStyle(.menu)
            .disabled(session.isRunning)

            Text("A：离手机近（我）  B：离手机远（对方），按音量区分")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var segmentsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(session.segments) { segment in
                        HStack(alignment: .top, spacing: 8) {
                            Text(segment.speaker)
                                .font(.footnote)
                                .bold()
                                .foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(segment.speaker == "A" ? Color.blue : Color.orange)
                                .clipShape(Circle())
                            Text(segment.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
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

    private var startStopButton: some View {
        Group {
            if !hasSelfHostedKey {
                Button("配置自建服务器") {
                    onConfigureKey()
                }
                .buttonStyle(.borderedProminent)
            } else if session.isRunning {
                Button("停止", role: .destructive) {
                    Task { await session.stop() }
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("开始记录") {
                    Task { await session.start() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var actionRow: some View {
        VStack(spacing: 12) {
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
            }
        }
    }

    private func share(format: MeetingRecordExporter.Format) {
        guard let record = session.makeRecord() else { return }
        do {
            let url = try MeetingRecordExporter.fileURL(for: record, format: format)
            shareItems = [url]
            isSharing = true
        } catch {
            session.status = "导出失败：\(error.localizedDescription)"
        }
    }
}
