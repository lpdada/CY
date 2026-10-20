// Copyright © 2026 Anton Novoselov. All rights reserved.

import SwiftUI
import OAuth
import AICore

/// Grok (xAI) setup: sign in with a SuperGrok / X Premium subscription, or use
/// an API key. Both hit the same `api.x.ai` endpoint - only the bearer differs.
struct GrokConfigurationView: View {
    let aiService: AIService

    @State private var hasExistingKey = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    if let iconName = AIProvider.grok.iconName {
                        Image(iconName)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 64, height: 64)
                    }

                    Text(AIProvider.grok.displayName)
                        .font(.title2)

                    if aiService.connectedProviders.contains(.grok) {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(aiService.isGrokSignedIn ? "Subscription Connected" : "API Key 已配置")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 8)

                GrokSubscriptionSection(aiService: aiService)

                GrokAPIKeySection(aiService: aiService, hasExistingKey: $hasExistingKey)

                GrokFallbackNote(isSignedIn: aiService.isGrokSignedIn, hasExistingKey: hasExistingKey)
            }
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(AIProvider.grok.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            hasExistingKey = AIProvider.grok.apiKey != nil
        }
    }
}

// MARK: - Subscription Sign-In

/// Drives xAI's device-code sign-in: request a code, send the user to the
/// browser to approve it, then poll until xAI reports the approval.
private struct GrokSubscriptionSection: View {
    let aiService: AIService

    @State private var deviceCode: DeviceCodeResponse?
    @State private var signInTask: Task<Void, Never>?
    @State private var showError = false
    @State private var errorMessage = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Grok 订阅")
                .font(.headline)

            Text("用你的 SuperGrok 或 X Premium 订阅代替 API Key。")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Set expectations before the user signs in: xAI gates which plans
            // may connect an app, so a valid subscription can still be refused.
            Label {
                Text("xAI 限制了哪些套餐可以连接 App，所以不是每个订阅都能用。API Key 则始终可用。")
            } icon: {
                Image(systemName: "info.circle")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if aiService.isGrokSignedIn {
                signedInRow
            } else if let deviceCode {
                pendingAuthorization(deviceCode)
            } else {
                signInButton
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(.background.secondary)
        }
        .onDisappear {
            signInTask?.cancel()
        }
        .alert("登录错误", isPresented: $showError) {
            Button("好") {}
        } message: {
            Text(errorMessage)
        }
    }

    private var signedInRow: some View {
        HStack {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("已登录")
                    .font(.callout)
                if let email = aiService.grokEmail {
                    Text(email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("退出登录", role: .destructive) {
                aiService.signOutFromGrok()
            }
            .controlSize(.small)
        }
    }

    private func pendingAuthorization(_ code: DeviceCodeResponse) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("在 x.ai 批准这个代码：")
                .font(.callout)

            Text(code.userCode)
                .font(.system(size: 28, weight: .bold, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)

            // The opened URI usually carries the code already, so copying is an
            // explicit action - it clobbers the clipboard and shows the system
            // paste banner, which is rude to do on the user's behalf.
            Button("复制代码", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = code.userCode
                HapticManager.success()
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .center)

            if let url = URL(string: code.browserURI) {
                Link(destination: url) {
                    Label("打开 x.ai 批准", systemImage: "arrow.up.right.square")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }

            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("等待批准…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("取消") {
                signInTask?.cancel()
                deviceCode = nil
            }
            .foregroundStyle(.red)
        }
    }

    private var signInButton: some View {
        Button {
            startSignIn()
        } label: {
            HStack(spacing: 6) {
                if aiService.isGrokSigningIn {
                    ProgressView()
                        .controlSize(.small)
                }
                Text("用 Grok 登录")
                    .font(.headline.weight(.medium))
            }
        }
        .disabled(aiService.isGrokSigningIn)
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .background {
            Capsule()
                .stroke(.blue, lineWidth: 2)
        }
        .buttonStyle(.plain)
    }

    private func startSignIn() {
        signInTask = Task {
            do {
                let code = try await aiService.startGrokDeviceCodeFlow()
                deviceCode = code

                if let url = URL(string: code.browserURI) {
                    await UIApplication.shared.open(url)
                }

                try await aiService.signInWithGrok(deviceCode: code)
                deviceCode = nil
                HapticManager.success()
            } catch is CancellationError {
                deviceCode = nil
            } catch {
                deviceCode = nil
                // A cancelled request can still surface as a transport error,
                // so don't alert on a sign-in the user walked away from.
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                showError = true
                HapticManager.error()
            }
        }
    }
}

// MARK: - API Key

private struct GrokAPIKeySection: View {
    let aiService: AIService
    @Binding var hasExistingKey: Bool

    @State private var apiKey = ""
    @State private var isVerifying = false
    @State private var verificationError: String?
    @State private var showDeleteConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("API Key")
                .font(.headline)

            Text("由 xAI 按 token 计费。任何账号都能用，解锁完整模型列表。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let apiKeyURL = AIProvider.grok.apiKeyURL {
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

            if let verificationError {
                Text(verificationError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

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
                        .stroke(.red, lineWidth: 1.5)
                }
                .padding(.top, 4)
            }
        }
        .padding()
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(.background.secondary)
        }
        .onAppear {
            apiKey = AIProvider.grok.apiKey ?? ""
        }
        .alert("删除 API Key", isPresented: $showDeleteConfirmation) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                deleteAPIKey()
            }
        } message: {
            Text("确定要删除 \(AIProvider.grok.displayName) 的 API Key 吗？此操作无法撤销。")
        }
    }

    private func saveAPIKey() {
        Task {
            isVerifying = true
            verificationError = nil
            HapticManager.mediumImpact()

            let success = await aiService.saveAPIKey(apiKey, for: .grok)
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
        guard let clipboard = UIPasteboard.general.string else { return }
        let trimmed = clipboard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        apiKey = trimmed
        saveAPIKey()
    }

    private func deleteAPIKey() {
        aiService.deleteAPIKey(for: .grok)
        apiKey = ""
        hasExistingKey = false
        aiService.refreshConnectedProviders()
        if !aiService.connectedProviders.contains(.grok) {
            aiService.disableAIEnhancementForModesUsingProvider(.grok)
        }
        HapticManager.success()
    }
}

// MARK: - Fallback Chain

private struct GrokFallbackNote: View {
    let isSignedIn: Bool
    let hasExistingKey: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("降级链", systemImage: "arrow.triangle.branch")
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                chip("Subscription", isActive: isSignedIn)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                chip("API Key", isActive: hasExistingKey)
            }
            .foregroundStyle(.secondary)

            // Be precise about which failure falls back: a broken token quietly
            // switches to the key, but xAI refusing the plan is reported instead
            // of silently spending API credits.
            Text("如果登录不可用——比如令牌刷新失败——会自动改用 API Key。")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Text("如果 xAI 拒绝的是订阅本身，会直接报错，而不是改用 API Key。")
                .font(.caption)
                .foregroundStyle(.tertiary)

            // Transcription deliberately breaks that rule: the audio is already
            // recorded, so losing it to a refused plan is worse than spending
            // API credits on the retry.
            Text("xAI 语音转文字用同一套凭据。那里如果订阅被拒，会用 API Key 重试，所以已录完的音频不会丢。")
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

    private func chip(_ title: String, isActive: Bool) -> some View {
        Text(title)
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isActive ? Color.green.opacity(0.15) : Color.secondary.opacity(0.1))
            .clipShape(.capsule)
    }
}
