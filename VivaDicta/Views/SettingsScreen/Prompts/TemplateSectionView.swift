//
//  TemplateSectionView.swift
//  VivaDicta
//
//  Created by Anton Novoselov on 2025.09.16
//

import SwiftUI

struct TemplateSelectionView: View {
    var promptsManager: PromptsManager
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTemplate: PromptsTemplates?
    @State private var showEmailNameAlert = false
    @State private var emailUserName = ""
    @State private var pendingEmailTemplate: PromptsTemplates?

    var body: some View {
        List(PromptsTemplates.allCases) { template in
            Button {
                if template == .email {
                    emailUserName = ""
                    pendingEmailTemplate = template
                    showEmailNameAlert = true
                } else {
                    selectedTemplate = template
                }
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(template.displayName)
                        .font(.headline)

                    Text(template.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
        }
        .navigationTitle("选择模板")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.visible)
        .fullScreenCover(item: $selectedTemplate) { template in
            NavigationStack {
                PromptFormView(
                    template: template,
                    promptsManager: promptsManager,
                    emailUserName: template == .email ? emailUserName : nil,
                    onComplete: {
                        dismiss()
                    }
                )
            }
        }
        .alert("输入你的全名，用于邮件提示词", isPresented: $showEmailNameAlert) {
            TextField("全名", text: $emailUserName)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
            Button("取消", role: .cancel) {
                emailUserName = ""
                selectedTemplate = pendingEmailTemplate
                pendingEmailTemplate = nil
            }
            Button("好") {
                selectedTemplate = pendingEmailTemplate
                pendingEmailTemplate = nil
            }
        }
    }
}
