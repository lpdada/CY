import Foundation

/// 把主 App 当前在用的 AI 凭据同步一份到 App Group，供键盘扩展读取。
///
/// 键盘扩展有自己的沙盒：它读不到主 App 的 Keychain，也拿不到主 App 的内存配置。
/// 所以键盘里的翻译以前只能走“发通知等主 App 回结果”，主 App 没在后台活着就
/// 永远等不到。改成快照后，键盘直接拿这套凭据调模型，不再依赖主 App 活着。
///
/// 调用点（见 `AIService.refreshSharedAISnapshot`）：
/// - `saveAPIKey(_:for:)` 校验通过后
/// - `deleteAPIKey(for:)` 里
/// - `AppState.handleModeChange` 切模式时
/// - `AIService` 初始化时（已存 Key 不用重存一次，快照启动即补齐）
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
