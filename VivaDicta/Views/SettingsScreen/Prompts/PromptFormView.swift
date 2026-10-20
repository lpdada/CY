//
//  PromptFormView.swift
//  VivaDicta
//
//  Created by Anton Novoselov on 2025.09.16
//

import SwiftUI
import TipKit

/// Unified view for creating and editing prompts
struct PromptFormView: View {
    @Environment(\.dismiss) var dismiss

    let promptsManager: PromptsManager
    let transcriptTagsTip = TranscriptTagsTip()

    // For creating new prompts from template
    private let template: PromptsTemplates?

    // For editing existing prompts
    private let editingPrompt: UserPrompt?

    // AIService to sync prompt changes with modes (only needed when editing)
    private let aiService: AIService?

    // Callback when prompt is saved (used when presented as sheet)
    private let onComplete: (() -> Void)?

    // User's name for email template (replaces [Your Name] placeholder)
    private let emailUserName: String?

    @State private var title: String = ""
    @State private var promptInstructions: String = ""
    @State private var useSystemTemplate: Bool = true
    @State private var wrapInTranscriptTags: Bool = true
    @State private var showInstructionsEditor = false
    @State private var showingAlert = false
    @State private var promptError: SettingsError = .duplicatePromptName("")
    @State private var showDeleteConfirmation = false

    private var isEditMode: Bool {
        editingPrompt != nil
    }

    private var navigationTitle: String {
        if isEditMode {
            return "Edit Prompt"
        } else {
            let templateName = template?.displayName ?? "Custom"
            return "New \(templateName) Prompt"
        }
    }

    private var isFormValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Initializers

    /// Create a new prompt from a template
    init(template: PromptsTemplates?,
         promptsManager: PromptsManager,
         emailUserName: String? = nil,
         onComplete: (() -> Void)? = nil) {
        self.template = template
        self.editingPrompt = nil
        self.aiService = nil
        self.promptsManager = promptsManager
        self.emailUserName = emailUserName
        self.onComplete = onComplete
    }

    /// Edit an existing prompt
    init(editingPrompt: UserPrompt,
         promptsManager: PromptsManager,
         aiService: AIService) {
        self.template = nil
        self.editingPrompt = editingPrompt
        self.aiService = aiService
        self.promptsManager = promptsManager
        self.emailUserName = nil
        self.onComplete = nil
    }

    // MARK: - Body

