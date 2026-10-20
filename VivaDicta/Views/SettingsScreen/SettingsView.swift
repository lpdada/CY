//
//  SettingsView.swift
//  VivaDicta
//
//  Created by Anton Novoselov on 2025.09.12
//

import SwiftUI
import AppGroup
import AppIntents
import TipKit
import MessageUI
import Presets
import AICore
import CloudTranscription

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    @State private var promptsManager = PromptsManager()

    @Environment(\.dismiss) private var dismiss
    @State private var navigationPath = NavigationPath()
    @AppStorage(AppGroupCoordinator.kIsVADEnabled, store: UserDefaultsStorage.shared)
    private var isVADEnabled = true
    @AppStorage(UserDefaultsStorage.Keys.isAutoCopyAfterRecordingEnabled)
    private var isAutoCopyAfterRecordingEnabled = false
    @AppStorage("preferredChineseScript") private var chineseScriptPreference: ChineseScriptPreference = .auto
    @AppStorage(ModelThinkingPreference.userDefaultsKey) private var isModelThinkingEnabled = false
    @AppStorage(UserDefaultsStorage.Keys.preferredMicrophone, store: UserDefaultsStorage.shared)
    private var preferredMicrophone: PreferredMicrophone = .default
    @AppStorage(UserDefaultsStorage.Keys.audioSessionTimeout)
    private var audioSessionTimeout: Int = 180
    private let prewarmManager = AudioPrewarmManager.shared
    @State private var showPrewarmError = false
    @State private var prewarmErrorMessage = ""
    
    @AppStorage(UserDefaultsStorage.Keys.displaySiriTip) private var displaySiriTip: Bool = true
    @State private var isKeepInClipboardEnabled = AppGroupCoordinator.shared.isKeepTranscriptInClipboardEnabled
    @State private var isHapticFeedbackEnabled = AppGroupCoordinator.shared.isKeyboardHapticFeedbackEnabled
    @State private var isSoundFeedbackEnabled = AppGroupCoordinator.shared.isKeyboardSoundFeedbackEnabled
    @State private var enabledKeyboardLanguages: Set<KeyboardLanguage> = AppGroupCoordinator.shared.enabledKeyboardLanguages

    @AppStorage(UserDefaultsStorage.Keys.isAutoAudioCleanupEnabled)
    private var isAutoAudioCleanupEnabled = false
    @AppStorage(UserDefaultsStorage.Keys.audioRetentionDays)
    private var audioRetentionDays = 7

    @AppStorage(UserDefaultsStorage.Keys.isAutoNoteCleanupEnabled)
    private var isAutoNoteCleanupEnabled = false
    @AppStorage(UserDefaultsStorage.Keys.noteRetentionDays)
    private var noteRetentionDays = 7

    @AppStorage(UserDefaultsStorage.Keys.isAutoChatCleanupEnabled)
    private var isAutoChatCleanupEnabled = false
    @AppStorage(UserDefaultsStorage.Keys.chatRetentionDays)
    private var chatRetentionDays = 7

    @AppStorage(UserDefaultsStorage.Keys.isICloudSyncEnabled)
    private var isICloudSyncEnabled = true
    @State private var showRestartAlert = false
    @AppStorage(AppGroupCoordinator.isHapticsEnabled, store: UserDefaultsStorage.shared)
    private var isHapticsEnabled = true
    @AppStorage(UserDefaultsStorage.Keys.recordingOrbStyle)
    private var orbStyle: RecordingOrbStyle = .particles

    @State private var showAddMode = false
    @State private var showMailCompose = false

    private let selectTranscriptionModelTipSettingsView = SelectTranscriptionModelTipSettingsView()
    
    var body: some View {
        NavigationStack(path: $navigationPath) {
            Form {
                // Modes section
                Section("模式") {
                    
                    ForEach(appState.aiService.modes) { mode in
                        NavigationLink(value: mode) {
                            ModeInfoRow(mode: mode, connectedProviders: appState.aiService.connectedProviders, presetManager: appState.presetManager)
                        }
                        .contextMenu {
                            Button {
                                HapticManager.heavyImpact()
                                duplicateMode(mode)
                            } label: {
                                Label("复制一份", systemImage: "doc.on.doc")
                            }

                            if appState.aiService.modes.count > 1 {
                                Button(role: .destructive) {
                                    deleteMode(mode)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if appState.aiService.modes.count > 1 {
                                Button(role: .destructive) {
                                    deleteMode(mode)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            Button {
                                HapticManager.heavyImpact()
                                duplicateMode(mode)
                            } label: {
                                Label("复制一份", systemImage: "doc.on.doc")
                            }
                            .tint(.blue)
                        }
                    }
                    
                    // Add New Mode button - only show if models are available
                    if appState.transcriptionManager.hasAvailableTranscriptionModels {
                        Button {
                            HapticManager.lightImpact()
                            showAddMode = true
                        } label: {
                            HStack {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(.blue)
                                    .font(.title2)

                                Text("添加新模式")
                                    .foregroundStyle(.blue)
                                    .font(.body)

                                Spacer()
                            }
                        }
                    } else {
                        Button {
                            HapticManager.lightImpact()
                            navigationPath.append(SettingsDestination.transcriptionModels)
                        } label: {
                            HStack {
                                Image(systemName: "info.circle")
                                    .foregroundStyle(.orange)
                                
                                Text("设置转写模型")
                                    .foregroundStyle(.orange)
                                    .font(.footnote)
                            }
                        }
                    }
                }
                
                Section("转写") {
                    NavigationLink(value: SettingsDestination.transcriptionModels) {
                        Text("转写模型")
                    }
                    .popoverTip(selectTranscriptionModelTipSettingsView)

                    Toggle(isOn: $isVADEnabled) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("语音活动检测")
                                .font(.body)
                            Text("通过检测语音片段提升准确率")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: isVADEnabled) { _, _ in
                        HapticManager.selectionChanged()
                    }

                    Toggle(isOn: $isAutoCopyAfterRecordingEnabled) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("复制到剪贴板")
                                .font(.body)
                            Text("录音后自动把转写复制到剪贴板")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: isAutoCopyAfterRecordingEnabled) { _, _ in
                        HapticManager.selectionChanged()
                    }
                }
                
                Section("词典") {
                    NavigationLink(value: SettingsDestination.correctSpelling) {
                        Text("拼写纠正")
                    }

                    NavigationLink(value: SettingsDestination.replacements) {
                        Text("词语替换")
                    }
                }
                
                Section("组织") {
                    NavigationLink(value: SettingsDestination.tags) {
                        Label("标签", systemImage: "tag")
                    }
                }

                Section("AI 设置") {
                    NavigationLink(value: SettingsDestination.aiProviders) {
                        Text("AI 服务商")
                    }
                    NavigationLink(value: SettingsDestination.presetsSettings) {
                        Text("AI 处理预设")
                    }
                    NavigationLink(value: SettingsDestination.remindersAndCalendar) {
                        Text("提醒事项与日历")
                    }
                    if ChineseScriptPreferenceStore.shouldShowSetting(modes: appState.aiService.modes) {
                        VStack(alignment: .leading, spacing: 4) {
                            Picker("中文简繁", selection: $chineseScriptPreference) {
                                ForEach(ChineseScriptPreference.allCases) { option in
                                    Text(option.displayName).tag(option)
                                }
                            }
                            Text("当 AI 增强输出是中文时应用。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .onChange(of: chineseScriptPreference) { _, _ in
                            HapticManager.selectionChanged()
                        }
                    }
                    Toggle(isOn: $isModelThinkingEnabled) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("让模型思考")
                                .font(.body)
                            Text("关闭更快：AI 处理会要求推理模型把思考降到最低。打开则完全不发送推理设置，每个模型用自己的默认值——更慢，但处理棘手文本可能更好。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: isModelThinkingEnabled) { _, _ in
                        HapticManager.selectionChanged()
                    }
                    NavigationLink(value: SettingsDestination.chatTools) {
                        HStack {
                            Text("对话工具")
                        }
                    }
                }

                Section("智能搜索") {
                    NavigationLink(value: SettingsDestination.smartSearch) {
                        HStack {
                            Text("智能搜索")
                            Spacer()
                            Text("\(RAGIndexingService.shared.indexedTranscriptionCount) 条笔记")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("键盘") {
                    Toggle(isOn: $isKeepInClipboardEnabled) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("复制到剪贴板")
                                .font(.body)
                            Text("插入后把转写保留在剪贴板")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: isKeepInClipboardEnabled) { _, newValue in
                        HapticManager.selectionChanged()
                        AppGroupCoordinator.shared.isKeepTranscriptInClipboardEnabled = newValue
                    }

                    Toggle(isOn: $isHapticFeedbackEnabled) {
                        Text("震动反馈")
                            .font(.body)
                    }
                    .onChange(of: isHapticFeedbackEnabled) { _, newValue in
                        HapticManager.selectionChanged()
                        AppGroupCoordinator.shared.isKeyboardHapticFeedbackEnabled = newValue
                    }

                    Toggle(isOn: $isSoundFeedbackEnabled) {
                        Text("声音")
                            .font(.body)
                    }
                    .onChange(of: isSoundFeedbackEnabled) { _, newValue in
                        HapticManager.selectionChanged()
                        AppGroupCoordinator.shared.isKeyboardSoundFeedbackEnabled = newValue
                    }

                    KeyboardLanguagesSettingsView(enabledLanguages: $enabledKeyboardLanguages)

                    VStack(alignment: .leading, spacing: 8) {
                        Picker("会话超时", selection: $audioSessionTimeout) {
                            #if DEBUG
                            Text("15 秒").tag(15)
                            #endif
                            Text("30 秒").tag(30)
                            Text("1 分钟").tag(60)
                            #if DEBUG
                            Text("90 秒").tag(90)
                            Text("2 分钟").tag(120)
                            #endif
                            Text("3 分钟").tag(180)
                            Text("5 分钟").tag(300)
                            Text("15 分钟").tag(900)
                            Text("30 分钟").tag(1800)
                            Text("1 小时").tag(3600)
                            Text("永不").tag(AppGroupCoordinator.sessionTimeoutNever)
                        }
                        .onChange(of: audioSessionTimeout) { _, _ in
                            HapticManager.selectionChanged()
                            prewarmManager.applyTimeoutChange()
                        }

                        Text("保持麦克风会话活跃，以便从键盘录音")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if audioSessionTimeout == AppGroupCoordinator.sessionTimeoutNever {
                            Text("选「永不」时，麦克风会一直保持待命，直到你在下面结束会话，这样更耗电。")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    
                    KeyboardSessionButton(
                        isSessionActive: prewarmManager.isSessionActiveObservable,
                        action: toggleKeyboardRecordingSession
                    )
                }

                Section("麦克风") {
                    Picker("输入", selection: $preferredMicrophone) {
                        Text("自动").tag(PreferredMicrophone.automatic)
                        Text("iPhone 麦克风").tag(PreferredMicrophone.builtIn)
                    }
                    // @AppStorage persists to the same store and key
                    // RecordingAudioSession reads, so there is nothing to write
                    // here. A live keyboard session keeps the route it was set
                    // up with until it ends - deliberately, since restarting it
                    // to apply the change tore down the Live Activity and its
                    // terminate control. Ending the session above applies it
                    // immediately.
                    .onChange(of: preferredMicrophone) { _, _ in
                        HapticManager.selectionChanged()
                    }

                    Text(preferredMicrophone == .automatic
                         ? "Uses whichever microphone is connected - AirPods, a wired headset, or the iPhone - the same way Phone and Voice Memos do."
                         : "Always records with the iPhone's own microphone, even when headphones are connected. Keeps Bluetooth headphones in full-quality audio while you dictate.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("反馈") {
                    Toggle(isOn: $isHapticsEnabled) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("震动反馈")
                                .font(.body)
                            Text("录音、复制、删除等操作时的震动")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Picker("录音球", selection: $orbStyle) {
                            ForEach(RecordingOrbStyle.allCases) { style in
                                Text(style.displayName).tag(style)
                            }
                        }
                        Text("录音界面上显示的动画。选「无」完全隐藏。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .onChange(of: orbStyle) { _, _ in
                        HapticManager.selectionChanged()
                    }
                }

                Section("存储") {

                    Toggle(isOn: $isAutoNoteCleanupEnabled) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("自动删除笔记")
                                .font(.body)
                            Text("自动删除旧笔记及其音频文件")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: isAutoNoteCleanupEnabled) { _, newValue in
                        HapticManager.selectionChanged()
                        if newValue {
                            isAutoAudioCleanupEnabled = false
                        }
                    }

                    if isAutoNoteCleanupEnabled {
                        Picker("笔记保留", selection: $noteRetentionDays) {
                            Text("1 天").tag(1)
                            Text("3 天").tag(3)
                            Text("7 天").tag(7)
                            Text("14 天").tag(14)
                            Text("30 天").tag(30)
                        }
                        .padding(.leading)
                        .onChange(of: noteRetentionDays) { _, _ in
                            HapticManager.selectionChanged()
                        }
                    }

                    if !isAutoNoteCleanupEnabled {
                        Toggle(isOn: $isAutoAudioCleanupEnabled) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("自动清理音频")
                                    .font(.body)
                                Text("自动删除旧音频文件以节省空间")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .onChange(of: isAutoAudioCleanupEnabled) { _, _ in
                            HapticManager.selectionChanged()
                        }

                        if isAutoAudioCleanupEnabled {
                            Picker("音频文件保留", selection: $audioRetentionDays) {
                                Text("1 天").tag(1)
                                Text("3 天").tag(3)
                                Text("7 天").tag(7)
                                Text("14 天").tag(14)
                                Text("30 天").tag(30)
                            }
                            .padding(.leading)
                            .onChange(of: audioRetentionDays) { _, _ in
                                HapticManager.selectionChanged()
                            }
                        }
                    }

                    if isAutoNoteCleanupEnabled || isAutoAudioCleanupEnabled {
                        AutoDeleteExemptTagsLink()
                            .padding(.leading)
                    }

                    Toggle(isOn: $isAutoChatCleanupEnabled) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("自动删除对话")
                                .font(.body)
                            Text("自动删除旧对话")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: isAutoChatCleanupEnabled) { _, _ in
                        HapticManager.selectionChanged()
                    }

                    if isAutoChatCleanupEnabled {
                        Picker("对话保留", selection: $chatRetentionDays) {
                            Text("1 天").tag(1)
                            Text("3 天").tag(3)
                            Text("7 天").tag(7)
                            Text("14 天").tag(14)
                            Text("30 天").tag(30)
                        }
                        .padding(.leading)
                        .onChange(of: chatRetentionDays) { _, _ in
                            HapticManager.selectionChanged()
                        }
                    }
                }
                
                Section {
                    Toggle(isOn: $isICloudSyncEnabled) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("iCloud 同步")
                                .font(.body)
                            Text("在设备间同步转写、词典和替换规则")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: isICloudSyncEnabled) { _, _ in
                        HapticManager.selectionChanged()
                        showRestartAlert = true
                    }
                } header: {
                    Text("iCloud")
                } footer: {
                    Text("需要重启 App 才生效。")
                }
                
                Section("导出笔记") {
                    NavigationLink(value: SettingsDestination.export) {
                        HStack {
                            Image(systemName: "square.and.arrow.up.on.square")
                                .foregroundStyle(.blue)
                            Text("导出笔记")
                        }
                    }
                }

                Section("集成") {
                    NavigationLink(value: SettingsDestination.integrations) {
                        HStack {
                            Image(systemName: "puzzlepiece.extension")
                                .foregroundStyle(.purple)
                            Text("集成")
                        }
                    }
                }

                Section("高级") {
                    NavigationLink(value: SettingsDestination.advanced) {
                        HStack {
                            Image(systemName: "slider.horizontal.3")
                                .foregroundStyle(.gray)
                            Text("高级")
                        }
                    }
                }

                Section("支持") {
                    Link(destination: URL(string: "https://vivadicta.com/ios/docs")!) {
                        HStack {
                            Image(systemName: "book")
                                .foregroundStyle(.purple)
                            Text("文档")
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "arrow.up.forward")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    Button {
                        if MFMailComposeViewController.canSendMail() {
                            showMailCompose = true
                        } else {
                            openSupportEmailFallback()
                        }
                    } label: {
                        HStack {
                            Image(systemName: "envelope")
                                .foregroundStyle(.blue)
                            Text("邮件联系支持")
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "arrow.up.forward")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button {
                        requestAppStoreReview()
                    } label: {
                        HStack {
                            Image(systemName: "star")
                                .foregroundStyle(.yellow)
                            Text("在 App Store 评价")
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "arrow.up.forward")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Link(destination: URL(string: "https://github.com/n0an/VivaDicta")!) {
                        HStack {
                            Image("github")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 20, height: 20)
                                .tint(.primary)
                            Text("在 GitHub 点星")
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "arrow.up.forward")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    ShareLink(item: URL(string: "https://apps.apple.com/app/id6758147238")!) {
                        HStack {
                            Image(systemName: "square.and.arrow.up")
                                .foregroundStyle(.green)
                            Text("分享畅言")
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "arrow.up.forward")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Link(destination: URL(string: "https://vivadicta.com")!) {
                        HStack {
                            Image(systemName: "desktopcomputer")
                                .foregroundStyle(.indigo)
                            Text("畅言 macOS 版")
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "arrow.up.forward")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    AppVersionFooter()
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                }
            }
            .navigationDestination(for: VivaMode.self) { mode in
                ModeEditView(
                    mode: mode,
                    aiService: appState.aiService,
                    presetManager: appState.presetManager,
                    transcriptionManager: appState.transcriptionManager,
                    navigationPath: $navigationPath)
            }
            .navigationDestination(for: SettingsDestination.self) { destination in
                switch destination {
                case .promptsSettings:
                    PromptsSettings(promptsManager: promptsManager, aiService: appState.aiService)
                case .transcriptionModels:
                    ModelsView()
                case .promptsTemplates:
                    TemplateSelectionView(promptsManager: promptsManager)
                case .presetsSettings:
                    PresetSettings(presetManager: appState.presetManager)
                case .correctSpelling:
                    WordsDictionaryView()
                case .replacements:
                    ReplacementsView()
                case .aiProviders:
                    AIProviders()
                case .tags:
                    TagManagementView()
                case .autoDeleteExemptTags:
                    AutoDeleteExemptTagsView()
                case .chatTools:
                    ChatToolsSettingsView()
                case .smartSearch:
                    SmartSearchSettingsView()
                case .integrations:
                    IntegrationsView()
                case .export:
                    ExportSettingsView()
                case .advanced:
                    AdvancedSettingsView()
                case .geminiTranscriptionPrompt:
                    GeminiTranscriptionPromptView()
                case .remindersAndCalendar:
                    RemindersCalendarSettingsView()
                }
            }
            .navigationDestination(for: Preset.self) { preset in
                PresetFormView(preset: preset, presetManager: appState.presetManager)
            }
            .navigationDestination(for: UserPrompt.self) { prompt in
                PromptFormView(
                    editingPrompt: prompt,
                    promptsManager: promptsManager,
                    aiService: appState.aiService
                )
            }
            .navigationDestination(isPresented: $showAddMode) {
                ModeEditView(
                    mode: nil,
                    aiService: appState.aiService,
                    presetManager: appState.presetManager,
                    transcriptionManager: appState.transcriptionManager,
                    navigationPath: $navigationPath
                )
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭", systemImage: "xmark") {
                        HapticManager.lightImpact()
                        dismiss()
                    }
                    .accessibilityLabel("关闭设置")
                }
            }

        }
        .animation(.default, value: isAutoAudioCleanupEnabled)
        .animation(.default, value: isAutoNoteCleanupEnabled)
        .onAppear {
            if appState.shouldNavigateToModels {
                appState.shouldNavigateToModels = false
                navigationPath.append(SettingsDestination.transcriptionModels)
            }
            if appState.shouldNavigateToModeSettings {
                appState.shouldNavigateToModeSettings = false
                navigationPath.append(appState.aiService.selectedMode)
            }
            if appState.pendingCloudTranscriptionProvider != nil {
                // Don't clear the flag here; ModelsView reads it on appear
                // and uses it to switch to the cloud tab + open the matching
                // CloudModelConfigurationView. Clearing happens there.
                navigationPath.append(SettingsDestination.transcriptionModels)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if navigationPath.isEmpty {
                SiriTipView(intent: ToggleRecordIntent(), isVisible: $displaySiriTip)
                    .padding(.horizontal)
            }
        }
        
        .alert("预热会话错误", isPresented: $showPrewarmError) {
            Button("好") {
                showPrewarmError = false
            }
        } message: {
            Text(prewarmErrorMessage)
        }
        .alert("需要重启", isPresented: $showRestartAlert) {
            Button("立即重启") {
                exit(0)
            }
            Button("稍后", role: .cancel) { }
        } message: {
            Text("App 需要重启，iCloud 同步的修改才生效。")
        }
        .sheet(isPresented: $showMailCompose) {
            MailComposeView(
                subject: "VivaDicta Support Request",
                recipients: ["support@vivadicta.com"],
                body: supportEmailBody
            )
        }
    }
    
    private func deleteMode(_ mode: VivaMode) {
        // Prevent deletion if there's only one mode
        guard appState.aiService.modes.count > 1 else { return }

        HapticManager.heavyImpact()
        appState.aiService.deleteMode(mode)
    }

    private func duplicateMode(_ mode: VivaMode) {
        appState.aiService.duplicateMode(mode)
    }

    // MARK: - Support

    private var deviceModelIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(validatingUTF8: $0) ?? "Unknown"
            }
        }
    }

    private var supportEmailBody: String {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
        let deviceModel = deviceModelIdentifier
        let systemVersion = UIDevice.current.systemVersion

        return """

---
Please describe your issue above this line
---
App Version: \(appVersion) (\(buildNumber))
Device: \(deviceModel)
iOS Version: \(systemVersion)
"""
    }

    private func requestAppStoreReview() {
        if let url = URL(string: "https://apps.apple.com/app/id6758147238?action=write-review") {
            UIApplication.shared.open(url)
        }
    }

    private func openSupportEmailFallback() {
        let subject = "VivaDicta Support Request"
        let encodedSubject = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let encodedBody = supportEmailBody.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""

        if let url = URL(string: "mailto:support@vivadicta.com?subject=\(encodedSubject)&body=\(encodedBody)") {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - Keyboard Recording Session Actions

    /// Starts the hot mic session, or ends the running one. The stop half is the
    /// only in-app way out of a "Never" session started from Settings or from the
    /// text-processing deep link - neither of those flows starts a Live Activity,
    /// and with no timeout no expiry timer will end them either.
    private func toggleKeyboardRecordingSession() {
        if prewarmManager.isSessionActiveObservable {
            endKeyboardRecordingSession()
        } else {
            activateKeyboardRecordingSession()
        }
    }

    private func activateKeyboardRecordingSession() {
        Task {
            HapticManager.lightImpact()
            do {
                // Start the pre-warm session (same as when receiving deep link)
                try await prewarmManager.startPrewarmSession()

                // Activate keyboard session to notify keyboard that hot mic is ready
                AppGroupCoordinator.shared.activateKeyboardSession(
                    timeoutSeconds: prewarmManager.audioSessionTimeout
                )

            } catch {
                prewarmErrorMessage = "Failed to activate session: \(error.localizedDescription)"
                HapticManager.error()
                showPrewarmError = true
            }
        }
    }

    /// Tears down the engine and audio session. `endSession()` also deactivates the
    /// shared keyboard session, which notifies the keyboard and ends any Live
    /// Activity through the existing `onKeyboardSessionExpired` handler.
    private func endKeyboardRecordingSession() {
        HapticManager.lightImpact()
        prewarmManager.endSession()
    }
}

// MARK: - Keyboard Session Button

/// Start/stop control for the hot mic session. Doubles as the session's status
/// row - the green dot shows while the microphone is armed.
private struct KeyboardSessionButton: View {
    let isSessionActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: isSessionActive ? "stop.circle" : "keyboard")
                    .foregroundStyle(isSessionActive ? .red : .blue)
                    .font(.body)

                VStack(alignment: .leading, spacing: 4) {
                    Text(isSessionActive ? "End Keyboard Recording Session" : "Enable Keyboard Recording Session")
                        .foregroundStyle(isSessionActive ? .red : .blue)
                        .font(.body)

                    if isSessionActive {
                        HStack {
                            Circle()
                                .fill(.green)
                                .frame(width: 6)

                            Text("会话活跃中")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                }

                Spacer()
            }
        }
        .buttonStyle(.plain)
    }
}

#if DEBUG
#Preview {
    SettingsView()
        .environment(AppState())
}
#endif

// MARK: - App Version Footer

private struct AppVersionFooter: View {
    private var versionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
        return "VivaDicta \(version) (\(build))"
    }

    var body: some View {
        Text(versionText)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .accessibilityLabel("App 版本 \(versionText)")
    }
}

// MARK: - Mode Info Row

private struct ModeInfoRow: View {
    let mode: VivaMode
    let connectedProviders: [AIProvider]
    let presetManager: PresetManager

    private var isTranscriptionProviderAvailable: Bool {
        guard let aiProvider = mode.transcriptionProvider.mappedAIProvider else {
            // On-device providers (WhisperKit, Parakeet) or custom are always available
            return true
        }
        return connectedProviders.contains(aiProvider)
    }

    private var transcriptionModelDisplayName: String {
        // For custom transcription, show the actual configured model name
        if mode.transcriptionProvider == .customTranscription {
            let manager = CustomTranscriptionModelManager.shared
            return manager.isConfigured ? manager.customModel.modelName : "Custom"
        }
        return mode.transcriptionProvider.getTranscriptionModelDisplayName(mode.transcriptionModel)
    }
    
    private var isLanguageSelectionAvailable: Bool {
        let provider = mode.transcriptionProvider
        let modelName = mode.transcriptionModel

        // Gemini always auto-detects
        if provider == .gemini { return false }

        // Parakeet V3 auto-detects, V2 needs language param
        if provider == .parakeet {
            return modelName == "parakeet-tdt-0.6b-v2"
        }

        return true
    }
    
    private var transcriptionLanguageView: some View {
        HStack(spacing: 4) {
            Image(systemName: "globe")
                .font(.system(size: 8))
            if let languageCode = mode.transcriptionLanguage, isLanguageSelectionAvailable {
                Text(TranscriptionModelProvider.allLanguages[languageCode] ?? languageCode)
            } else {
                Text("自动")
            }
        }
    }

    private var reminderExtractorSummary: String? {
        guard let provider = mode.reminderExtractorProvider else { return nil }
        if let model = mode.reminderExtractorModel, !model.isEmpty, provider != .apple {
            return "Reminders: \(provider.displayName) - \(model)"
        }
        return "Reminders: \(provider.displayName)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(mode.name)
                .font(.body.weight(.medium))

            if !mode.transcriptionModel.isEmpty && isTranscriptionProviderAvailable {
                HStack(alignment: .top, spacing: 0) {
                    // Transcription info - takes 50% width
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: "waveform")
                            .foregroundStyle(
                                MeshGradient(
                                    width: 2,
                                    height: 2,
                                    points: [
                                        [0, 0], [1, 0],
                                        [0, 1], [1, 1]
                                    ],
                                    colors: [
                                        .blue, .green,
                                        .indigo, .teal
                                    ]
                                )
                            )
                            .accessibilityLabel("转写服务商")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.transcriptionProvider.displayName)
                                .foregroundStyle(.secondary)
                            Text(transcriptionModelDisplayName)
                                .foregroundStyle(.tertiary)
                            transcriptionLanguageView
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // Enhancement info - takes 50% width
                    if let provider = mode.aiProvider, connectedProviders.contains(provider) {
                        Divider()
                            .padding(.trailing, 8)
                        HStack(alignment: .top, spacing: 4) {
                            Image(systemName: "sparkles")
                                .foregroundStyle(
                                    MeshGradient(
                                        width: 2,
                                        height: 2,
                                        points: [
                                            [0, 0], [1, 0],
                                            [0, 1], [1, 1]
                                        ],
                                        colors: [
                                            .purple, .red,
                                            .blue, .pink
                                        ]
                                    )
                                )
                                .accessibilityLabel("AI 处理服务商")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(provider.displayName)
                                    .foregroundStyle(.secondary)
                                Text(mode.aiModel)
                                    .foregroundStyle(.tertiary)
                                if let presetId = mode.presetId {
                                    Text(presetManager.preset(for: presetId)?.name
                                         ?? PresetCatalog.displayName(for: presetId, fallback: presetId, userDefaults: UserDefaultsStorage.shared))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .font(.caption2)
                .padding(.leading, 4)
            }

            if let reminderExtractorSummary {
                Label(reminderExtractorSummary, systemImage: "checklist")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 4)
            }
        }
        .padding(.vertical, 4)
    }
}

enum SettingsError: LocalizedError {
    case duplicateModeName(String)
    case duplicatePromptName(String)
    case unexpectedError(String)

    var errorDescription: String? {
        switch self {
        case .duplicateModeName(_):
            "Invalid Mode Name"
        case .duplicatePromptName(_):
            "Invalid Prompt Name"
        case .unexpectedError(_):
            "Unexpected Error"
        }
    }

    var failureReason: String {
        switch self {
        case .duplicateModeName(let name):
            "There's already an existing Mode with name \(name). Enter a different name for this mode."
        case .duplicatePromptName(let name):
            "There's already an existing Prompt with name \(name). Enter a different name for this prompt."
        case .unexpectedError(let message):
            "An unexpected error occurred: \(message). Please try again."
        }
    }
}

// MARK: - Mail Compose View

struct MailComposeView: UIViewControllerRepresentable {
    let subject: String
    let recipients: [String]
    let body: String

    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let mailComposer = MFMailComposeViewController()
        mailComposer.mailComposeDelegate = context.coordinator
        mailComposer.setSubject(subject)
        mailComposer.setToRecipients(recipients)
        mailComposer.setMessageBody(body, isHTML: false)
        return mailComposer
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(dismiss: dismiss)
    }

    class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let dismiss: DismissAction

        init(dismiss: DismissAction) {
            self.dismiss = dismiss
        }

        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            dismiss()
        }
    }
}
