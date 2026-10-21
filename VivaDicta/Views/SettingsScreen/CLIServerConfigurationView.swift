//
//  CLIServerConfigurationView.swift
//  VivaDicta
//
//  Created by Anton Novoselov on 2026.03.27
//

import SwiftUI

struct CLIServerConfigurationView: View {
    @Environment(\.dismiss) private var dismiss
    let aiService: AIService

    // Server state — loaded in onAppear to always reflect current UserDefaults
    @State private var isServerEnabled = false
    @State private var serverURL = ""
    @State private var serverToken = ""
    @State private var isTestingConnection = false
    @State private var connectionTestResult: Bool?
    @State private var showCLIWarning = false
    @State private var hasUnsavedChanges = false

    // Health response for per-CLI availability
    @State private var healthResponse: VivAgentsClient.HealthResponse?

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 8) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 48))
                        .foregroundStyle(.blue.gradient)

                    Text("VivAgents 服务器")
                        .font(.title2)

                    if isServerEnabled && VivAgentsClient.isVerified {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("已连接")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 8)

                // Connection form
                connectionSection

                // CLI availability
                if isServerEnabled && VivAgentsClient.isVerified {
                    availabilitySection
                }

                // Info
                infoSection
            }
            .padding()
        }
        .contentShape(.rect)
        .onTapGesture {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        .navigationTitle("VivAgents 服务器")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if #available(iOS 26, *) {
                    Button(role: .confirm) {
                        saveSettings()
                    }
                    .disabled(!hasUnsavedChanges)
                    .tint(hasUnsavedChanges ? .blue : .gray)
                } else {
                    Button("保存") {
                        saveSettings()
                    }
                    .disabled(!hasUnsavedChanges)
                    .foregroundStyle(hasUnsavedChanges ? .blue : .gray)
                }
            }
        }
        .onAppear {
            isServerEnabled = UserDefaults.standard.bool(forKey: VivAgentsClient.isEnabledKey)
            serverURL = UserDefaults.standard.string(forKey: VivAgentsClient.serverURLKey) ?? ""
            serverToken = VivAgentsClient.authToken ?? ""
            hasUnsavedChanges = false
        }
        .task {
            // Re-fetch health on appear if server is connected
            if isServerEnabled && VivAgentsClient.isVerified && healthResponse == nil {
                healthResponse = await VivAgentsClient.fetchHealth()
                if let health = healthResponse {
                    VivAgentsClient.saveAvailability(from: health)
                    aiService.refreshConnectedProviders()
                }
            }
        }
        .alert("使用须知", isPresented: $showCLIWarning) {
            Button("取消", role: .cancel) { }
            Button("启用") {
                isServerEnabled = true
                hasUnsavedChanges = true
            }
        } message: {
            Text("CLI 代理是为软件开发设计的。用于一般文本处理可能超出其预期用途，并可能导致账号受限。\n\n启用此功能风险自担。")
        }
    }

    // MARK: - Connection Section

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("连接")
                .font(.headline)

            Text("连接到运行 CLI 代理的服务器做 AI 处理。可以是你装了畅言的 Mac，也可以是远程服务器。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("启用 VivAgents 服务器", isOn: Binding(
                get: { isServerEnabled },
                set: { newValue in
                    if newValue {
                        showCLIWarning = true
                    } else {
                        isServerEnabled = false
                        hasUnsavedChanges = true
                    }
                }
            ))

            if isServerEnabled {
                TextField("服务器 URL（如 http://192.168.1.5:3456）", text: $serverURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .padding()
                    .background {
                        Capsule()
                            .stroke(.gray, lineWidth: 0.5)
                    }
                    .onChange(of: serverURL) { _, _ in
                        connectionTestResult = nil
                    }

                SecureField("授权令牌", text: $serverToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding()
                    .background {
                        Capsule()
                            .stroke(.gray, lineWidth: 0.5)
                    }
                    .onChange(of: serverToken) { _, _ in
                        connectionTestResult = nil
                    }

                HStack {
                    if #available(iOS 26.0, *) {
                        Button {
                            saveAndTestConnection()
                        } label: {
                            HStack(spacing: 6) {
                                if isTestingConnection {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                Text("测试并保存")
                                    .font(.headline.weight(.medium))
                            }
                        }
                        .disabled(serverURL.isEmpty || isTestingConnection)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 16)
                        .glassEffect(.regular.tint(.blue.opacity(0.3)).interactive())
                        .buttonStyle(.plain)
                    } else {
                        Button {
                            saveAndTestConnection()
                        } label: {
                            HStack(spacing: 6) {
                                if isTestingConnection {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                Text("测试并保存")
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
                        .disabled(serverURL.isEmpty || isTestingConnection)
                        .buttonStyle(.plain)
                    }

                    if let result = connectionTestResult {
                        HStack(spacing: 4) {
                            Image(systemName: result ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(result ? .green : .red)
                            Text(result ? "Connected" : "Failed")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
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

    // MARK: - CLI Availability Section

    private var availabilitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("可用的代理")
                .font(.headline)

            Text("在服务器上检测到了 CLI 代理。每个都可以在服务器配置里单独启用。")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                cliRow(name: "Claude Code CLI", provider: "Anthropic", available: healthResponse?.claudeAvailable ?? false)
                cliRow(name: "Codex CLI", provider: "OpenAI", available: healthResponse?.codexAvailable ?? false)
                cliRow(name: "Gemini CLI", provider: "Google", available: healthResponse?.geminiAvailable ?? false)
            }

            if let version = healthResponse?.version {
                Text("服务器 v\(version)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(.background.secondary)
        }
    }

    private func cliRow(name: String, provider: String, available: Bool) -> some View {
        HStack {
            Image(systemName: available ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(available ? .green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.callout)
                Text(provider)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(available ? "Available" : "Not found")
                .font(.caption)
                .foregroundStyle(available ? .green : .secondary)
        }
    }

    // MARK: - Info Section

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("工作原理", systemImage: "info.circle")
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)

            Text("VivAgents 服务器托管 CLI 代理并通过网络提供服务。你的 iPhone 或 iPad 连上它，把 AI 请求经代理转发——用你现有的账号，不需要 API Key。")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Link(destination: URL(string: "https://vivadicta.com/ios/docs/vivagents")!) {
                Label("设置指南", systemImage: "book")
                    .font(.caption)
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

    private func saveSettings() {
        if isServerEnabled && !serverURL.isEmpty {
            // When enabled with URL, test connection first (same as Test & Save)
            saveAndTestConnection()
            return
        }

        UserDefaults.standard.set(isServerEnabled, forKey: VivAgentsClient.isEnabledKey)

        if !isServerEnabled {
            UserDefaults.standard.set(false, forKey: VivAgentsClient.isVerifiedKey)
            connectionTestResult = nil
            healthResponse = nil
            VivAgentsClient.clearAvailability()
        }

        aiService.refreshConnectedProviders()
        hasUnsavedChanges = false
        HapticManager.success()
    }

    private func saveAndTestConnection() {
        UserDefaults.standard.set(isServerEnabled, forKey: VivAgentsClient.isEnabledKey)
        UserDefaults.standard.set(serverURL, forKey: VivAgentsClient.serverURLKey)
        VivAgentsClient.setAuthToken(serverToken)
        hasUnsavedChanges = false

        Task {
            isTestingConnection = true
            let success = await VivAgentsClient.testConnection(provider: "any")
            connectionTestResult = success
            UserDefaults.standard.set(success, forKey: VivAgentsClient.isVerifiedKey)
            isTestingConnection = false
            aiService.refreshConnectedProviders()

            // Fetch health details for CLI availability
            if success {
                let health = await VivAgentsClient.fetchHealth()
                healthResponse = health
                if let health {
                    VivAgentsClient.saveAvailability(from: health)
                }
                HapticManager.success()
            } else {
                healthResponse = nil
                VivAgentsClient.clearAvailability()
                HapticManager.error()
            }
        }
    }
}
