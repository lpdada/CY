//
//  IntegrationsView.swift
//  VivaDicta
//
//  Created by Anton Novoselov on 2026.04.25
//

import SwiftUI
import AppGroup

/// Settings screen for third-party integrations (Obsidian today; Webhooks /
/// Zapier later). Two sibling toggles control the Obsidian hand-off:
/// "Auto-open after transcription" (`isObsidianGloballyEnabled`) drives the
/// automatic open in `RecordViewModel.openObsidianIfEnabled` and gates the
/// per-mode opt-out in `ModeEditView`; "Show Send to Obsidian button"
/// (`isObsidianSendButtonEnabled`) reveals a manual send button on the
/// transcription detail screen. The note-name template and the optional custom
/// URL template are shared by both.
struct IntegrationsView: View {
    @AppStorage(UserDefaultsStorage.Keys.isObsidianGloballyEnabled)
    private var isObsidianAutoOpenEnabled = false

    @AppStorage(UserDefaultsStorage.Keys.isObsidianSendButtonEnabled)
    private var isObsidianSendButtonEnabled = false

    @AppStorage(UserDefaultsStorage.Keys.obsidianNoteTemplate)
    private var obsidianNoteTemplate = UserDefaultsStorage.defaultObsidianNoteTemplate

    @AppStorage(UserDefaultsStorage.Keys.isObsidianCustomURLEnabled)
    private var isObsidianCustomURLEnabled = false

    @AppStorage(UserDefaultsStorage.Keys.obsidianCustomURLTemplate)
    private var obsidianCustomURLTemplate = ""

    private static let customURLExample = "obsidian://open?file=Daily%2F{date}&prepend={text}"

    private var isAnyObsidianEnabled: Bool {
        isObsidianAutoOpenEnabled || isObsidianSendButtonEnabled
    }

    var body: some View {
        Form {
            Section(header: Text("Obsidian"),
                    footer: obsidianFooter) {
                Toggle(isOn: $isObsidianAutoOpenEnabled) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("转写后自动打开")
                            .font(.body)
                        Text("每次转写后打开 Obsidian，并把文本保存为笔记。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: isObsidianAutoOpenEnabled) { _, _ in
                    HapticManager.selectionChanged()
                }

                Toggle(isOn: $isObsidianSendButtonEnabled) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("显示「发送到 Obsidian」按钮")
                            .font(.body)
                        Text("在每条笔记的详情页加一个按钮，需要时发送转写。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: isObsidianSendButtonEnabled) { _, _ in
                    HapticManager.selectionChanged()
                }

                if isAnyObsidianEnabled {
                    Toggle(isOn: $isObsidianCustomURLEnabled) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("自定义 URL")
                                .font(.body)
                            Text("自己写完整的 URL，比如插入到日记笔记开头，或配合 Advanced URI 插件使用。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: isObsidianCustomURLEnabled) { _, _ in
                        HapticManager.selectionChanged()
                    }

                    if isObsidianCustomURLEnabled {
                        TextField(Self.customURLExample, text: $obsidianCustomURLTemplate, axis: .vertical)
                            .lineLimit(2...6)
                            .font(.callout.monospaced())
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    } else {
                        HStack {
                            Text("笔记名称")
                            Spacer()
                            TextField(UserDefaultsStorage.defaultObsidianNoteTemplate, text: $obsidianNoteTemplate)
                                .multilineTextAlignment(.trailing)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        }
                    }
                }
            }
        }
        .navigationTitle("集成")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var obsidianFooter: some View {
        if isAnyObsidianEnabled {
            if isObsidianCustomURLEnabled {
                // Verbatim: the literal "%2F" must not be read as a format specifier.
                Text(verbatim: "Changyan opens this URL after filling in the placeholders: \(NoteTemplate.placeholderList). {text} is the final text (AI-processed if a preset ran), {original} is the raw transcription. Values are URL-encoded automatically; type literal slashes in paths as %2F. Example for a daily note: \(Self.customURLExample). Any app's URL scheme works. The text is also copied to the clipboard, so &clipboard works too. Leave the field empty to use the standard note.")
            } else {
                Text("新转写会创建一篇 Obsidian 笔记；已有同名笔记时追加进去。占位符：\(NoteTemplate.placeholderList)。想改为追加到日记笔记，把名称只设为 {date}。每个模式的设置里可以单独关掉自动打开。每次都会覆盖剪贴板。")
            }
        }
    }
}
