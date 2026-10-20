//
//  CustomOpenAIConfigurationView.swift
//  VivaDicta
//
//  Created by Anton Novoselov on 2026.01.17
//

import SwiftUI
import os
import AICore

private let logger = Logger(subsystem: "com.antonnovoselov.VivaDicta", category: "CustomOpenAIConfig")

struct CustomOpenAIConfigurationView: View {
    @Environment(\.dismiss) private var dismiss
    let aiService: AIService

    @State private var endpointURL: String = ""
    @State private var modelName: String = ""
    @State private var apiKey: String = ""
    @State private var isChecking = false
    @State private var connectionStatus: ConnectionStatus = .unknown
    @State private var showingClearConfirmation = false

    enum ConnectionStatus: Equatable {
        case unknown
        case checking
        case connected
        case failed(message: String)
        case invalidURL
        case missingModel
    }

    private var isConfigured: Bool {
        !aiService.customOpenAIEndpointURL.isEmpty && !aiService.customOpenAIModelName.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Icon
                Image(systemName: "server.rack")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)

                Text("自定义 AI 服务商")
                    .font(.title2)

                Text("OpenAI 兼容 API")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                // Connection status
                connectionStatusView

                // Input fields
                VStack(spacing: 20) {
                    // Endpoint URL input
                    VStack(alignment: .leading, spacing: 8) {
                        Text("接口 URL")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        TextField("服务器 URL", text: $endpointURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding()
                            .background {
                                Capsule()
                                    .stroke(urlFieldBorderColor, lineWidth: urlFieldBorderWidth)
                            }
                            .onChange(of: endpointURL) { _, newValue in
                                let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                                if !trimmed.isEmpty && !isValidURL(trimmed) {
                                    connectionStatus = .invalidURL
                                } else if connectionStatus == .invalidURL {
                                    connectionStatus = .unknown
                                }
                            }

                        Text("完整的对话补全接口 URL。\n例如：https://openrouter.ai/api/v1/chat/completions")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    // Model Name input
                    VStack(alignment: .leading, spacing: 8) {
                        Text("模型名称")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        TextField("gpt-4, llama-3.1-70b, etc.", text: $modelName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding()
                            .background {
                                Capsule()
                                    .stroke(modelFieldBorderColor, lineWidth: modelFieldBorderWidth)
                            }
                            .onChange(of: modelName) { _, newValue in
                                let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                                if trimmed.isEmpty && connectionStatus != .unknown {
                                    connectionStatus = .missingModel
                                } else if connectionStatus == .missingModel && !trimmed.isEmpty {
                                    connectionStatus = .unknown
                                }
                            }

                        Text("你的 API 服务器要求的模型标识。")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    // API Key input (optional)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("API Key（可选）")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        SecureField("sk-...", text: $apiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .privacySensitive()
                            .padding()
                            .background {
                                Capsule()
                                    .stroke(Color.gray, lineWidth: 0.5)
                            }

                        Text("如果你的服务器不需要认证，留空。")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal)

                // Action buttons
                VStack(spacing: 12) {
                    // Test & Save button
                    if #available(iOS 26.0, *) {
                        Button {
                            testAndSave()
                        } label: {
                            HStack {
                                if case .checking = connectionStatus {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                Text(connectionStatus == .checking ? "Connecting..." : "Test & Save")
                                    .font(.headline.weight(.medium))
                            }
                        }
                        .disabled(isChecking || !canTestConnection)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 16)
                        .glassEffect(.regular.tint(.blue.opacity(0.3)).interactive())
                        .buttonStyle(.plain)
                    } else {
                        Button {
                            testAndSave()
                        } label: {
                            HStack {
                                if case .checking = connectionStatus {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                Text(connectionStatus == .checking ? "Connecting..." : "Test & Save")
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
                        .disabled(isChecking || !canTestConnection)
                        .buttonStyle(.plain)
                    }

                    // Clear Configuration button (only shown when configured)
                    if isConfigured {
                        Button(role: .destructive) {
                            showingClearConfirmation = true
                        } label: {
                            Label("清除配置", systemImage: "trash")
                                .font(.subheadline)
                        }
                    }
                }

                // Help text
                VStack(spacing: 8) {
                    Text("连接到任意 OpenAI 兼容的 API 服务器。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Text("支持 LiteLLM、vLLM、Ollama 及其他兼容服务器。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 8)
                .padding(.bottom)
            }
            .padding()
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onTapGesture {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("自定义 AI 服务商")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loadExistingConfiguration()
        }
        .confirmationDialog(
            "清除配置",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("清除", role: .destructive) {
                clearConfiguration()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会删除你的自定义 OpenAI 配置，并停用所有使用它的模式的 AI 处理。")
        }
    }

    @ViewBuilder
    private var connectionStatusView: some View {
        switch connectionStatus {
        case .unknown:
            EmptyView()

        case .checking:
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("正在测试连接…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

        case .connected:
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("连接成功")
                Text("连接成功")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

        case .failed(let message):
            HStack(alignment: .top) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .accessibilityLabel("连接失败")
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }

        case .invalidURL:
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("URL 无效")
                Text("URL 无效。请用 http:// 或 https://")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

        case .missingModel:
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("缺少模型名称")
                Text("请输入模型名称")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var trimmedModelName: String {
        modelName.trimmingCharacters(in: .whitespaces)
    }

    private var trimmedEndpointURL: String {
        endpointURL.trimmingCharacters(in: .whitespaces)
    }

    private var canTestConnection: Bool {
        !trimmedEndpointURL.isEmpty && !trimmedModelName.isEmpty && connectionStatus != .invalidURL
    }

    private var urlFieldBorderColor: Color {
        switch connectionStatus {
        case .invalidURL:
            return .orange
        case .connected:
            return .green
        case .failed:
            return .red
        default:
            return .gray
        }
    }

    private var urlFieldBorderWidth: CGFloat {
        switch connectionStatus {
        case .unknown:
            return 0.5
        default:
            return 1.5
        }
    }

    private var modelFieldBorderColor: Color {
        switch connectionStatus {
        case .missingModel:
            return .orange
        case .connected:
            return .green
        default:
            return .gray
        }
    }

    private var modelFieldBorderWidth: CGFloat {
        switch connectionStatus {
        case .unknown:
            return 0.5
        case .connected, .missingModel:
            return 1.5
        default:
            return 0.5
        }
    }

    private func isValidURL(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            return false
        }
        return true
    }

    private func loadExistingConfiguration() {
        endpointURL = aiService.customOpenAIEndpointURL
        modelName = aiService.customOpenAIModelName
        if let existingKey = AIProvider.customOpenAI.apiKey {
            apiKey = existingKey
        }

        // Show connected status if already verified (verification happens on app launch)
        if isConfigured && aiService.customOpenAIIsVerified {
            connectionStatus = .connected
        }
    }

    private func testAndSave() {
        isChecking = true
        Task {
            await testConnection(saveOnSuccess: true)
        }
    }

    private func testConnection(saveOnSuccess: Bool) async {
        let urlToTest = trimmedEndpointURL
        let modelToTest = trimmedModelName
        let apiKeyToSave = apiKey.trimmingCharacters(in: .whitespaces)

        logger.debug("CustomOpenAI Config - Testing connection to: '\(urlToTest)' with model: '\(modelToTest)'")

        guard isValidURL(urlToTest) else {
            logger.debug("CustomOpenAI Config - Invalid URL")
            connectionStatus = .invalidURL
            isChecking = false
            return
        }

        guard !modelToTest.isEmpty else {
            logger.debug("CustomOpenAI Config - Missing model name")
            connectionStatus = .missingModel
            isChecking = false
            return
        }

        connectionStatus = .checking

        HapticManager.lightImpact()

        // Save configuration to test
        aiService.customOpenAIEndpointURL = urlToTest
        aiService.customOpenAIModelName = modelToTest

        if !apiKeyToSave.isEmpty {
            _ = await aiService.saveAPIKey(apiKeyToSave, for: .customOpenAI)
        } else {
            aiService.deleteAPIKey(for: .customOpenAI)
        }

        let result = await aiService.verifyCustomOpenAISetup()
        logger.debug("CustomOpenAI Config - Result: success=\(result.success)")

        if result.success {
            connectionStatus = .connected
            // Mark as verified so other screens know it's ready
            aiService.customOpenAIIsVerified = true
            aiService.refreshConnectedProviders()
            HapticManager.success()
        } else {
            connectionStatus = .failed(message: result.message)
            // Mark as NOT verified - this invalidates the configuration
            aiService.customOpenAIIsVerified = false
            // Disable AI processing for all modes using Custom OpenAI
            aiService.disableCustomOpenAIEnhancementForAllModes()
            aiService.refreshConnectedProviders()
            HapticManager.error()
        }
        isChecking = false
    }

    private func clearConfiguration() {
        HapticManager.heavyImpact()
        aiService.clearCustomOpenAIConfiguration()
        aiService.disableCustomOpenAIEnhancementForAllModes()
        aiService.refreshConnectedProviders()

        endpointURL = ""
        modelName = ""
        apiKey = ""
        connectionStatus = .unknown
    }
}

#Preview {
    NavigationStack {
        CustomOpenAIConfigurationView(aiService: AIService())
    }
}
