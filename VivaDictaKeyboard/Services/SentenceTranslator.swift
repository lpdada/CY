//
//  SentenceTranslator.swift
//  VivaDictaKeyboard
//
//  九宫格“一键翻译”用的整句翻译器：把组句中的中文整句发给 OpenAI 兼容接口，
//  换回一句日文，由调用方把中文组字串清掉、日文直接打进输入框。
//
//  配置直接共用主 App 的：主 App 选中的增强模式（模式列表 + 选中名都在
//  App Group 共享区里）决定模型和端点，Key 读主 App 同步到共享区的镜像
//  （主 App 保存/删除 Key 时同步，见 AIService.saveAPIKey/deleteAPIKey），
//  翻译不再另配一套 Key。目标语言固定日语（按钮就叫“译日”）。
//  模式没选文本模型、模型名为空、端点非法、镜像里没 Key 时整体关闭
//  （调用方把按钮变灰）；只支持 OpenAI 兼容格式的模型，Anthropic 的
//  messages 格式、Apple/本地/Ollama 没有云端点，都不支持。键盘扩展里联网
//  还要求系统设置里开了“完全访问”，没开时请求会失败、调用方保留中文。
//  内存缓存 128 条、同一句不重复请求、ephemeral 会话、单次超时 8 秒、
//  不重试、不落盘；打字内容只发给配置里的模型端点。

import Foundation
import AICore
import AppGroup
import UIKit
import os

