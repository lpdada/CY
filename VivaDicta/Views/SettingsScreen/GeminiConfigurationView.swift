// Copyright © 2026 Anton Novoselov. All rights reserved.

import SwiftUI
import OAuth
import AICore

struct GeminiConfigurationView: View {
    @Environment(\.dismiss) private var dismiss
    let aiService: AIService

    // API Key state
    @State private var apiKey: String = ""
    @State private var isVerifying = false
    @State private var verificationError: String?
    @State private var hasExistingKey = false
    @State private var showDeleteConfirmation = false
    @State private var isGeminiCliEnabled = VivAgentsClient.isGeminiCliEnabled
    // OAuth error
    @State private var showOAuthError = false
    @State private var oauthErrorMessage = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 8) {
                    if let iconName = AIProvider.gemini.iconName {
                        Image(iconName)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 64, height: 64)
                    }

                    Text("Gemini")
                        .font(.title2)

                    if aiService.connectedProviders.contains(.gemini) {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(geminiConnectionLabel)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 8)

                // Model availability note
                modelAvailabilityNote

                // Google OAuth section
                geminiOAuthSection

                // CLI Server section
                geminiCLIServerSection

                // API Key section
                apiKeySection

                // Fallback chain
                fallbackChainNote
            }
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Gemini")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            let existingKey = AIProvider.gemini.apiKey
            apiKey = existingKey ?? ""
            hasExistingKey = existingKey != nil
        }
        .alert("登录错误", isPresented: $showOAuthError) {
            Button("好") {}
        } message: {
            Text(oauthErrorMessage)
        }
        .alert("删除 API Key", isPresented: $showDeleteConfirmation) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                deleteAPIKey()
            }
        } message: {
            Text("确定要删除 Gemini 的 API Key 吗？此操作无法撤销。")
        }
    }

    // MARK: - Model Availability Note

    private var modelAvailabilityNote: some View {
        Label {
            Text("OAuth 和 CLI 代理连接只支持有限的模型。要用全部模型请使用 API Key。")
        } icon: {
            Image(systemName: "info.circle")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Google OAuth Section

    private var geminiOAuthSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Google 账号")
                .font(.headline)

            Text("用你的 Google 账号使用 Gemini——不需要 API Key。可能有速率限制且响应较慢。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if aiService.isGeminiSignedIn {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("已登录")
                            .font(.callout)
                        if let email = aiService.geminiEmail {
                            Text(email)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("退出登录", role: .destructive) {
                        aiService.signOutFromGemini()
                    }
                    .controlSize(.small)
                }
            } else {
                if #available(iOS 26.0, *) {
                    Button {
                        signInWithGemini()
                    } label: {
                        HStack(spacing: 6) {
                            if aiService.isGeminiSigningIn {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text("用 Google 登录")
                                .font(.headline.weight(.medium))
                        }
                    }
                    .disabled(aiService.isGeminiSigningIn)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                    .glassEffect(.regular.tint(.blue.opacity(0.3)).interactive())
                    .buttonStyle(.plain)
                } else {
                    Button {
                        signInWithGemini()
                    } label: {
                        HStack(spacing: 6) {
                            if aiService.isGeminiSigningIn {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text("用 Google 登录")
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
                    .disabled(aiService.isGeminiSigningIn)
                    .buttonStyle(.plain)
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

            if let apiKeyURL = AIProvider.gemini.apiKeyURL {
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
                        pasteAndSave()
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
                        pasteAndSave()
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
                Text("OAuth")
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(aiService.isGeminiSignedIn ? Color.green.opacity(0.15) : Color.secondary.opacity(0.1))
                    .clipShape(.capsule)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text("VivAgents")
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(VivAgentsClient.isEnabled && VivAgentsClient.isGeminiCliActive ? Color.green.opacity(0.15) : Color.secondary.opacity(0.1))
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

    // MARK: - CLI Server Section

    private var geminiConnectionLabel: String {
        if aiService.isGeminiSignedIn {
            return "Google Connected"
        } else if VivAgentsClient.isEnabled && VivAgentsClient.isGeminiCliActive {
            return "VivAgents 服务器已连接"
        } else {
            return "API Key 已配置"
        }
    }

    private var geminiCLIServerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Gemini CLI 代理")
                .font(.headline)

            if VivAgentsClient.isEnabled && VivAgentsClient.isGeminiCliAvailable {
                Toggle("使用 Gemini CLI 代理", isOn: $isGeminiCliEnabled)
                    .onChange(of: isGeminiCliEnabled) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: VivAgentsClient.geminiCliEnabledKey)
                        aiService.refreshConnectedProviders()
                    }

                if isGeminiCliEnabled {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Gemini CLI 已启用")
                            .font(.callout)
                    }
                }
            } else {
                Text("通过 VivAgents 服务器使用你的 Gemini CLI 账号。不需要 API Key。")
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

    // MARK: - Actions

    private func signInWithGemini() {
        Task {
            do {
                try await aiService.signInWithGemini()
            } catch {
                oauthErrorMessage = error.localizedDescription
                showOAuthError = true
            }
        }
    }

    private func saveAPIKey() {
        Task {
            isVerifying = true
            verificationError = nil
            HapticManager.mediumImpact()

            let success = await aiService.saveAPIKey(apiKey, for: .gemini)
            isVerifying = false
            if success {
                hasExistingKey = true
                HapticManager.success()
            } else {
                verificationError = "API Key 无效"
                HapticManager.error()
            }
        }
    }

    private func pasteAndSave() {
        if let clipboardString = UIPasteboard.general.string {
            let trimmed = clipboardString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                apiKey = trimmed
                saveAPIKey()
            }
        }
    }

    private func deleteAPIKey() {
        aiService.deleteAPIKey(for: .gemini)
        apiKey = ""
        hasExistingKey = false
        aiService.refreshConnectedProviders()
        if !aiService.connectedProviders.contains(.gemini) {
            aiService.disableAIEnhancementForModesUsingProvider(.gemini)
        }
        HapticManager.success()
    }
}
