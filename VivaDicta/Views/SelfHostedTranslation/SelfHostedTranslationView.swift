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
        VStack(spacing: 12) {
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
        VStack(spacing: 8) {
            // 双向对话开关与语言选择并成一行：上面每省一行，
            // 下面的实时字幕区就多一行。
            HStack(spacing: 8) {
                Toggle("双向对话", isOn: $session.isConversationMode)
                    .fixedSize()
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

            // 转写模型与朗读开关并成一行；朗读开关运行中也可拨动，
            // 声音切换不依赖开关重拨。
            HStack(spacing: 8) {
                Picker("转写模型", selection: $session.asrModelName) {
                    ForEach(selfHostedModels) { model in
                        Text(model.displayName).tag(model.name)
                    }
                }
                .pickerStyle(.menu)
                .disabled(session.isRunning)
                Spacer()
                Toggle("朗读译文", isOn: $session.ttsEnabled)
                    .fixedSize()
            }

            if session.ttsEnabled {
                if session.isConversationMode {
                    TTSVoicePickerRow(language: session.sourceLanguage, serverVoices: session.serverVoices) {
                        session.voiceSelectionChanged(for: session.sourceLanguage)
                    }
                    TTSVoicePickerRow(language: session.targetLanguage, serverVoices: session.serverVoices) {
                        session.voiceSelectionChanged(for: session.targetLanguage)
                    }
                } else {
                    Picker("朗读声音", selection: fixedVoiceBinding) {
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

    /// Fixed-mode voice binding: writing the store alone is what the
    /// old picker did, but a voice picked while readout is on must
    /// also stop the old voice at once, so the change goes through
    /// voiceSelectionChanged(for:) instead of only persisting.
    private var fixedVoiceBinding: Binding<String?> {
        Binding(
            get: { session.ttsVoiceID },
            set: {
                session.ttsVoiceID = $0
                session.voiceSelectionChanged(for: session.targetLanguage)
            }
        )
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
/// onVoiceChange fires after the store write so a voice picked while
/// readout is on stops the old voice at once (see voiceSelectionChanged).
private struct TTSVoicePickerRow: View {
    let language: SelfHostedTranslationSession.Language
    let serverVoices: [ServerTTSVoice]
    let onVoiceChange: () -> Void

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
            set: {
                ServerTTSVoiceSelection.setVoiceID($0, forLanguageCode: language.rawValue)
                onVoiceChange()
            }
        )
    }
}
