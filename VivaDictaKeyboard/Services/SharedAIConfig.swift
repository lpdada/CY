import Foundation

/// 键盘侧读取主 App 的 AI 凭据。
///
/// 主 App 把 key 存 Keychain（`AIProvider.keychainKey`），而键盘扩展的
/// entitlements 里只有 app group、没有 keychain-access-groups —— 键盘压根读不到，
/// 「翻译」按钮灰掉就是这个原因，不是模型没配、也不是 key 没填。
///
/// 这里按优先级取：
/// 1. App Group 里主 App 同步过来的快照（见 `AppGroupAISnapshot`）
/// 2. Keychain（要先给键盘加 keychain-access-groups，见 entitlements 改动）
///
/// 两个都拿不到就返回 nil，调用方据此把按钮置灰并给一句人话提示。
enum SharedAIConfig {
    static let appGroupId = "group.com.antonnovoselov.VivaDicta"

    /// 主 App 当前在用的那一套。
    struct Snapshot: Equatable {
        let provider: String
        let model: String
        let baseURL: String
        let apiKey: String

        var isUsable: Bool {
            !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && URL(string: baseURL) != nil
                && !model.isEmpty
        }
    }

    /// App Group 里那份快照；没有就是 nil。
    /// 必须是 nonisolated：工程开了 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，
    /// 不标的话它默认就是 MainActor 隔离，SentenceTranslator.loadConfig（actor
    /// 的静态方法，天然 nonisolated）调它会直接报隔离错；读 UserDefaults 本来
    /// 就是线程安全的，不需要隔离。
    nonisolated static func snapshot() -> Snapshot? {
        guard let defaults = UserDefaults(suiteName: appGroupId) else { return nil }
        let key = defaults.string(forKey: "vdAISnapshotAPIKey") ?? ""
        guard !key.isEmpty else { return nil }
        let snapshot = Snapshot(
            provider: defaults.string(forKey: "vdAISnapshotProvider") ?? "customOpenAI",
            model: defaults.string(forKey: "vdAISnapshotModel") ?? "",
            baseURL: defaults.string(forKey: "vdAISnapshotBaseURL") ?? "",
            apiKey: key
        )
        return snapshot.isUsable ? snapshot : nil
    }

    /// 有没有可用的凭据。UI 用它决定按钮亮还是灰。
    static var isConfigured: Bool {
        snapshot() != nil
    }

    /// 一句人能看懂的提示，灰按钮长按/点击时用。
    static var unavailableHint: String {
        "先在畅言 App 里配置 AI 模型的 API Key，键盘里就能直接用；或在键盘设置里填一次。"
    }
}