    var body: some View {
        Form {
            Section(header: Text("提示词名称")) {
                TextField("标题", text: $title)
            }

            Section(
                header: Text("提示词指令"),
                footer: template == .custom ? Text("小提示：用 <TRANSCRIPT> 引用转写的文本。\n例如：「整理 <TRANSCRIPT> 并修正语法」") : nil
            ) {
                Button {
                    showInstructionsEditor = true
                } label: {
                    Text(promptInstructions.isEmpty ? "Tap to add instructions" : promptInstructions)
                        .lineLimit(3)
                        .foregroundStyle(promptInstructions.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("编辑提示词指令")
                .accessibilityHint(promptInstructions.isEmpty ? "Double tap to add instructions" : "Current instructions: \(promptInstructions)")

                TipView(transcriptTagsTip)
            }

            Section {
                DisclosureGroup("Advanced Settings") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("使用系统指令", isOn: $useSystemTemplate)

                        Text("开启后，你的指令会与系统指令合并，以提高转写质量。关掉可完全掌控 AI 提示词。注意：在设置里开启拼写纠正后，它始终会包含在内。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("包上 <TRANSCRIPT> 标签", isOn: $wrapInTranscriptTags)

                        Text("开启后，转写文本会先包上 <TRANSCRIPT> 标签再发送给 AI。用我们的提示词模板时请保持开启，因为模板就是用这个标签引用文本的。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if isEditMode {
                if isFormValid {
                    Section {
                        
                        Button {
                            duplicatePrompt()
                        } label: {
                            HStack {
                                Spacer()
                                Label("复制提示词", systemImage: "doc.on.doc")
                                Spacer()
                            }
                        }
                    }
                }
                
                Section {
                    Button(role: .destructive) {
                        deletePrompt()
                    } label: {
                        HStack {
                            Spacer()
                            Label("删除提示词", systemImage: "trash")
                                .foregroundStyle(.red)
                            Spacer()
                        }
                    }
                }
            }
            
        }
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle(navigationTitle)
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            if !isEditMode {
                ToolbarItem(placement: .cancellationAction) {
                    if #available(iOS 26, *) {
                        Button("关闭", systemImage: "xmark") {
                            dismiss()
                        }
                        .labelStyle(.iconOnly)
                    } else {
                        Button("取消") {
                            dismiss()
                        }
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if #available(iOS 26, *) {
                    Button(role: .confirm) {
                        savePrompt()
                    }
                    .disabled(!isFormValid)
                    .tint(.blue)
                } else {
                    Button("保存") {
                        savePrompt()
                    }
                    .disabled(!isFormValid)
                }
            }
        }
        .onAppear {
            setupInitialValues()
            Task {
                await TranscriptTagsTip.promptEditOpenedEvent.donate()
            }
        }
        .fullScreenCover(isPresented: $showInstructionsEditor) {
            NavigationStack {
                PromptInstructionsEditorView(instructions: $promptInstructions)
            }
        }
        .alert(isPresented: $showingAlert,
               error: promptError,
               actions: { _ in },
               message: { error in
            Text(error.failureReason)
        })
        .alert("删除提示词？", isPresented: $showDeleteConfirmation) {
            Button("取消", role: .cancel) { }
            Button("删除", role: .destructive) {
                deletePrompt()
            }
        } message: {
            Text("此操作无法撤销。")
        }
    }

    // MARK: - Private Methods

    private func setupInitialValues() {
        if let existingPrompt = editingPrompt {
            // Edit mode: pre-fill with existing prompt data
            title = existingPrompt.title
            promptInstructions = existingPrompt.promptInstructions
            useSystemTemplate = existingPrompt.useSystemTemplate
            wrapInTranscriptTags = existingPrompt.wrapInTranscriptTags
        } else if let template = template, template != .custom {
            // Create mode with template: pre-fill from template
            title = template.defaultTitle
            var instructions = template.prompt

            // For email template, replace [Your Name] with user's name if provided
            if template == .email,
               let userName = emailUserName,
               !userName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                instructions = instructions.replacing("[Your Name]", with: userName)
            }

            promptInstructions = instructions
        }
        // Create mode without template or custom: leave empty
    }

    private func savePrompt() {
        HapticManager.lightImpact()
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)

        if isEditMode {
            saveExistingPrompt(trimmedTitle: trimmedTitle)
        } else {
            saveNewPrompt(trimmedTitle: trimmedTitle)
        }
    }

    private func saveNewPrompt(trimmedTitle: String) {
        if promptsManager.isPromptNameDuplicate(trimmedTitle) {
            promptError = .duplicatePromptName(trimmedTitle)
            showingAlert = true
            return
        }

        let prompt = UserPrompt(
            title: trimmedTitle,
            promptInstructions: promptInstructions,
            useSystemTemplate: useSystemTemplate,
            wrapInTranscriptTags: wrapInTranscriptTags
        )

        promptsManager.addPrompt(prompt)
        dismissAndComplete()
    }

    private func saveExistingPrompt(trimmedTitle: String) {
        guard let existingPrompt = editingPrompt else { return }

        if promptsManager.isPromptNameDuplicate(trimmedTitle, excludingId: existingPrompt.id) {
            promptError = .duplicatePromptName(trimmedTitle)
            showingAlert = true
            return
        }

        let updatedPrompt = UserPrompt(
            id: existingPrompt.id,
            title: trimmedTitle,
            promptInstructions: promptInstructions,
            useSystemTemplate: useSystemTemplate,
            wrapInTranscriptTags: wrapInTranscriptTags,
            createdAt: existingPrompt.createdAt
        )

        promptsManager.updatePrompt(updatedPrompt)

        dismiss()
    }

    private func dismissAndComplete() {
        dismiss()
        onComplete?()
    }

    private func duplicatePrompt() {
        guard let existingPrompt = editingPrompt else { return }
        HapticManager.lightImpact()
        promptsManager.duplicatePrompt(existingPrompt)
        dismiss()
    }

    private func deletePrompt() {
        guard let existingPrompt = editingPrompt else { return }
        HapticManager.lightImpact()
        promptsManager.deletePrompt(existingPrompt)
        dismiss()
    }
}
