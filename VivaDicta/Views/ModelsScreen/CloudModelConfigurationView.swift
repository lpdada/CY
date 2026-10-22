//
//  CloudModelConfigurationView.swift
//  VivaDicta
//
//  Created by Anton Novoselov on 2025.09.03
//

import SwiftUI
import AICore
import AppGroup

struct CloudModelConfigurationView: View {
    @Environment(\.dismiss) var dismiss
    var model: CloudModel
    let aiService: AIService
    var onSave: (CloudModel) -> Void

    @State var apiKey: String = ""
    @State private var serverURL: String = ""
    @State private var isVerifying: Bool = false
    @State private var verificationError: String? = nil
    @State private var showDeleteConfirmation: Bool = false
    @State private var clearButtonVisible = false

    var body: some View {
        
        VStack(spacing: 10) {
            if let iconName = model.provider.mappedAIProvider?.iconName {
                Image(iconName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)
            }

            Text("\(model.provider.displayName) API Key")
                .font(.title2)
            if model.provider == .selfHosted {
                TextField("服务器地址", text: $serverURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding()
                    .background {
                        Capsule()
                            .stroke(.gray, lineWidth: 0.5)
                    }
                Text("默认 https://asr.ysloving.com，换服务器时改这里")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            

            if let apiKeyURL = model.provider.mappedAIProvider?.apiKeyURL {
                Button {
                    UIApplication.shared.open(apiKeyURL)
                } label: {
                    Label("获取 API Key", systemImage: "key")
                        .font(.headline.weight(.medium))
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
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
            if model.apiKey != nil {
                if #available(iOS 26.0, *) {
                    Button(action: {
                        showDeleteConfirmation = true
                        HapticManager.warning()
                    }) {
                        Text("删除 API Key")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.red)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                    .glassEffect(.regular.tint(.red.opacity(0.2)).interactive())
                    .padding(.top, 8)
                } else {
                    Button(action: {
                        showDeleteConfirmation = true
                        HapticManager.warning()
                    }) {
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
            apiKey = model.apiKey ?? ""
            if model.provider == .selfHosted {
                let stored = UserDefaultsStorage.appPrivate.string(forKey: UserDefaultsStorage.Keys.selfHostedServerURL) ?? ""
                serverURL = stored.isEmpty ? "https://asr.ysloving.com" : stored
            }
            clearButtonVisible = !apiKey.isEmpty
        }
        .padding()
        .alert("删除 API Key", isPresented: $showDeleteConfirmation) {
            Button("取消", role: .cancel) { }
            Button("删除", role: .destructive) {
                deleteAPIKey()
            }
        } message: {
            Text("确定要删除 \(model.provider.displayName) 的 API Key 吗？此操作无法撤销。")
        }
        .navigationTitle(model.provider == .selfHosted ? "自建服务器" : "API Key")
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
                        .disabled(isSaveDisabled)
                        .tint(.blue)
                    } else {
                        Button("保存") {
                            saveKey()
                        }
                        .disabled(isSaveDisabled)
                    }
                }
            }
        }
    }
    
    
    private var isSaveDisabled: Bool {
        if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if model.provider == .selfHosted,
           serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return false
    }

    func saveKey() {
        if model.provider == .selfHosted {
            saveSelfHostedKey()
            return
        }
        Task {
            guard let aiProvider = model.provider.mappedAIProvider else {
                verificationError = "API verification not supported for this provider"
                return
            }
            
            isVerifying = true
            verificationError = nil

            HapticManager.mediumImpact()
            
            let isValid = await aiService.saveAPIKey(apiKey, for: aiProvider)
            
            isVerifying = false

            if isValid {
                onSave(model)
            } else {
                verificationError = "API Key 无效。请检查你的 Key 后重试。"
            }
        }
    }

    /// 自建服务器：地址 + key 直接保存，不走云厂商的 key 校验接口。
    /// 保存后跑一次公开健康检查，只验证服务器可达；key 是否有效在首次
    /// 转写时见分晓。健康检查失败时不关闭页面，让用户修正地址重试，
    /// 配置本身已经存下了。
    func saveSelfHostedKey() {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        SelfHostedTranscriptionConfig.saveServerURL(trimmedURL)
        SelfHostedTranscriptionConfig.saveAPIKey(trimmedKey)
        HapticManager.mediumImpact()

        Task {
            isVerifying = true
            verificationError = nil
            let reachable = await SelfHostedTranscriptionConfig.checkHealth()
            isVerifying = false
            if reachable {
                onSave(model)
            } else {
                verificationError = "已保存，但服务器连接失败，请检查地址。"
            }
        }
    }

    func deleteAPIKey() {
        if model.provider == .selfHosted {
            SelfHostedTranscriptionConfig.deleteAPIKey()
            apiKey = ""
            onSave(model)
            return
        }
        HapticManager.heavyImpact()
        // Remove the API key from Keychain
        if let aiProvider = model.provider.mappedAIProvider {
            aiService.deleteAPIKey(for: aiProvider)
        }

        // Clear the text field
        apiKey = ""

        // Refresh AI service if applicable
        if model.provider.mappedAIProvider != nil {
            aiService.refreshConnectedProviders()
        }

        // Notify parent view to refresh
        onSave(model)
    }
}

#Preview {
    CloudModelConfigurationView(
        model: TranscriptionModelProvider.allCloudModels[0],
        aiService: AIService(),
        onSave: { _ in }
    )
}
