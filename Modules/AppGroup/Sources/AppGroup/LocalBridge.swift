//
//  LocalBridge.swift
//  AppGroup
//
//  自签（无 App Group）环境下的跨进程数据桥。
//
//  背景：App Store 版靠 App Group 的共享 UserDefaults 在主 App 与键盘扩展
//  之间搬运数据；免费签名签不到原 App Group，containerURL 为 nil，
//  共享存储不存在。本桥用畅言（Changyan iOS）验证过的三件套替代：
//  - 事件信号：仍走 Darwin 通知（系统级，不依赖 App Group），Coordinator 已有。
//  - 扩展 → 主 App 的文本载荷（文本处理输入、语音指令目标、剪贴板上下文、
//    模式选择）：写命名剪贴板（同步写完再发通知，时序与原 defaults 写法一致）。
//  - 主 App → 扩展的结果（转写文本、处理结果、错误）：同样走命名剪贴板，
//    扩展在通知 handler 里先落地到本地缓存再走原有逻辑。
//  - 状态与配置（录音状态、电平、会话、模式/预设列表、设置项）：主 App 内嵌
//    一个只绑 127.0.0.1 的 HTTP 服务，扩展按通知触发拉取并写本地缓存。
//
//  桥只在「iOS 且 App Group 容器不可用」时启用；正版环境完全走原路径。
//

import Foundation
#if os(iOS)
import UIKit
#endif
import Network
import os

/// 跨进程桥的模式判定与进程角色。
public enum LocalBridge {
    private static let logger = Logger(appGroupCategory: "LocalBridge")

    /// 主 App 的 bundle id 前缀（正式与 beta 两种配置都以此开头，扩展在其后加后缀）。
    private static let mainAppBundleId = "com.antonnovoselov.VivaDicta"

    /// 是否处于桥模式：iOS 且 App Group 容器拿不到。
    public static let isEnabled: Bool = {
        #if os(iOS)
        let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.antonnovoselov.VivaDicta"
        )
        return container == nil
        #else
        return false
        #endif
    }()

    /// 当前进程是否主 App（扩展的 bundle 里带 NSExtension 字典）。
    public static var isMainAppProcess: Bool {
        Bundle.main.infoDictionary?["NSExtension"] == nil
    }

    /// 桥模式下各进程统一使用的本地存储：主 App 里是权威数据，
    /// 扩展里是桥拉取到的缓存。两边都落在各自的 .standard 上，
    /// Coordinator / UserDefaultsStorage / 键盘侧各读取点共用这一份。
    public static var localDefaults: UserDefaults { .standard }
}

// MARK: - 命名剪贴板载荷通道

/// 载荷包的种类，与 Coordinator 里的读写点一一对应。
public enum BridgePayloadKind: String {
    case textProcessing      // 键盘 → 主 App：requestTextProcessing 的三个字段
    case voiceInstruction    // 键盘 → 主 App：语音指令的目标文本与模式
    case clipboardContext    // 键盘 → 主 App：AI 上下文剪贴板文本
    case selectedMode        // 键盘 → 主 App：当前选中的 VivaMode 名
    case transcribedText     // 主 App → 键盘：转写结果文本
    case transcriptionError  // 主 App → 键盘：转写错误信息
    case textResult          // 主 App → 键盘：文本处理结果
    case textError           // 主 App → 键盘：文本处理错误
}

/// 命名剪贴板上的 JSON 包读写。包结构：{kind, nonce, fields: {String: String}}。
/// 读取方按 kind 取走自己那一类；取走后立即清空剪贴板，同一包不会被落地两次。
public enum BridgePasteboard {
    #if os(iOS)
    private static let boardName = UIPasteboard.Name("com.vivadicta.bridge")
    private static var board: UIPasteboard? {
        UIPasteboard(name: boardName, create: true)
    }
    #endif

    /// 取走指定种类的载荷包字段；种类不符或剪贴板为空则返回 nil。
    /// 成功取走后清空剪贴板，避免下一次 ingest 读到旧包。
    public static func consume(kind: BridgePayloadKind) -> [String: String]? {
        #if os(iOS)
        guard LocalBridge.isEnabled, let board,
              let text = board.string, !text.isEmpty,
              let data = text.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              payload["kind"] as? String == kind.rawValue,
              let fields = payload["fields"] as? [String: String] else { return nil }
        board.string = ""
        return fields
        #else
        return nil
        #endif
    }
    public static func send(kind: BridgePayloadKind, fields: [String: String]) {
        #if os(iOS)
        guard LocalBridge.isEnabled, let board else { return }
        let payload: [String: Any] = [
            "kind": kind.rawValue,
            "nonce": UUID().uuidString,
            "fields": fields,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        board.string = text
        #endif
    }

}

// MARK: - 状态/配置 HTTP 服务（主 App 进程）

/// 只绑 127.0.0.1 的极简 HTTP 服务，把 Coordinator 本地存储里的
/// 状态与配置以 JSON 暴露给扩展进程拉取。无鉴权（仅回环可达）。
public final class BridgeStateServer: @unchecked Sendable {
    public static let port: NWEndpoint.Port = 47821

