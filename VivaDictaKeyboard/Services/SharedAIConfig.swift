import Foundation

/// 键盘侧读取主 App 的 AI 凭据。
///
/// 主 App 把 key 存 Keychain，而键盘扩展读不到主 App 的 Keychain，
/// 所以键盘直接读主 App 同步到 App Group 的快照（见 `AppGroupAISnapshot`）。
/// 快照没有、或不完整，就返回 nil，调用方据此把按钮置灰并给一句人话提示。
/// 注意：键盘扩展读 App Group 共享区、联网都需要“允许完全访问”；
/// 没开完全访问时这里同样读不到快照，按钮一样是灰的。
enum SharedAIConfig {
    nonisolated static let appGroupId = "group.com.antonnovoselov.VivaDicta"

    /// 主 App 当前在用的那一套。
    struct Snapshot: Equatable {
        let provider: String
        let model: String
        let baseURL: String
        let apiKey: String

        nonisolated var isUsable: Bool {
            !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && URL(string: baseURL) != nil
                && !model.isEmpty
        }
    }

    /// 快照，按优先级读：
    /// 1. App Group suite（正版）
    /// 2. 键盘本地 defaults（桥模式缓存：主 App 经 /vd/config 同步过来的快照，
    ///    见 AppGroupCoordinator；自签无 App Group 时只有这一路能通）
    /// 两处都没有就是 nil。
    /// 必须是 nonisolated：工程开了 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，
    /// 不标的话它默认就是 MainActor 隔离，SentenceTranslator.loadConfig（actor
    /// 的静态方法，天然 nonisolated）调它会直接报隔离错；读 UserDefaults 本来
    /// 就是线程安全的，不需要隔离。
    nonisolated static func snapshot() -> Snapshot? {
        if let snapshot = read(from: UserDefaults(suiteName: appGroupId)) {
            return snapshot
        }
        return read(from: .standard)
    }

    private nonisolated static func read(from defaults: UserDefaults?) -> Snapshot? {
        guard let defaults else { return nil }
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

    /// 一句人能看懂的提示，按钮不可用时用。
    static var unavailableHint: String {
        "键盘还没拿到主 App 的模型配置：请先打开畅言 App 一次（确认选中模式已保存 Key），并给键盘开完全访问（设置 → 通用 → 键盘 → 允许完全访问）。"
    }
}