actor SentenceTranslator {
    static let shared = SentenceTranslator()

    struct Config: Sendable {
        var endpoint: URL
        var model: String
        var apiKey: String
        var timeout: TimeInterval
        /// 模型所属的服务商：opencode 网关靠请求头路由，不光认 Key，
        /// 发请求时要带上 OpenCodeHeaders，否则会被当匿名限流。
        var provider: AIProvider
    }

    private static let logger = Logger(
        subsystem: "com.antonnovoselov.VivaDicta.keyboard",
        category: "sentence-translate"
    )
    private static let cacheLimit = 128

    private var cache: [String: String] = [:]
    private var recency: [String] = []
    private var inFlight: [String: Task<String?, Never>] = [:]
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    /// 配置是否齐全（主 App 模式 + 共享 Key 镜像都就绪）。调用方据此决定按钮能不能点。
    static var isConfigured: Bool {
        loadConfig() != nil
    }

    /// 从 App Group 共享区读主 App 选中的增强模式，再读该模型的 Key 镜像。
    /// 模式列表与选中名都是主 App 写进共享区的（见 AIService）；Key 镜像由主 App
    /// 保存/删除 Key 时同步（见 AIService.saveAPIKey/deleteAPIKey），键盘不另配 Key。
    static func loadConfig() -> Config? {
        let defaults = AppGroupCoordinator.shared.clientDefaults
        guard let selectedName = defaults.string(forKey: AppGroupCoordinator.selectedVivaModeKey),
              let modesData = defaults.data(forKey: AppGroupCoordinator.vivaModesKey),
              let modes = try? JSONDecoder().decode([SharedMode].self, from: modesData),
              let mode = modes.first(where: { $0.name == selectedName }),
              let provider = mode.aiProvider else { return nil }
        // OpenAI 兼容格式才行：Anthropic 是 messages 格式，Apple/本地/Ollama
        // 没有云端点，Copilot 走 OAuth token（不在 Key 镜像里），一律不支持。
        guard provider != .anthropic, provider != .apple, provider != .local,
              provider != .ollama, provider != .copilot else { return nil }
        let model: String
        let endpointString: String
        if provider == .customOpenAI {
            // 自定义端点走主 App 的归一化规则：已含 /chat/completions 就直通，
            // 以 /v1 结尾就补 /chat/completions，否则补 /v1/chat/completions。
            let rawEndpoint = defaults.string(forKey: UserDefaultsStorage.Keys.customOpenAIEndpointURL) ?? ""
            endpointString = normalizeRequestURL(rawEndpoint)
            let sharedModel = defaults.string(forKey: UserDefaultsStorage.Keys.customOpenAIModelName) ?? ""
            model = mode.aiModel.isEmpty ? sharedModel : mode.aiModel
        } else {
            endpointString = provider.baseURL
            model = mode.aiModel
        }
        guard !model.isEmpty, !endpointString.isEmpty,
              let endpoint = URL(string: endpointString),
              let apiKey = defaults.string(forKey: UserDefaultsStorage.SharedKeys.sharedAPIKey(forProvider: provider.rawValue)),
              !apiKey.isEmpty else { return nil }
        return Config(endpoint: endpoint, model: model, apiKey: apiKey, timeout: 8, provider: provider)
    }

    /// 主 App 自定义端点的归一化规则（与 AIService.customOpenAIRequestURL 一致）。
    private static func normalizeRequestURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let noSlash = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        if noSlash.contains("/chat/completions") { return noSlash }
        if noSlash.hasSuffix("/v1") { return noSlash + "/chat/completions" }
        return noSlash + "/v1/chat/completions"
    }

    /// 共享区里模式列表的最小解码形状：只要名字、文本模型、模型名，
    /// 其余字段（转写模型、预设等）解码时忽略，不依赖主 App 的 VivaMode 类型。
    private struct SharedMode: Decodable {
        var name: String
        var aiProvider: AIProvider?
        var aiModel: String
    }

    /// 拿一句日语译文；`nil` 表示网络失败、返回内容为空，或配置不完整。
    func translate(_ text: String, config: Config) async -> String? {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard source.count >= 2 else { return nil }
        if let hit = cache[source] { return hit }
        if let running = inFlight[source] { return await running.value }

        let session = self.session
        let task = Task<String?, Never> { [config] in
            await Self.perform(source, config: config, session: session)
        }
        inFlight[source] = task
        let result = await task.value
        inFlight[source] = nil
        if let result {
            store(source, result)
        }
        return result
    }

    private func store(_ source: String, _ translation: String) {
        if cache[source] == nil {
            recency.append(source)
            if recency.count > Self.cacheLimit {
                let dropped = recency.removeFirst()
                cache[dropped] = nil
            }
        }
        cache[source] = translation
    }

    // MARK: - 请求

    // 注意：这里刻意不用 Codable 类型做请求/响应。首两版构建都倒在同一处：
    // 文件作用域的 ChatRequest/ChatResponse 的 Codable 实现被编译器判定为
    // MainActor 隔离，从 actor 方法里编解码直接报错，改 nonisolated 也没过去。
    // JSONSerialization 不走协议一致性隔离，彻底绕开这个问题。
    private static func perform(
        _ source: String,
        config: Config,
        session: URLSession
    ) async -> String? {
        var request = URLRequest(url: config.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = config.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        // opencode 网关靠这几个头路由（不光认 Key）：没带会被当匿名限流，
        // 所以这里跟主 App 的 AIProviderRegistry 一样合并 OpenCodeHeaders。
        for (field, value) in OpenCodeHeaders.headers(for: config.provider) {
            request.setValue(value, forHTTPHeaderField: field)
        }

        let payload: [String: Any] = [
            "model": config.model,
            "temperature": 0.2,
            "stream": false,
            "messages": [
                ["role": "system", "content": prompt],
                ["role": "user", "content": source],
            ],
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        request.httpBody = body

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            guard (200..<300).contains(http.statusCode) else {
                logger.log(level: .info, "整句翻译 HTTP \(http.statusCode, privacy: .public)")
                return nil
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String else { return nil }
            return cleanup(content)
        } catch {
            logger.log(level: .info, "整句翻译请求失败：\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static let prompt = """
    你是输入法里的翻译器。把用户给出的中文译成自然的日语，口语优先，长度与原文相当。
    只输出译文本身：不要解释，不要加引号，不要罗马字或假名注音。
    """

    /// 模型偶尔会带上引号或「」；去掉这些包装，其余原样。
    private static func cleanup(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let wrappers: Set<Character> = ["\"", "“", "”", "「", "」", "『", "』"]
        while let first = text.first, wrappers.contains(first) { text.removeFirst() }
        while let last = text.last, wrappers.contains(last) { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

// MARK: - 九宫格翻译共享状态
//
// 九宫格视图（组句、整句候选）和工具条左图标（翻译按钮）各管一头，
// 句子、翻译中、错误、翻译完成信号都放这里打通：
//  - 九宫格：数字串变化时把整句候选写进 `sentence`；翻译完成信号一到就清数字串；
//  - 工具条左图标：点按时调 `requestTranslate(proxy:)`，成功后组字串和数字串
//    由完成信号清掉，日文直接打进输入框（不自动发送）；失败时中文原样保留，
//    只把 `error` 置上，由九宫格候选区显示一行红字。
//  由 KeyboardCustomView 用 @State 持有一份，同时传给九宫格和工具条。
//  翻译进行中九宫格不接受新按键，避免翻译回来时组句已变、中文和日文错位。
@MainActor
@Observable
final class PinyinTranslationState {
    var sentence: String = ""
    var isTranslating: Bool = false
    var error: String?
    var completedNonce: Int = 0

    /// 按钮是否可用：有句子、配了 Key、翻译没在进行。完全访问由工具条另行判断。
    var canTranslate: Bool {
        !sentence.isEmpty && SentenceTranslator.isConfigured && !isTranslating
    }

    func requestTranslate(proxy: UITextDocumentProxy) {
        let source = sentence
        guard !source.isEmpty, !isTranslating else { return }
        guard let config = SentenceTranslator.loadConfig() else {
            error = "翻译未就绪，中文已保留"
            return
        }
        isTranslating = true
        error = nil
        Task {
            let result = await SentenceTranslator.shared.translate(source, config: config)
            isTranslating = false
            if let result, !result.isEmpty {
                proxy.unmarkText()
                proxy.insertText(result)
                completedNonce += 1
            } else {
                error = "翻译失败，中文已保留"
            }
        }
    }
}


