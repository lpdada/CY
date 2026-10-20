//
//  ChatToolsSettingsView.swift
//  VivaDicta
//
//  Created by Anton Novoselov on 2026.04.10
//

import Networking
import SwiftUI

/// Settings hub for chat tools such as automatic note search and web search.
struct ChatToolsSettingsView: View {
    @AppStorage(CrossNoteSearchToolFeature.isEnabledKey)
    private var isImplicitCrossNoteSearchEnabled = false
    @AppStorage(WebSearchToolFeature.isEnabledKey)
    private var isImplicitWebSearchEnabled = false
    @State private var isExaConfigured = ExaAPIKeyManager.isConfigured

    @AppStorage(SmartSearchFeature.isEnabledKey)
    private var isSmartSearchEnabled = true

    var body: some View {
        Form {
            Section("其他笔记") {
                Toggle(isOn: $isImplicitCrossNoteSearchEnabled) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("在其他笔记中自动搜索（实验）")
                            .font(.body)
                        Text("允许兼容的对话模型在聊天时自行决定是否搜索你的其他笔记。默认关闭。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!isSmartSearchEnabled)

                if !isSmartSearchEnabled {
                    Text("需要开启智能搜索，因为其他笔记搜索用的是共享的 RAG 索引。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("网络搜索") {
                Toggle(isOn: $isImplicitWebSearchEnabled) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("网络搜索（Exa）")
                            .font(.body)
                        Text("允许对话用 Exa 搜索网络。开启后，对话里会出现网络搜索按钮，兼容的模型也可能自动搜索。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!isExaConfigured)

                if !isExaConfigured {
                    Text("需要 Exa API Key，因为网络搜索用的是 Exa。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                NavigationLink {
                    ExaWebSearchSettingsView()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("配置 Exa API Key")
                            Text("管理对话网络搜索用的 Exa API Key。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if isExaConfigured {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        }
                    }
                }
            }
        }
        .navigationTitle("对话工具")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            isExaConfigured = ExaAPIKeyManager.isConfigured
        }
    }
}

private struct ExaWebSearchSettingsView: View {
    @State private var exaAPIKey: String = ""
    @State private var hasExistingKey = false
    @State private var showDeleteConfirmation = false
    @State private var isVerifying = false
    @State private var verificationError: String?
    @State private var clearButtonVisible = false

    var body: some View {
        VStack(spacing: 10) {
            Text("网络搜索（Exa）")
                .font(.title2)

            Text("让对话模型在聊天时搜索网络获取最新信息。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            TextField("Exa API Key", text: $exaAPIKey)
                .privacySensitive()
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding()
                .background {
                    Capsule()
                        .stroke(verificationError != nil ? .red : .gray, lineWidth: verificationError != nil ? 1.5 : 0.5)
                }
                .onChange(of: exaAPIKey) { _, _ in
                    verificationError = nil
                    clearButtonVisible = !exaAPIKey.isEmpty
                }

            if let error = verificationError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            if #available(iOS 26.0, *) {
                Button {
                    pasteFromClipboard()
                } label: {
                    Text("从剪贴板粘贴")
                        .font(.headline.weight(.medium))
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 16)
                .glassEffect(.regular.tint(.blue.opacity(0.3)).interactive())
                .buttonStyle(.plain)
            } else {
                Button {
                    pasteFromClipboard()
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
            }

            Button {
                UIApplication.shared.open(URL(string: "https://dashboard.exa.ai/api-keys")!)
            } label: {
                Label("获取 Exa API Key", systemImage: "key")
                    .font(.headline.weight(.medium))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)

            if clearButtonVisible {
                if #available(iOS 26.0, *) {
                    Button {
                        exaAPIKey = ""
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
                        exaAPIKey = ""
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
        .padding()
        .contentShape(.rect)
        .onTapGesture {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        .navigationTitle("网络搜索")
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
                        .disabled(exaAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .tint(.blue)
                    } else {
                        Button("保存") {
                            saveKey()
                        }
                        .disabled(exaAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .onAppear {
            let existing = ExaAPIKeyManager.apiKey
            exaAPIKey = existing ?? ""
            hasExistingKey = existing != nil
            clearButtonVisible = !exaAPIKey.isEmpty
        }
        .alert("删除 API Key", isPresented: $showDeleteConfirmation) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                ExaAPIKeyManager.delete()
                exaAPIKey = ""
                hasExistingKey = false
                clearButtonVisible = false
                HapticManager.heavyImpact()
            }
        } message: {
            Text("确定要删除 Exa 的 API Key 吗？")
        }
    }

    private func pasteFromClipboard() {
        if let clipboardString = UIPasteboard.general.string {
            let trimmed = clipboardString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                exaAPIKey = trimmed
                saveKey()
            }
        }
    }

    private func saveKey() {
        let trimmed = exaAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isVerifying = true
        verificationError = nil

        Task {
            HapticManager.mediumImpact()

            let isValid = await verifyExaKey(trimmed)

            isVerifying = false

            if isValid {
                ExaAPIKeyManager.save(trimmed)
                hasExistingKey = true
                HapticManager.success()
            } else {
                verificationError = "API Key 无效。请检查你的 Key 后重试。"
                HapticManager.error()
            }
        }
    }

    private func verifyExaKey(_ key: String) async -> Bool {
        guard let url = URL(string: "https://api.exa.ai/search") else { return false }

        let payload: [String: Any] = ["query": "test", "numResults": 1]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.httpBody = body

        do {
            let client: any NetworkService = DefaultNetworkService(category: "ExaKeyVerification")
            let (_, response) = try await client.send(request)
            return (200...299).contains(response.statusCode)
        } catch {
            return false
        }
    }
}
