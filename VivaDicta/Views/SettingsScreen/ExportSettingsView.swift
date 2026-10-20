//
//  ExportSettingsView.swift
//  VivaDicta
//
//  Created by Anton Novoselov on 2026.05.09
//

import SwiftUI
import AppGroup
import UniformTypeIdentifiers

/// Settings screen for the markdown folder-export integration. Two sibling
/// toggles control the hand-off:
/// - "Auto-export after transcription" (`isFolderExportGloballyEnabled`) drives
///   the silent post-transcription save in `FolderExportService.saveIfEnabled`
///   and gates the per-mode opt-out in `ModeEditView`.
/// - "Show Export to Folder button" (`isFolderExportButtonEnabled`) reveals a
///   manual export FAB on the transcription detail screen.
/// The folder picker, Markdown Export variation picker and the file section
/// (name template, write mode, entry template) are shared.
struct ExportSettingsView: View {
    @AppStorage(MarkdownExportContent.userDefaultsKey)
    private var markdownExportContent: MarkdownExportContent = .default

    @AppStorage(UserDefaultsStorage.Keys.isFolderExportGloballyEnabled)
    private var isFolderExportAutoEnabled = false

    @AppStorage(UserDefaultsStorage.Keys.isFolderExportButtonEnabled)
    private var isFolderExportButtonEnabled = false

    @AppStorage(UserDefaultsStorage.SharedKeys.folderExportDisplayName, store: UserDefaultsStorage.shared)
    private var folderExportDisplayName: String = ""

    @AppStorage(UserDefaultsStorage.Keys.folderExportFilenameTemplate)
    private var filenameTemplate = UserDefaultsStorage.defaultFolderExportFilenameTemplate

    @AppStorage(UserDefaultsStorage.Keys.folderExportWriteMode)
    private var writeMode: FolderExportWriteMode = .default

    @AppStorage(UserDefaultsStorage.Keys.folderExportEntryTemplate)
    private var entryTemplate = UserDefaultsStorage.defaultFolderExportEntryTemplate

    @State private var isFolderPickerPresented = false
    @State private var folderPickerError: String?

    private var isAnyExportEnabled: Bool {
        isFolderExportAutoEnabled || isFolderExportButtonEnabled
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("Markdown 导出", selection: $markdownExportContent) {
                        ForEach(MarkdownExportContent.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    Text("选择导出 Markdown 时包含什么。对手动分享、「导出到文件夹」按钮和下面的自动导出都生效。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .onChange(of: markdownExportContent) { _, _ in
                    HapticManager.selectionChanged()
                }
            }

            Section(header: Text("文件夹导出"), footer: exportFooter) {
                Toggle(isOn: $isFolderExportAutoEnabled) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("转写后自动导出")
                            .font(.body)
                        Text("每次转写后，自动把 .md 文件保存到下面选择的文件夹。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: isFolderExportAutoEnabled) { _, _ in
                    HapticManager.selectionChanged()
                }

                Toggle(isOn: $isFolderExportButtonEnabled) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("显示「导出到文件夹」按钮")
                            .font(.body)
                        Text("在每条笔记的详情页加一个按钮，需要时把 Markdown 文件保存到文件夹。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: isFolderExportButtonEnabled) { _, _ in
                    HapticManager.selectionChanged()
                }

                if isAnyExportEnabled {
                    Button {
                        isFolderPickerPresented = true
                    } label: {
                        HStack {
                            Text(folderExportDisplayName.isEmpty ? "Choose folder..." : "Folder")
                            Spacer()
                            if !folderExportDisplayName.isEmpty {
                                Text(folderExportDisplayName)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }

                    if !folderExportDisplayName.isEmpty {
                        Button("清空文件夹", role: .destructive) {
                            FolderExportService.clearBookmark()
                            folderExportDisplayName = ""
                        }
                    }
                }
            }

            if isAnyExportEnabled {
                Section(header: Text("文件"), footer: fileFooter) {
                    HStack {
                        Text("文件名")
                        Spacer()
                        TextField(UserDefaultsStorage.defaultFolderExportFilenameTemplate, text: $filenameTemplate)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }

                    Picker("如果文件已存在", selection: $writeMode) {
                        ForEach(FolderExportWriteMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .onChange(of: writeMode) { _, _ in
                        HapticManager.selectionChanged()
                    }

                    if writeMode != .replace {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("条目")
                            TextField(UserDefaultsStorage.defaultFolderExportEntryTemplate, text: $entryTemplate, axis: .vertical)
                                .lineLimit(2...8)
                                .font(.callout.monospaced())
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        }
                    }
                }
            }
        }
        .navigationTitle("导出笔记")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $isFolderPickerPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                guard url.startAccessingSecurityScopedResource() else {
                    folderPickerError = "Could not access the selected folder."
                    return
                }
                defer { url.stopAccessingSecurityScopedResource() }
                do {
                    try FolderExportService.storeBookmark(for: url)
                } catch {
                    folderPickerError = error.localizedDescription
                }
            case .failure(let error):
                folderPickerError = error.localizedDescription
            }
        }
        .alert("文件夹选择失败",
               isPresented: Binding(
                   get: { folderPickerError != nil },
                   set: { if !$0 { folderPickerError = nil } }
               ),
               presenting: folderPickerError) { _ in
            Button("好", role: .cancel) { folderPickerError = nil }
        } message: { message in
            Text(message)
        }
    }

    @ViewBuilder
    private var exportFooter: some View {
        if isAnyExportEnabled {
            Text("可以选任意文件夹，包括 Obsidian 仓库。每个模式的设置里可以单独关掉自动导出。")
        }
    }

    @ViewBuilder
    private var fileFooter: some View {
        switch writeMode {
        case .replace:
            Text("每个名称一个 Markdown 文件。占位符：\(NoteTemplate.placeholderList)。「/」会创建子文件夹，如 Daily/{date}。缺少 .md 时自动补上。名称对每条笔记唯一时（默认含秒数），每条转写都有自己的文件；重复导出同一条笔记会覆盖。")
        case .append, .prepend:
            Text("每条转写作为一个条目加入文件。例如文件名 Daily/{date} 会把一整天收集在同一篇笔记里。\(writeMode == .prepend ? "新条目加在顶部、YAML frontmatter 之后。" : "新条目加在末尾。")条目占位符：\(NoteTemplate.placeholderList)，以及 {markdown}（含各版本的完整导出）。{text} 是最终文本，{original} 是原始转写。条目带有隐藏标记，重复导出同一条笔记会更新它的条目，而不是再加一份。")
        }
    }
}
