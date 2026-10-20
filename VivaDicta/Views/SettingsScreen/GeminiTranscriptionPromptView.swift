// Copyright © 2026 Anton Novoselov. All rights reserved.

import AppGroup
import CloudTranscription
import SwiftUI

/// Editor for the instruction sent alongside the audio to Gemini's
/// general-purpose models.
///
/// Only those models are prompted at all: `gemini-3.5-transcribe` goes through
/// the Interactions API, which rejects a developer instruction outright, so a
/// custom prompt has no effect when it is the selected model.
struct GeminiTranscriptionPromptView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage(AppGroupCoordinator.kGeminiTranscriptionPrompt, store: UserDefaultsStorage.shared)
    private var storedPrompt = ""

    @State private var draft = ""
    @FocusState private var isEditorFocused: Bool

    private var defaultPrompt: String { GeminiTranscriptionService.defaultTranscriptionPrompt }

    var body: some View {
        Form {
            Section {
                TextEditor(text: $draft)
                    .frame(minHeight: 140)
                    .focused($isEditorFocused)
                    .autocorrectionDisabled()
            } header: {
                Text("指令")
            } footer: {
                Text("随音频一起发送给 Gemini 的通用模型。留空则用内置指令。")
            }

            Section {
                Text(defaultPrompt)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Button("恢复默认") {
                    draft = ""
                    HapticManager.lightImpact()
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("内置指令")
            }

            Section {
                Label(
                    "Gemini 3.5 Transcribe 会忽略这个——Google 的专用转写模型不接受指令。",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } footer: {
                Text("如果提示词要求的是转写以外的内容——比如摘要、翻译——返回的就会是那个结果，App 的其他部分会把它当作转写文本处理。")
            }
        }
        .navigationTitle("转写提示词")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { draft = storedPrompt }
        .onDisappear { save() }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") {
                    save()
                    isEditorFocused = false
                    dismiss()
                }
            }
        }
    }

    /// Blank and whitespace-only drafts are stored as empty, which is how the
    /// transcription layer is told to fall back to the built-in instruction.
    private func save() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != storedPrompt else { return }
        storedPrompt = trimmed
    }
}

#Preview {
    NavigationStack {
        GeminiTranscriptionPromptView()
    }
}
