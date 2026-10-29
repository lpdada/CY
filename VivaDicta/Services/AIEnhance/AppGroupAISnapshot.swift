import Foundation

/// 把主 App 当前在用的 AI 凭据同步一份到 App Group，供键盘扩展读取。
///
/// 键盘扩展有自己的沙盒：它读不到主 App 的 Keychain（除非给扩展也配
/// keychain-access-groups），也拿不到主 App 的内存配置。所以「键盘里的翻译」
/// 一直灰着——不是模型没配，是它根本不知道 key 在哪儿。
///
/// 调用点就两处，改 `AIService`：
/// - `saveAPIKey(_:for:)` 校验通过后调 `AppGroupAISnapshot.save(...)`
/// - `deleteAPIKey(for:)` 里调 `AppGroupAISnapshot.clear()`
enum AppGroupAISnapshot {
    private static let suiteName = "group.com.antonnovoselov.VivaDicta"

    private enum Key {
        static let provider = "vdAISnapshotProvider"
        static let model = "vdAISnapshotModel"
        static let baseURL = "vdAISnapshotBaseURL"
        static let apiKey = "vdAISnapshotAPIKey"
    }

    /// `provider` 用 `AIProvider.rawValue`；`baseURL` 是这个 provider 的接口根地址
    /// （DeepSeek 是 `https://api.deepseek.com`，OpenAI 是 `https://api.openai.com`）。
    static func save(provider: String, model: String, baseURL: String, apiKey: String) {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        defaults.set(provider, forKey: Key.provider)
        defaults.set(model, forKey: Key.model)
        defaults.set(baseURL, forKey: Key.baseURL)
        defaults.set(apiKey, forKey: Key.apiKey)
        defaults.synchronize()
    }

    static func clear() {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        for key in [Key.provider, Key.model, Key.baseURL, Key.apiKey] {
            defaults.removeObject(forKey: key)
        }
        defaults.synchronize()
    }
}
