//
//  AnthropicConfigurationView.swift
//  VivaDicta
//
//  Created by Anton Novoselov on 2026.03.26
//

import SwiftUI
import AICore

struct AnthropicConfigurationView: View {
    @Environment(\.dismiss) private var dismiss
    let aiService: AIService

    // API Key state
    @State private var apiKey: String = ""
    @State private var isVerifying = false
    @State private var verificationError: String?
    @State private var hasExistingKey = false
    @State private var showDeleteConfirmation = false
    @State private var isAnthropicCliEnabled = VivAgentsClient.isAnthropicCliEnabled
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 8) {
                    if let iconName = AIProvider.anthropic.iconName {
                        Image(iconName)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 64, height: 64)
                    }

                    Text("Anthropic")
                        .font(.title2)

                    if aiService.connectedProviders.contains(.anthropic) {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(VivAgentsClient.isEnabled && VivAgentsClient.isAnthropicCliActive ? "VivAgents 服务器已连接" : "API Key 已配置")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 8)

                // Model availability note
//                modelAvailabilityNote

                // VivAgents Server section
                cliServerStatusSection

                // API Key section
                apiKeySection

                // Fallback chain
                fallbackChainNote
            }
            .padding()
        }
        .contentShape(.rect)
        .onTapGesture {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        .navigationTitle("Anthropic")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            let existingKey = AIProvider.anthropic.apiKey
            apiKey = existingKey ?? ""
            hasExistingKey = existingKey != nil
        }
        .alert("删除 API Key", isPresented: $showDeleteConfirmation) {
            Button("取消", role: .cancel) { }
            Button("删除", role: .destructive) {
                deleteAPIKey()
            }
        } message: {
            Text("确定要删除 Anthropic 的 API Key 吗？此操作无法撤销。")
        }
    }

    // MARK: - Model Availability Note

    private var modelAvailabilityNote: some View {
        Label {
            Text("CLI 代理只支持有限的模型。要用全部模型请使用 API Key。")
        } icon: {
            Image(systemName: "info.circle")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - VivAgents Server Status Section

    private var cliServerStatusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Anthropic CLI 代理")
                .font(.headline)

            if VivAgentsClient.isEnabled && VivAgentsClient.isAnthropicCliAvailable {
                Toggle("使用 Anthropic CLI 代理", isOn: $isAnthropicCliEnabled)
                    .onChange(of: isAnthropicCliEnabled) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: VivAgentsClient.anthropicCliEnabledKey)
                        aiService.refreshConnectedProviders()
                    }

                if isAnthropicCliEnabled {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Anthropic CLI 已启用")
                            .font(.callout)
                    }
                }
            } else {
                Text("使用 VivAgents 服务器。不需要 API Key。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                NavigationLink {
                    CLIServerConfigurationView(aiService: aiService)
                } label: {
                    Text("配置 VivAgents 服务器")
                        .font(.callout)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(.background.secondary)
        }
    }

    // MARK: - API Key Section

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("API Key")
                .font(.headline)

            Text("最快、最可靠的选择。没有速率限制。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let apiKeyURL = AIProvider.anthropic.apiKeyURL {
                Button {
                    UIApplication.shared.open(apiKeyURL)
                } label: {
                    Label("获取 API Key", systemImage: "key")
                        .font(.headline.weight(.medium))
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            }

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
                    verificationError = nil
                }

            if let error = verificationError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if #available(iOS 26.0, *) {
                HStack {
                    Button {
                        saveAPIKey()
                    } label: {
                        HStack(spacing: 6) {
                            if isVerifying {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text("保存 API Key")
                                .font(.headline.weight(.medium))
                        }
                    }
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isVerifying)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                    .glassEffect(.regular.tint(.blue.opacity(0.3)).interactive())
                    .buttonStyle(.plain)

                    Button {
                        if let clipboardString = UIPasteboard.general.string {
                            let trimmed = clipboardString.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                apiKey = trimmed
                                saveAPIKey()
                            }
                        }
                    } label: {
                        Text("粘贴")
                            .font(.headline.weight(.medium))
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                    .glassEffect(.regular.tint(.gray.opacity(0.3)).interactive())
                    .buttonStyle(.plain)
                }

                if hasExistingKey {
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
                    .padding(.top, 4)
                }
            } else {
                HStack {
                    Button {
                        saveAPIKey()
                    } label: {
                        HStack(spacing: 6) {
                            if isVerifying {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text("保存 API Key")
                                .font(.headline.weight(.medium))
                                .foregroundStyle(.primary)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 16)
                        .background {
                            Capsule()
                                .stroke(.blue, lineWidth: 2)
                        }
                    }
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isVerifying)
                    .buttonStyle(.plain)

                    Button {
                        if let clipboardString = UIPasteboard.general.string {
                            let trimmed = clipboardString.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                apiKey = trimmed
                                saveAPIKey()
                            }
                        }
                    } label: {
                        Text("粘贴")
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

                if hasExistingKey {
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
                    .padding(.top, 4)
                }
            }
        }
        .padding()
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(.background.secondary)
        }
    }

    // MARK: - Fallback Chain

    private var fallbackChainNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("降级链", systemImage: "arrow.triangle.branch")
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Text("VivAgents")
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(VivAgentsClient.isEnabled && VivAgentsClient.isVerified ? Color.green.opacity(0.15) : Color.secondary.opacity(0.1))
                    .clipShape(.capsule)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text("API Key")
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(hasExistingKey ? Color.green.opacity(0.15) : Color.secondary.opacity(0.1))
                    .clipShape(.capsule)
            }
            .foregroundStyle(.secondary)

            Text("如果第一个可用方法失败，会自动尝试下一个。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(.background.secondary)
        }
    }

    // MARK: - Actions

    private func saveAPIKey() {
        Task {
            isVerifying = true
            verificationError = nil
            HapticManager.mediumImpact()

            let isValid = await aiService.saveAPIKey(apiKey, for: .anthropic)

            isVerifying = false
            if isValid {
                hasExistingKey = true
                HapticManager.success()
            } else {
                verificationError = "API Key 无效。请检查你的 Key 后重试。"
                HapticManager.error()
            }
        }
    }

    private func deleteAPIKey() {
        HapticManager.heavyImpact()
        aiService.deleteAPIKey(for: .anthropic)
        apiKey = ""
        hasExistingKey = false
        aiService.refreshConnectedProviders()
        // Only disable modes if VivAgents Server isn't keeping Anthropic connected
        if !aiService.connectedProviders.contains(.anthropic) {
            aiService.disableAIEnhancementForModesUsingProvider(.anthropic)
        }
    }
}

#if DEBUG || QA
#Preview {
    NavigationStack {
        AnthropicConfigurationView(aiService: AIService())
    }
}
#endif
