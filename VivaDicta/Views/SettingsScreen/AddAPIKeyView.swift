//
//  AddAPIKeyView.swift
//  VivaDicta
//
//  Created by Anton Novoselov on 2025.09.12
//

import SwiftUI
import AICore

struct AddAPIKeyView: View {
    @Environment(\.dismiss) var dismiss
    let provider: AIProvider
    let aiService: AIService

    @State private var apiKey: String = ""
    @State private var isVerifying: Bool = false
    @State private var verificationError: String? = nil
    @State private var clearButtonVisible = false
    @State private var showDeleteConfirmation = false
    @State private var hasExistingKey = false

    var onSave: (AIProvider) -> Void
    
    var body: some View {
        VStack(spacing: 10) {
            if let iconName = provider.iconName {
                Image(iconName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)
            }

            Text("\(provider.displayName) API Key")
                .font(.title2)
            
            
            TextField("API Key", text: $apiKey)
                .privacySensitive()
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding()
                .background {
                    Capsule()
                        .stroke(verificationError != nil ? .red : .gray, lineWidth: verificationError != nil ? 1.5 : 0.5)
                }
                .onChange(of: apiKey) { _, _ in
                    // Clear error when user starts typing
                    verificationError = nil
                    clearButtonVisible = !apiKey.isEmpty
                }
            
            
            if #available(iOS 26.0, *) {
                Button {
                    if let clipboardString = UIPasteboard.general.string {
                        let trimmed = clipboardString.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            apiKey = trimmed
                            saveKey()
                        }
                    }
                } label: {
                    Text("从剪贴板粘贴")
                        .font(.headline.weight(.medium))
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 16)
                .glassEffect(.regular.tint(.blue.opacity(0.3)).interactive())
                .buttonStyle(.plain)
                .accessibilityLabel("从剪贴板粘贴")
            } else {
                Button {
                    if let clipboardString = UIPasteboard.general.string {
                        let trimmed = clipboardString.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            apiKey = trimmed
                            saveKey()
                        }
                    }
                } label: {
                    Text("从剪贴板粘贴")
                        .font(.headline.weight(.medium))
                        .foregroundStyle(.primary)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 16)
                        .background {
                            Capsule()
                                .stroke(.blue, lineWidth: 2)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("从剪贴板粘贴")
            }
            

            if let apiKeyURL = provider.apiKeyURL {
                Button {
                    UIApplication.shared.open(apiKeyURL)
                } label: {
                    Label("获取 API Key", systemImage: "key")
                        .font(.headline.weight(.medium))
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }

            if clearButtonVisible {
                if #available(iOS 26.0, *) {
                    Button {
                        apiKey = ""
                        HapticManager.lightImpact()
                    } label: {
                        Text("清除")
                            .font(.headline.weight(.medium))
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                    .glassEffect(.regular.tint(.gray.opacity(0.3)).interactive())
                    .buttonStyle(.plain)
                } else {
                    Button {
                        apiKey = ""
                        HapticManager.lightImpact()
                    } label: {
                        Text("清除")
                            .font(.headline.weight(.medium))
                            .foregroundStyle(.primary)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 16)
                            .background {
                                Capsule()
                                    .stroke(.gray, lineWidth: 2)
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            
            if let error = verificationError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            // Delete API Key button - only show if there's an existing key
            if hasExistingKey {
                if #available(iOS 26.0, *) {
                    Button {
                        showDeleteConfirmation = true
                        HapticManager.warning()
                    } label: {
                        Text("删除 API Key")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.red)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                    .glassEffect(.regular.tint(.red.opacity(0.2)).interactive())
                    .padding(.top, 8)
                } else {
                    Button {
                        showDeleteConfirmation = true
                        HapticManager.warning()
                    } label: {
                        Text("删除 API Key")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.red)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                    .overlay {
                        Capsule()
                            .stroke(Color.red, lineWidth: 1.5)
                    }
                    .padding(.top, 8)
                }
            }

            Spacer()
        }
        .animation(.easeInOut(duration: 0.2), value: clearButtonVisible)
        .onAppear {
            // Load existing API key from Keychain (synced via iCloud Keychain)
            let existingKey = provider.apiKey
            apiKey = existingKey ?? ""
            hasExistingKey = existingKey != nil
            clearButtonVisible = !apiKey.isEmpty
        }
        .padding()
        .contentShape(.rect)
        .onTapGesture {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        .navigationTitle("API Key")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isVerifying {
                    ProgressView()
                } else {
                    if #available(iOS 26, *) {
                        Button(role: .confirm) {
                            saveKey()
                        }
                        .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .tint(.blue)
                    } else {
                        Button("保存") {
                            saveKey()
                        }
                        .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .alert("删除 API Key", isPresented: $showDeleteConfirmation) {
            Button("取消", role: .cancel) { }
            Button("删除", role: .destructive) {
                deleteAPIKey()
            }
        } message: {
            Text("确定要删除 \(provider.displayName) 的 API Key 吗？此操作无法撤销。")
        }
    }

    private func deleteAPIKey() {
        HapticManager.heavyImpact()

        // Remove the API key from Keychain
        aiService.deleteAPIKey(for: provider)

        // Clear the text field and update state
        apiKey = ""
        hasExistingKey = false
        clearButtonVisible = false

        // Refresh connected providers
        aiService.refreshConnectedProviders()

        // Disable AI processing for modes using this provider
        aiService.disableAIEnhancementForModesUsingProvider(provider)

        onSave(provider)
        dismiss()
    }
    
    func saveKey() {
        Task {
            isVerifying = true
            verificationError = nil
            
            HapticManager.mediumImpact()
            
            let isValid = await aiService.saveAPIKey(apiKey, for: provider)
            
            isVerifying = false
                
            if isValid {
                onSave(provider)
                dismiss()
            } else {
                verificationError = "API Key 无效。请检查你的 Key 后重试。"
            }
        }
    }
}

#Preview {
    NavigationStack {
        AddAPIKeyView(
            provider: .openAI,
            aiService: AIService(),
            onSave: {_ in })
    }
}
