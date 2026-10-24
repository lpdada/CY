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
                    SummarySectionsView(text: summary)
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
            Toggle("双向对话", isOn: $session.isConversationMode)
                .disabled(session.isRunning)
            HStack(spacing: 8) {
                Picker(session.isConversationMode ? "语言 A" : "源语言", selection: $session.sourceLanguage) {
                    ForEach(SelfHostedTranslationSession.Language.allCases, id: \.self) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .pickerStyle(.menu)
                Image(systemName: session.isConversationMode ? "arrow.left.arrow.right" : "arrow.right")
                    .foregroundStyle(.secondary)
                Picker(session.isConversationMode ? "语言 B" : "目标语言", selection: $session.targetLanguage) {
                    ForEach(SelfHostedTranslationSession.Language.allCases, id: \.self) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .pickerStyle(.menu)
            }
            .disabled(session.isRunning)

            if session.isConversationMode {
                Text("每句话按文字自动识别是 A 还是 B，翻成另一种语言；纯汉字默认按中文处理（日语口语通常带假名），中英混说或第三种语言无法判定时，沿用上一句的方向。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Picker("转写模型", selection: $session.asrModelName) {
                ForEach(selfHostedModels) { model in
                    Text(model.displayName).tag(model.name)
                }
            }
            .pickerStyle(.menu)
            .disabled(session.isRunning)

            // 当前选中模型的优点/注意点随选择实时变，选模型不再盲选。
            // 说明文字直接取模型自带的中文介绍，不另写一套，避免两处说法打架。
            if let selectedModel = selfHostedModels.first(where: { $0.name == session.asrModelName }) {
                Text(selectedModel.description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Text("能听懂哪种语言取决于转写模型：SenseVoice 主要覆盖中英日韩，其他语言请选 Whisper 系模型；翻译本身不受此限制。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Toggle("朗读译文", isOn: $session.ttsEnabled)

            if session.ttsEnabled {
                if session.isConversationMode {
                    TTSVoicePickerRow(language: session.sourceLanguage, serverVoices: session.serverVoices)
                    TTSVoicePickerRow(language: session.targetLanguage, serverVoices: session.serverVoices)
                } else {
                    Picker("朗读声音", selection: $session.ttsVoiceID) {
                        Text("系统默认").tag(nil as String?)
                        ForEach(session.serverVoices.filter { $0.language == session.targetLanguage.rawValue }) { voice in
                            Text(voice.displayName).tag(voice.id as String?)
                        }
                    }
                    .pickerStyle(.menu)
                }
                if let error = session.serverVoicesError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if !session.isConversationMode, session.sourceLanguage == session.targetLanguage {
                Text("源语言与目标语言相同，翻译结果与原文一致")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if session.isConversationMode, session.sourceLanguage == session.targetLanguage {
                Text("语言 A 与语言 B 相同，双向没有意义，请选两种不同的语言")
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
                            if session.isConversationMode {
                                Text("\(pair.sourceLanguage.displayName) → \(pair.targetLanguage.displayName)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
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
                Button("导出 HTML") { share(format: .html) }
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

/// Server-voice picker for one language in conversation mode. The
/// selection is read from and written to the per-language store
/// directly, so each direction can keep its own voice while the
/// session's single `ttsVoiceID` still serves fixed mode.
private struct TTSVoicePickerRow: View {
    let language: SelfHostedTranslationSession.Language
    let serverVoices: [ServerTTSVoice]

    var body: some View {
        Picker("朗读声音（\(language.displayName)）", selection: voiceBinding) {
            Text("系统默认").tag(nil as String?)
            ForEach(serverVoices.filter { $0.language == language.rawValue }) { voice in
                Text(voice.displayName).tag(voice.id as String?)
            }
        }
        .pickerStyle(.menu)
    }

    private var voiceBinding: Binding<String?> {
        Binding(
            get: { ServerTTSVoiceSelection.voiceID(forLanguageCode: language.rawValue) },
            set: { ServerTTSVoiceSelection.setVoiceID($0, forLanguageCode: language.rawValue) }
        )
    }
}
