//
//  AdvancedSettingsView.swift
//  VivaDicta
//
//  Created by Anton Novoselov on 2026.05.08
//

import SwiftUI
import AppGroup
import CloudTranscription

enum AppendWithVoiceStyle: String, CaseIterable, Identifiable {
    case toolbar
    case floatingButton

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .toolbar: "Toolbar"
        case .floatingButton: "Floating Button"
        }
    }
}

struct AdvancedSettingsView: View {
    @Environment(AppState.self) private var appState

    @AppStorage(UserDefaultsStorage.Keys.appendWithVoiceStyle)
    private var appendWithVoiceStyleRaw: String = AppendWithVoiceStyle.toolbar.rawValue

    @AppStorage(UserDefaultsStorage.Keys.isChatEnabled)
    private var isChatEnabled: Bool = true

    @AppStorage(UserDefaultsStorage.Keys.isAutoShareAfterRecordingEnabled)
    private var isAutoShareAfterRecordingEnabled: Bool = false

    @AppStorage(UserDefaultsStorage.Keys.isStripTrailingPeriodEnabled)
    private var isStripTrailingPeriodEnabled: Bool = false

    @AppStorage(UserDefaultsStorage.Keys.isFillerRemovalEnabled)
    private var isFillerRemovalEnabled: Bool = true

    @AppStorage(UserDefaultsStorage.Keys.isSkipStateLosingHostReturnEnabled)
    private var isSkipStateLosingHostReturnEnabled: Bool = false

    @AppStorage(UserDefaultsStorage.Keys.defaultAIModeId)
    private var defaultAIModeId: String = ""

    @AppStorage(AppGroupCoordinator.kGeminiTranscriptionThinkingLevel, store: UserDefaultsStorage.shared)
    private var geminiThinkingLevel: GeminiTranscriptionService.ThinkingLevel = .low

    private var appendWithVoiceStyle: Binding<AppendWithVoiceStyle> {
        Binding(
            get: {
                AppendWithVoiceStyle(rawValue: appendWithVoiceStyleRaw) ?? .toolbar
            },
            set: { newValue in
                appendWithVoiceStyleRaw = newValue.rawValue
            }
        )
    }

    /// Modes that have AI processing enabled and a provider/model configured
    /// (a preset is not required - the user picks one in the AI Actions sheet).
    ///
    /// Must use the same `requirePreset: false` filter as the AI Actions sheet's
    /// `availableModes` (`TranscriptionDetailView`). The sheet only honors a saved
    /// default when that mode is still present in its `availableModes`, so if these
    /// two filters ever diverge the default could silently never apply.
    private var aiConfiguredModes: [VivaMode] {
        appState.aiService.modes.filter {
            appState.aiService.isProperlyConfigured(for: $0, requirePreset: false)
        }
    }

    /// Falls back to "None" when the stored mode no longer exists or no longer
    /// has AI configured, so the picker never shows a stale/blank selection.
    private var defaultAIMode: Binding<String> {
        Binding(
            get: {
                aiConfiguredModes.contains { $0.id.uuidString == defaultAIModeId }
                    ? defaultAIModeId
                    : ""
            },
            set: { newValue in
                defaultAIModeId = newValue
            }
        )
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("语音续写", selection: appendWithVoiceStyle) {
                        ForEach(AppendWithVoiceStyle.allCases) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .onChange(of: appendWithVoiceStyle.wrappedValue) { _, _ in
                        HapticManager.selectionChanged()
                    }
                    Text("选择在笔记上如何使用「语音续写」：工具栏模式把它放进底部操作栏的铅笔菜单里；悬浮按钮模式在右下角显示一个麦克风快捷按钮。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Picker("默认 AI 模式", selection: defaultAIMode) {
                        Text("无").tag("")
                        ForEach(aiConfiguredModes) { mode in
                            Text(mode.name).tag(mode.id.uuidString)
                        }
                    }
                    .onChange(of: defaultAIMode.wrappedValue) { _, _ in
                        HapticManager.selectionChanged()
                    }
                    Text("当当前模式没有 AI 处理时，这是在笔记的 AI 操作里预选的模式。你仍可以在 AI 操作面板里切换模式。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("笔记详情")
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("对话", isOn: $isChatEnabled)
                        .onChange(of: isChatEnabled) { _, _ in
                            HapticManager.selectionChanged()
                        }
                    Text("在主屏和笔记详情里显示对话按钮。关掉后整个 App 都不显示对话按钮。Siri 快捷指令和深链仍可打开对话。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("自动分享笔记", isOn: $isAutoShareAfterRecordingEnabled)
                        .onChange(of: isAutoShareAfterRecordingEnabled) { _, _ in
                            HapticManager.selectionChanged()
                        }
                    Text("在 App 内转写一完成，就自动弹出分享面板（内容是笔记文本）。从键盘、Watch 或扩展捕获的笔记不受影响。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("功能")
            }

            Section {
                Picker(selection: $geminiThinkingLevel) {
                    Text("低").tag(GeminiTranscriptionService.ThinkingLevel.low)
                    Text("中").tag(GeminiTranscriptionService.ThinkingLevel.medium)
                    Text("高").tag(GeminiTranscriptionService.ThinkingLevel.high)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Gemini 思考等级")
                            .font(.body)
                        Text("Gemini 回答前思考多少。低最快、最便宜")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: geminiThinkingLevel) { _, _ in
                    HapticManager.selectionChanged()
                }

                NavigationLink(value: SettingsDestination.geminiTranscriptionPrompt) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Gemini 转写提示词")
                            .font(.body)
                        Text("自定义随音频一起发送的指令")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("转写")
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("去掉语气词", isOn: $isFillerRemovalEnabled)
                        .onChange(of: isFillerRemovalEnabled) { _, _ in
                            HapticManager.selectionChanged()
                        }
                    Text("从转写中去掉「uh」「um」「ähm」这类迟疑声（按转写的语言匹配）。关掉则原样保留。对所有模式生效。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("去掉末尾句号", isOn: $isStripTrailingPeriodEnabled)
                        .onChange(of: isStripTrailingPeriodEnabled) { _, _ in
                            HapticManager.selectionChanged()
                        }
                    Text("去掉转写末尾的「.」或「...」，让「Okay.」这类随口消息读起来不显得冷淡。对所有模式生效。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("文本处理")
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("跳过会丢失位置的 App", isOn: $isSkipStateLosingHostReturnEnabled)
                        .onChange(of: isSkipStateLosingHostReturnEnabled) { _, _ in
                            HapticManager.selectionChanged()
                        }
                    Text("畅言送你返回时，Safari 和 Claude 会打开新标签页或新对话。打开这个开关，畅言会改为提示你滑动返回，精确回到你离开的位置。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("你会切回去的 App")
                        .font(.body)
                    Text(VivaDictaApp.StateLosingHostApps.displayNames.formatted(.list(type: .and)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("返回 App")
            }
        }
        .navigationTitle("高级")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        AdvancedSettingsView()
    }
    .environment(AppState())
}
#endif
