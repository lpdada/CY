import SwiftUI

/// Self-hosted sentence translation: mic -> silence chunking -> the
/// user's own ASR server -> AI translation -> bilingual list, with
/// optional TTS readout. Stopped sessions auto-save to
/// Documents/TranslationSessions; open 历史 for past records, export,
/// share, or one-tap AI summary.
///
/// Layout (2026-10 redesign): the configuration that used to take a tall
/// card now lives in a one-line bar that expands on tap (chevron down)
/// and collapses again (chevron up), so the bilingual transcript owns
/// the rest of the screen. Every binding, disabled rule and warning
/// below keeps the behaviour of the old card.
struct SelfHostedTranslationView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

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
            .navigationBarTitleDisplayMode(.inline)
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
            // 关页面 = 停录音。以前「关闭」只 dismiss，session 的录音/识别/
            // 朗读都是独立 Task，会把 session 一直持有，页面没了麦克风还开着。
            .onDisappear {
                Task { await session?.stop() }
            }
            // 切到后台也停：不让麦克风在后台一直录、译文在后台一直念。
            .onChange(of: scenePhase) { _, phase in
                // 只处理真正的后台，.inactive（下拉控制中心、来电横幅）不停。
                guard phase == .background else { return }
                Task { await session?.stop() }
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
    /// Collapsed by default: the transcript, not the settings, is the
    /// point of this screen.
    @State private var settingsExpanded = false
    @State private var showingSummary = false

    var body: some View {
        VStack(spacing: 0) {
            settingsBar
            transcript
            bottomBar
        }
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
        .sheet(isPresented: $showingSummary) {
            summarySheet
        }
    }

    // MARK: - Compact settings bar

    /// One-line summary (languages · model · readout) with a chevron that
    /// expands the pickers in place. The whole row is the hit target;
    /// the chevron is the affordance (down = expand, up = collapse).
    private var settingsBar: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.22)) {
                    settingsExpanded.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    Text(languagePairText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .layoutPriority(1)

                    if session.isConversationMode {
                        miniTag("双向", tint: .purple, fill: 0.14)
                    }

                    if session.ttsEnabled {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                            .accessibilityHidden(true)
                    }

                    miniTag(modelDisplayName, tint: .secondary, fill: 0.10)

                    Spacer(minLength: 4)

                    Image(systemName: settingsExpanded ? "chevron.up" : "chevron.down")
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
            .accessibilityLabel(settingsExpanded ? "收起语言与声音设置" : "展开语言与声音设置")

            if settingsExpanded {
                expandedSettings
            }

            if let warning = languageWarning {
                Text(warning)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
            if session.ttsEnabled, let error = session.serverVoicesError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
        }
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var expandedSettings: some View {
        VStack(spacing: 10) {
            HStack(alignment: .bottom, spacing: 8) {
                languageColumn(
                    title: session.isConversationMode ? "语言 A" : "源语言",
                    selection: $session.sourceLanguage
                )
                Button {
                    let temp = session.sourceLanguage
                    session.sourceLanguage = session.targetLanguage
                    session.targetLanguage = temp
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.footnote.weight(.semibold))
                        .frame(width: 34, height: 34)
                        .background(Color.secondary.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(session.isRunning)
                .accessibilityLabel("交换语言")
                languageColumn(
                    title: session.isConversationMode ? "语言 B" : "目标语言",
                    selection: $session.targetLanguage
                )
            }

            Toggle("双向对话", isOn: $session.isConversationMode)
                .font(.subheadline)

            HStack {
                Text("转写模型")
                    .font(.subheadline)
                Spacer()
                Picker("转写模型", selection: $session.asrModelName) {
                    ForEach(selfHostedModels) { model in
                        Text(model.displayName).tag(model.name)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .disabled(session.isRunning)
            }

            // 朗读开关运行中也可拨动，声音切换不依赖开关重拨。
            Toggle("朗读译文", isOn: $session.ttsEnabled)
                .font(.subheadline)

            if session.ttsEnabled {
                if session.isConversationMode {
                    voiceRow(title: "朗读声音（\(session.sourceLanguage.displayName)）",
                             language: session.sourceLanguage)
                    voiceRow(title: "朗读声音（\(session.targetLanguage.displayName)）",
                             language: session.targetLanguage)
                } else {
                    HStack {
                        Text("朗读声音")
                            .font(.subheadline)
                        Spacer()
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
        .padding(.horizontal, 14)
        .padding(.top, 2)
        .padding(.bottom, 12)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func languageColumn(
        title: String,
        selection: Binding<SelfHostedTranslationSession.Language>
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Picker(title, selection: selection) {
                ForEach(SelfHostedTranslationSession.Language.allCases, id: \.self) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .disabled(session.isRunning)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func voiceRow(
        title: String,
        language: SelfHostedTranslationSession.Language
    ) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .lineLimit(1)
            Spacer()
            TTSVoicePickerRow(language: language, serverVoices: session.serverVoices) {
                session.voiceSelectionChanged(for: language)
            }
        }
    }

    private func miniTag(_ text: String, tint: Color, fill: Double) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(fill), in: Capsule())
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

    private var languagePairText: String {
        session.isConversationMode
            ? "\(session.sourceLanguage.displayName) ⇄ \(session.targetLanguage.displayName)"
            : "\(session.sourceLanguage.displayName) → \(session.targetLanguage.displayName)"
    }

    private var modelDisplayName: String {
        selfHostedModels.first(where: { $0.name == session.asrModelName })?.displayName
            ?? session.asrModelName
    }

    private var languageWarning: String? {
        guard session.sourceLanguage == session.targetLanguage else { return nil }
        return session.isConversationMode
            ? "语言 A 与语言 B 相同，双向没有意义，请选两种不同的语言"
            : "源语言与目标语言相同，翻译结果与原文一致"
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if session.pairs.isEmpty {
                        emptyState
                    }
                    ForEach(session.pairs) { pair in
                        PairCardView(
                            pair: pair,
                            showDirection: session.isConversationMode,
                            isReverse: session.isConversationMode
                                && pair.sourceLanguage == session.targetLanguage
                        )
                        .id(pair.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .scrollIndicators(.hidden)
            .onChange(of: session.pairs.count) { _, _ in
                guard let lastID = session.pairs.last?.id else { return }
                withAnimation {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: hasSelfHostedKey ? "waveform" : "server.rack")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(hasSelfHostedKey ? "点下方麦克风开始翻译" : "先配置自建服务器")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 70)
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 12) {
            if !hasSelfHostedKey {
                Button("配置自建服务器") {
                    onConfigureKey()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                micButton
            }

            VStack(alignment: .leading, spacing: 2) {
                if session.isSummarizing {
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
                } else if hasSelfHostedKey {
                    Text("待开始")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 4)

            iconButton("doc.text", label: "总结") {
                Task { await session.summarize() }
            }
            .disabled(session.pairs.isEmpty || session.isRunning || session.isSummarizing)

            Menu {
                Button("导出 TXT") { share(format: .txt) }
                Button("导出 PDF") { share(format: .pdf) }
                Button("导出 HTML") { share(format: .html) }
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(Color.secondary.opacity(0.12), in: Circle())
            }
            .disabled(session.pairs.isEmpty || session.isRunning)
            .accessibilityLabel("分享")

            iconButton("clock.arrow.circlepath", label: "历史") {
                showingHistory = true
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(.bar)
    }

    private var micButton: some View {
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
        .accessibilityLabel(session.isRunning ? "停止翻译" : "开始翻译")
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

    private var summarySheet: some View {
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
            .navigationTitle("总结")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showingSummary = false }
                }
            }
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

/// One subtitle as a card: the translation leads, the original follows
/// in small gray text. In conversation mode a small direction pill says
/// which way this sentence went (blue A→B, purple B→A).
private struct PairCardView: View {
    let pair: SelfHostedTranslationSession.Pair
    let showDirection: Bool
    let isReverse: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if showDirection {
                Text("\(pair.sourceLanguage.displayName) → \(pair.targetLanguage.displayName)")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background((isReverse ? Color.purple : Color.blue).opacity(0.12))
                    .foregroundStyle(isReverse ? Color.purple : Color.blue)
                    .clipShape(Capsule())
            }
            Text(pair.original)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if pair.isTranslating {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("翻译中…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let translation = pair.translation {
                Text(translation)
                    .font(.body.weight(.semibold))
                    .lineSpacing(2)
                    .textSelection(.enabled)
            } else if let error = pair.error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.04), radius: 4, y: 1)
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