    private var listener: NWListener?
    // provider 闭包只读 Coordinator 的本地 UserDefaults（本身线程安全），
    // 在服务的串行回调队列上调用，故不标 @Sendable。
    private let stateProvider: () -> [String: Any]
    private let configProvider: () -> [String: Any]
    private let logger = Logger(appGroupCategory: "BridgeStateServer")

    public init(
        stateProvider: @escaping () -> [String: Any],
        configProvider: @escaping () -> [String: Any]
    ) {
        self.stateProvider = stateProvider
        self.configProvider = configProvider
    }

    public func start() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: Self.port)
        // 扩展与主 App 同机回环，不需要任何加密与代理
        params.allowLocalEndpointReuse = true
        do {
            let listener = try NWListener(using: params)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state {
                    self?.logger.logError("BridgeStateServer listener failed: \(error.localizedDescription)")
                }
            }
            listener.start(queue: .global(qos: .utility))
            self.listener = listener
            logger.logInfo("BridgeStateServer listening on 127.0.0.1:47821")
        } catch {
            logger.logError("BridgeStateServer start failed: \(error.localizedDescription)")
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .utility))
        receiveRequest(connection, buffer: Data())
    }

    private func receiveRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            let text = String(data: buffer, encoding: .utf8) ?? ""
            if text.contains("\r\n\r\n") || isComplete || error != nil {
                self.respond(connection, request: text)
            } else {
                self.receiveRequest(connection, buffer: buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection, request: String) {
        let firstLine = request.components(separatedBy: "\r\n").first ?? ""
        let path = firstLine.components(separatedBy: " ").dropFirst().first ?? ""

        let bodyObject: [String: Any]
        switch path {
        case "/vd/state":
            bodyObject = stateProvider()
        case "/vd/config":
            bodyObject = configProvider()
        case "/vd/health":
            bodyObject = ["ok": true]
        default:
            let body = Data("not found".utf8)
            let head = "HTTP/1.1 404 Not Found\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }

        let body = (try? JSONSerialization.data(withJSONObject: bodyObject)) ?? Data("{}".utf8)
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

// MARK: - 状态/配置拉取（扩展进程）

/// 扩展侧拉取主 App 的状态/配置快照并写入本地缓存。
public enum BridgeStateClient {
    private static let logger = Logger(appGroupCategory: "BridgeStateClient")

    private static func fetch(path: String) async -> [String: Any]? {
        guard let url = URL(string: "http://127.0.0.1:47821\(path)") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2.0
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            return nil
        }
    }

    /// 拉取状态快照（isRecording/status/level/session），交给调用方写入缓存。
    public static func pullState() async -> [String: Any]? {
        await fetch(path: "/vd/state")
    }

    /// 拉取配置快照（模式、预设、设置项），交给调用方写入缓存。
    public static func pullConfig() async -> [String: Any]? {
        await fetch(path: "/vd/config")
    }

    /// 把快照字典里的分型键值写入指定 defaults。
    /// 快照结构：{"strings": {...}, "bools": {...}, "doubles": {...}, "datas": {key: base64}}
    public static func applySnapshot(_ snapshot: [String: Any], to defaults: UserDefaults) {
        if let strings = snapshot["strings"] as? [String: String] {
            for (key, value) in strings { defaults.set(value, forKey: key) }
        }
        if let bools = snapshot["bools"] as? [String: Bool] {
            for (key, value) in bools { defaults.set(value, forKey: key) }
        }
        if let doubles = snapshot["doubles"] as? [String: Double] {
            for (key, value) in doubles { defaults.set(value, forKey: key) }
        }
        if let datas = snapshot["datas"] as? [String: String] {
            for (key, value) in datas {
                if let data = Data(base64Encoded: value) {
                    defaults.set(data, forKey: key)
                }
            }
        }
        if let arrays = snapshot["arrays"] as? [String: [String]] {
            for (key, value) in arrays { defaults.set(value, forKey: key) }
        }
    }

    /// 读取 defaults 中一组键，组装成快照结构（服务端提供者用）。
    public static func makeSnapshot(
        from defaults: UserDefaults,
        stringKeys: [String],
        boolKeys: [String],
        doubleKeys: [String],
        dataKeys: [String],
        arrayKeys: [String]
    ) -> [String: Any] {
        var snapshot: [String: Any] = [:]
        var strings: [String: String] = [:]
        for key in stringKeys {
            if let value = defaults.string(forKey: key) { strings[key] = value }
        }
        var bools: [String: Bool] = [:]
        for key in boolKeys {
            if defaults.object(forKey: key) != nil { bools[key] = defaults.bool(forKey: key) }
        }
        var doubles: [String: Double] = [:]
        for key in doubleKeys {
            if defaults.object(forKey: key) != nil { doubles[key] = defaults.double(forKey: key) }
        }
        var datas: [String: String] = [:]
        for key in dataKeys {
            if let value = defaults.data(forKey: key) { datas[key] = value.base64EncodedString() }
        }
        var arrays: [String: [String]] = [:]
        for key in arrayKeys {
            if let value = defaults.array(forKey: key) as? [String] { arrays[key] = value }
        }
        snapshot["strings"] = strings
        snapshot["bools"] = bools
        snapshot["doubles"] = doubles
        snapshot["datas"] = datas
        snapshot["arrays"] = arrays
        return snapshot
    }
}
