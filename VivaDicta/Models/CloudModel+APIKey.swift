//
//  CloudModel+APIKey.swift
//  VivaDicta
//
//  Created by Anton Novoselov on 2026.05.15
//

import Foundation
import AICore
import OAuth
import Keychain
import AppGroup

// This extension lives in a main-target-only file because it transitively
// depends on `AIProvider.apiKey`, which uses the Keychain package that
// extensions do not link against. CloudModel itself is shared with
// extensions; this convenience property is not.
extension CloudModel {
    var apiKey: String? {
        if provider == .selfHosted {
            return SelfHostedTranscriptionConfig.apiKey
        }
        return provider.mappedAIProvider?.apiKey
    }

    /// True when the model has a credential to transcribe with: its provider's
    /// API key, or a signed-in Grok subscription for the providers that take
    /// one (xAI). Views read this rather than `apiKey != nil` so a
    /// subscription-only setup doesn't look unconfigured.
    @MainActor
    var isConfigured: Bool {
        apiKey != nil || hasGrokSubscription
    }

    /// A signed-in SuperGrok / X Premium subscription this model can use in
    /// place of an API key.
    @MainActor
    var hasGrokSubscription: Bool {
        provider.acceptsGrokSubscription && DefaultOAuthManager.shared.isSignedIn(provider: GrokOAuthProvider())
    }
}

/// 自建转写服务器的配置：地址存 UserDefaults，API key 存钥匙串。
/// 与各云厂商的 mappedAIProvider 路径平行，不动 AIProvider 枚举。
enum SelfHostedTranscriptionConfig {
    static let defaultServerURL = URL(string: "https://asr.ysloving.com")!

    private static let keychain: any KeychainService = DefaultKeychainService()
    private static let apiKeyKey = "selfHostedTranscriptionAPIKey"

    static var apiKey: String? {
        let key = keychain.getString(forKey: apiKeyKey)
        return key?.isEmpty == true ? nil : key
    }

    static func saveAPIKey(_ key: String) {
        keychain.save(key, forKey: apiKeyKey)
    }

    static func deleteAPIKey() {
        keychain.delete(forKey: apiKeyKey)
    }

    /// Stored server address, or the default when nothing (or nothing valid)
    /// was saved. Trailing slashes are stripped so endpoint paths join cleanly.
    static var serverURL: URL {
        let raw = UserDefaultsStorage.appPrivate.string(forKey: UserDefaultsStorage.Keys.selfHostedServerURL) ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultServerURL }
        let noTrailingSlash = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        return URL(string: noTrailingSlash) ?? defaultServerURL
    }

    static func saveServerURL(_ urlString: String) {
        UserDefaultsStorage.appPrivate.set(urlString, forKey: UserDefaultsStorage.Keys.selfHostedServerURL)
    }

    /// Reachability check only (the health endpoint is public): it proves the
    /// server answers, not that the key is valid. Key validity only shows up
    /// on the first real transcription.
    static func checkHealth() async -> Bool {
        var request = URLRequest(url: serverURL.appending(path: "health"))
        request.timeoutInterval = 15
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}
