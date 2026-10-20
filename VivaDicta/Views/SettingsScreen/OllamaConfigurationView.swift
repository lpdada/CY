//
//  OllamaConfigurationView.swift
//  VivaDicta
//
//  Created by Anton Novoselov on 2026.01.16
//

import SwiftUI
import AppGroup

struct OllamaConfigurationView: View {
    @Environment(\.dismiss) private var dismiss
    let aiService: AIService

    @State private var serverURL: String = ""
    @State private var isChecking = false
    @State private var connectionStatus: ConnectionStatus = .unknown

    enum ConnectionStatus: Equatable {
        case unknown
        case checking
        case connected(modelCount: Int)
        case failed(message: String)
        case invalidURL
    }

    var body: some View {
        VStack(spacing: 16) {
            // Icon
            Image("ollama")
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .padding(.top, 8)

            Text("Ollama")
                .font(.title2)

            Text("本地 AI 服务器")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // Server URL input
            VStack(alignment: .leading, spacing: 8) {
                Text("服务器 URL")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("格式：http://host:11434 或 https://host:11434\n（Ollama 默认端口是 11434）")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                TextField("服务器 URL", text: $serverURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding()
                    .background {
                        Capsule()
                            .stroke(connectionStatus.borderColor, lineWidth: connectionStatus.borderWidth)
                    }
            }
            .padding(.horizontal)

            // Connection status
            connectionStatusView
                .padding(.horizontal)

            // Test Connection button
            if #available(iOS 26.0, *) {
                Button {
                    isChecking = true
                    Task {
                        await checkConnection()
                    }
                } label: {
                    HStack {
                        if case .checking = connectionStatus {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(connectionStatus == .checking ? "Connecting..." : "Connect")
                            .font(.headline.weight(.medium))
                    }
                }
                .disabled(isChecking || !canConnect)
                .padding(.vertical, 8)
                .padding(.horizontal, 16)
                .glassEffect(.regular.tint(.blue.opacity(0.3)).interactive())
                .buttonStyle(.plain)
            } else {
                Button {
                    isChecking = true
                    Task {
                        await checkConnection()
                    }
                } label: {
                    HStack {
                        if case .checking = connectionStatus {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(connectionStatus == .checking ? "Connecting..." : "Connect")
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
                .disabled(isChecking || !canConnect)
                .buttonStyle(.plain)
            }

            // Models list (if connected)
            if case .connected = connectionStatus, !aiService.ollamaModels.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("可用的模型")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(aiService.ollamaModels, id: \.self) { model in
                                Text(model)
                                    .font(.system(.body, design: .monospaced))
                                    .padding(.horizontal)
                                    .padding(.vertical, 4)
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                }
            }

            Spacer()

            // Help text
            VStack(spacing: 8) {
                Text("Ollama 在你的 Mac 或服务器上本地运行 AI 模型。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                
                Link("Get Ollama →", destination: URL(string: "https://ollama.com")!)
                    .font(.caption)
            }
            .padding(.bottom)
        }
        .padding()
        .contentShape(Rectangle())
        .onTapGesture {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        .navigationTitle("Ollama")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Only load URL if user previously saved one (not the default)
            let savedURL = UserDefaultsStorage.shared.string(forKey: UserDefaultsStorage.Keys.ollamaServerURL)
            if let savedURL, !savedURL.isEmpty {
                serverURL = savedURL
            }
            // Show connected status if models were previously loaded (cached state)
            if !aiService.ollamaModels.isEmpty {
                connectionStatus = .connected(modelCount: aiService.ollamaModels.count)
            }
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
                Text("正在检查连接…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

        case .connected(let modelCount):
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("连接成功")
                Text("已连接 • \(modelCount) 个模型可用")
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
        }
    }

    private func isValidOllamaURL(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            return false
        }
        return true
    }

    private var trimmedServerURL: String {
        serverURL.trimmingCharacters(in: .whitespaces)
    }

    private var canConnect: Bool {
        !trimmedServerURL.isEmpty && isValidOllamaURL(trimmedServerURL)
    }

    private func checkConnection() async {
        let urlToTest = trimmedServerURL

        guard !urlToTest.isEmpty && isValidOllamaURL(urlToTest) else {
            connectionStatus = .invalidURL
            isChecking = false
            return
        }

        connectionStatus = .checking

        HapticManager.lightImpact()

        aiService.ollamaServerURL = urlToTest

        let result = await aiService.verifyOllamaSetup()

        if result.success {
            connectionStatus = .connected(modelCount: aiService.ollamaModels.count)
            HapticManager.success()
        } else {
            connectionStatus = .failed(message: result.message)
            // Clear models so other screens know Ollama is not ready
            aiService.ollamaModels = []
            // Disable AI processing for all modes using Ollama
            aiService.disableOllamaEnhancementForAllModes()
            HapticManager.error()
        }
        isChecking = false
    }
}

extension OllamaConfigurationView.ConnectionStatus {
    var borderColor: Color {
        switch self {
        case .unknown, .checking:
            return .gray
        case .connected:
            return .green
        case .failed:
            return .red
        case .invalidURL:
            return .orange
        }
    }

    var borderWidth: CGFloat {
        switch self {
        case .unknown:
            return 0.5
        case .checking, .connected, .failed, .invalidURL:
            return 1.5
        }
    }
}

#Preview {
    NavigationStack {
        OllamaConfigurationView(aiService: AIService())
    }
}
