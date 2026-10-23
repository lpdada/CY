import SwiftUI

/// Self-hosted sentence translation: mic -> silence chunking -> the
/// user's own ASR server -> AI translation -> bilingual list, with
/// optional TTS readout. Stopped sessions auto-save to
/// Documents/TranslationSessions; open 历史 for past records, export,
/// share, or one-tap AI summary.
struct SelfHostedTranslationView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var session: SelfHostedTranslationSession?
    @State private var hasSelfHostedKey = SelfHostedTranscriptionConfig.apiKey != nil
    @State private var showingConfig = false

    private var selfHostedModels: [CloudModel] {
        TranscriptionModelProvider.allCloudModels.filter { $0.provider == .selfHosted }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let session {
                    SelfHostedTranslationContentView(
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
            .navigationTitle("自建翻译")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .onAppear {
                if session == nil {
                    session = SelfHostedTranslationSession(aiService: appState.aiService)
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

private struct SelfHostedTranslationContentView: View {
    @Bindable var session: SelfHostedTranslationSession
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
                    Text("总结")
                        .font(.headline)
                    Text(summary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            pairsList
            startStopButton
            actionRow
        }
        .padding()
        .task {
            await session.refreshServerVoices()
        }
        .sheet(isPresented: $showingHistory) {
            TranslationHistoryView(aiService: aiService)
        }
        .sheet(isPresented: $isSharing) {
            ActivityView(activityItems: shareItems)
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Picker("源语言", selection: $session.sourceLanguage) {
                    ForEach(SelfHostedTranslationSession.Language.allCases, id: \.self) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .pickerStyle(.segmented)
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                Picker("目标语言", selection: $session.targetLanguage) {
                    ForEach(SelfHostedTranslationSession.Language.allCases, id: \.self) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .pickerStyle(.segmented)
            }
            .disabled(session.isRunning)

            Picker("转写模型", selection: $session.asrModelName) {
                ForEach(selfHostedModels) { model in
                    Text(model.displayName).tag(model.name)
                }
            }
            .pickerStyle(.menu)
            .disabled(session.isRunning)

            Toggle("朗读译文", isOn: $session.ttsEnabled)

            if session.ttsEnabled {
                Picker("朗读声音", selection: $session.ttsVoiceID) {
                    Text("系统默认").tag(nil as String?)
                    ForEach(session.serverVoices.filter { $0.language == session.targetLanguage.rawValue }) { voice in
                        Text(voice.displayName).tag(voice.id as String?)
                    }
                }
                .pickerStyle(.menu)
                if let error = session.serverVoicesError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if session.sourceLanguage == session.targetLanguage {
                Text("源语言与目标语言相同，翻译结果与原文一致")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var pairsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(session.pairs) { pair in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(pair.original)
                                .foregroundStyle(.secondary)
                            if pair.isTranslating {
                                HStack(spacing: 6) {
                                    ProgressView()
                                    Text("翻译中…")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            } else if let translation = pair.translation {
                                Text(translation)
                            } else if let error = pair.error {
                                Text(error)
                                    .foregroundStyle(.red)
                            }
                        }
                        .id(pair.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: session.pairs.count) { _, _ in
                if let lastID = session.pairs.last?.id {
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
                Button("开始翻译") {
                    Task { await session.start() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button("总结") {
                Task { await session.summarize() }
            }
            .buttonStyle(.bordered)
            .disabled(session.pairs.isEmpty || session.isRunning || session.isSummarizing)
            Menu("分享") {
                Button("导出 TXT") { share(format: .txt) }
                Button("导出 PDF") { share(format: .pdf) }
            }
            .buttonStyle(.bordered)
            .disabled(session.pairs.isEmpty || session.isRunning)
            Button("历史") {
                showingHistory = true
            }
            .buttonStyle(.bordered)
        }
    }

    private func share(format: TranslationSessionExporter.Format) {
        guard let record = session.makeRecord() else { return }
        do {
            let url = try TranslationSessionExporter.fileURL(for: record, format: format)
            shareItems = [url]
            isSharing = true
        } catch {
            session.status = "导出失败：\(error.localizedDescription)"
        }
    }
}
