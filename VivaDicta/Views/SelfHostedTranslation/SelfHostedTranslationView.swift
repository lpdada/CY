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
            ListeningStatusView(status: session.status, isRunning: session.isRunning)
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
                .padding()
                .background(.white)
                .clipShape(.rect(cornerRadius: 16))
                .shadow(color: .black.opacity(0.05), radius: 4, y: 1)
            }
            pairsList
            startStopButton
            actionRow
        }
        .padding()
        .background(Color(.systemGroupedBackground))
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

    /// Control card: everything that configures the session lives in
    /// one white card, so the live subtitles below it get the space.
    /// Only the card styling is new here; every binding, disabled
    /// rule, and warning below keeps its previous behavior.
    private var controls: some View {
        VStack(spacing: 8) {
            VStack(spacing: 0) {
                Toggle("双向对话", isOn: $session.isConversationMode)
                    .padding(.vertical, 10)
                Divider()
                LanguagePillRow(
                    sourceLanguage: $session.sourceLanguage,
                    targetLanguage: $session.targetLanguage,
                    isConversationMode: session.isConversationMode,
                    disabled: session.isRunning
                )
                Divider()
                LabeledPickerRow(label: "转写模型") {
                    Picker("转写模型", selection: $session.asrModelName) {
                        ForEach(selfHostedModels) { model in
                            Text(model.displayName).tag(model.name)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .disabled(session.isRunning)
                }
                Divider()
                // 朗读开关运行中也可拨动，声音切换不依赖开关重拨。
                Toggle("朗读译文", isOn: $session.ttsEnabled)
                    .padding(.vertical, 10)
                if session.ttsEnabled {
                    Divider()
                    if session.isConversationMode {
                        LabeledPickerRow(label: "朗读声音（\(session.sourceLanguage.displayName)）") {
                            TTSVoicePickerRow(language: session.sourceLanguage, serverVoices: session.serverVoices) {
                                session.voiceSelectionChanged(for: session.sourceLanguage)
                            }
                        }
                        Divider()
                        LabeledPickerRow(label: "朗读声音（\(session.targetLanguage.displayName)）") {
                            TTSVoicePickerRow(language: session.targetLanguage, serverVoices: session.serverVoices) {
                                session.voiceSelectionChanged(for: session.targetLanguage)
                            }
                        }
                    } else {
                        LabeledPickerRow(label: "朗读声音") {
                            Picker("朗读声音", selection: fixedVoiceBinding) {
                                Text("系统默认").tag(nil as String?)
                                ForEach(session.serverVoices.filter { $0.language == session.targetLanguage.rawValue }) { voice in
                                    Text(voice.displayName).tag(voice.id as String?)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .background(.white)
            .clipShape(.rect(cornerRadius: 18))
            .shadow(color: .black.opacity(0.06), radius: 10, y: 2)

            if session.ttsEnabled, let error = session.serverVoicesError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(session.pairs) { pair in
                        PairCardView(
                            pair: pair,
                            showDirection: session.isConversationMode,
                            isReverse: session.isConversationMode && pair.sourceLanguage == session.targetLanguage
                        )
                        .id(pair.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
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
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(.blue)
                .foregroundStyle(.white)
                .clipShape(.rect(cornerRadius: 14))
            } else if session.isRunning {
                Button("停止", role: .destructive) {
                    Task { await session.stop() }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(.red)
                .foregroundStyle(.white)
                .clipShape(.rect(cornerRadius: 14))
            } else {
                Button("开始翻译") {
                    Task { await session.start() }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(.blue)
                .foregroundStyle(.white)
                .clipShape(.rect(cornerRadius: 14))
            }
        }
        .bold()
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button("总结") {
                Task { await session.summarize() }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(.white)
            .foregroundStyle(.blue)
            .clipShape(.rect(cornerRadius: 12))
            .shadow(color: .black.opacity(0.04), radius: 4, y: 1)
            .disabled(session.pairs.isEmpty || session.isRunning || session.isSummarizing)
            Menu("分享") {
                Button("导出 TXT") { share(format: .txt) }
                Button("导出 PDF") { share(format: .pdf) }
                Button("导出 HTML") { share(format: .html) }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(.white)
            .foregroundStyle(.blue)
            .clipShape(.rect(cornerRadius: 12))
            .shadow(color: .black.opacity(0.04), radius: 4, y: 1)
            .disabled(session.pairs.isEmpty || session.isRunning)
            Button("历史") {
                showingHistory = true
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(.white)
            .foregroundStyle(.blue)
            .clipShape(.rect(cornerRadius: 12))
            .shadow(color: .black.opacity(0.04), radius: 4, y: 1)
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

/// Language pickers styled as pills: the A language gets the blue
/// pill, the B language a gray one, with a swap button between them.
/// Swapping only exchanges the two selections (and is disabled while
/// running, like the pickers); recorded pairs keep their own
/// direction, and per-language voices follow the language code.
private struct LanguagePillRow: View {
    @Binding var sourceLanguage: SelfHostedTranslationSession.Language
    @Binding var targetLanguage: SelfHostedTranslationSession.Language
    let isConversationMode: Bool
    let disabled: Bool

    var body: some View {
        HStack(spacing: 10) {
            Picker(isConversationMode ? "语言 A" : "源语言", selection: $sourceLanguage) {
                ForEach(SelfHostedTranslationSession.Language.allCases, id: \.self) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.blue)
            .foregroundStyle(.white)
            .clipShape(.rect(cornerRadius: 12))
            Button("交换语言", systemImage: "arrow.left.arrow.right") {
                let temp = sourceLanguage
                sourceLanguage = targetLanguage
                targetLanguage = temp
            }
            .labelStyle(.iconOnly)
            .padding(8)
            .background(Color.secondary.opacity(0.12))
            .clipShape(.circle)
            Picker(isConversationMode ? "语言 B" : "目标语言", selection: $targetLanguage) {
                ForEach(SelfHostedTranslationSession.Language.allCases, id: \.self) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.secondary.opacity(0.12))
            .clipShape(.rect(cornerRadius: 12))
        }
        .padding(.vertical, 10)
        .disabled(disabled)
    }
}

/// One labeled row inside the control card. The label is a plain
/// Text so the row reads correctly no matter how the menu picker
/// renders its own label; the picker itself shows only its value.
private struct LabeledPickerRow<Content: View>: View {
    let label: String
    let content: Content

    init(label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            content
        }
        .padding(.vertical, 10)
    }
}

/// Status line under the control card: while running, a green dot
/// plus a small waveform join the session status text; when idle,
/// the text alone keeps its previous footnote style.
private struct ListeningStatusView: View {
    let status: String
    let isRunning: Bool

    var body: some View {
        if !status.isEmpty {
            HStack(spacing: 8) {
                if isRunning {
                    Circle()
                        .fill(.green)
                        .frame(width: 9, height: 9)
                        .shadow(color: .green.opacity(0.35), radius: 4)
                    Text(status)
                        .bold()
                    Spacer()
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach([8, 15, 20, 11, 17], id: \.self) { height in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(.green)
                                .frame(width: 3, height: CGFloat(height))
                        }
                    }
                    .frame(height: 20)
                } else {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// One subtitle as a card: direction pill on top (blue for A→B,
/// purple for the reverse direction), the original in small gray
/// text, and the translation large and bold as the main content.
private struct PairCardView: View {
    let pair: SelfHostedTranslationSession.Pair
    let showDirection: Bool
    let isReverse: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showDirection {
                Text("\(pair.sourceLanguage.displayName) → \(pair.targetLanguage.displayName)")
                    .font(.caption)
                    .bold()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background((isReverse ? Color.purple : Color.blue).opacity(0.12))
                    .foregroundStyle(isReverse ? Color.purple : Color.blue)
                    .clipShape(.capsule)
            }
            Text(pair.original)
                .font(.subheadline)
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
                    .bold()
            } else if let error = pair.error {
                Text(error)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.white)
        .clipShape(.rect(cornerRadius: 16))
        .shadow(color: .black.opacity(0.05), radius: 4, y: 1)
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
        .labelsHidden()
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
