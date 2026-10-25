import Foundation

/// 会议文本润色：整场分批、按编号回填。
///
/// 两个调用点共用这一份，避免两套解析漂移：流式会议页（对内存里的
/// Segment 润色）和历史详情页（对已保存的 MeetingRecord 润色）。
///
/// 为什么要分批：模型必须把每一行原样回显，输出超过约 2000 字后开始
/// 漏行/并段；漏掉的段只能保留原文，且是静默失败。25 段 / 2000 字
/// 一批，30 分钟会议约 4–6 次请求。
@MainActor
enum MeetingTextPolisher {
    static let batchSize = 25
    static let batchCharacters = 2000

    struct Outcome {
        /// 0-based 下标 -> 润色后的文本；缺的段表示模型没回显，调用方保留原文。
        var polished: [Int: String] = [:]
        var failed = 0
        var requests = 0
    }

    /// 固定润色提示词：不套用当前「模式」的预设，因为预设可能是总结/翻译，
    /// 会压缩行数、破坏逐段映射。provider/model 仍取当前模式。
    static let systemPrompt = """
    你是会议记录润色助手。用户给你若干行带编号的语音转写文本，可能中、日、英混排。

    逐行只做三件事：补全标点并合理断句；去掉口头语、语气词和重复；修正明显的同音字错别字。

    绝对不要：合并或拆分任何一行；删减信息；总结或概括；翻译（中文行输出中文，日语行输出日语，英语行输出英语）。

    输出格式：行数与输入完全相同，每行以 [编号] 开头，空一格后接润色后的文本；每段必须保持一行，不要折行。
    只输出这些行，不要解释、标题、代码块或多余空行。
    """

    static func polish(
        _ texts: [String],
        aiService: AIService,
        onProgress: ((_ done: Int, _ total: Int) -> Void)? = nil
    ) async -> Outcome {
        var outcome = Outcome()
        let targets = texts.indices.filter { !texts[$0].isEmpty }
        guard !targets.isEmpty else { return outcome }
        onProgress?(0, targets.count)

        for batch in makeBatches(targets, texts: texts) {
            if Task.isCancelled { break }
            let numbered = batch.enumerated().map { offset, index in
                "[\(offset + 1)] \(texts[index])"
            }.joined(separator: "\n")
            do {
                let reply = try await aiService.enhanceBatch(
                    numbered, systemMessage: systemPrompt)
                var parsed = parseNumbered(reply, count: batch.count)
                if batch.count == 1, parsed[1] == nil {
                    // 只有一段时模型常直接答正文、不带编号。
                    parsed[1] = reply
                }
                for (offset, index) in batch.enumerated() {
                    if let polished = clean(parsed[offset + 1]), !polished.isEmpty {
                        outcome.polished[index] = polished
                    } else {
                        // 模型漏了/改坏了这一行：保留原文，不猜。
                        outcome.failed += 1
                    }
                }
            } catch is CancellationError {
                break
            } catch {
                outcome.failed += batch.count
            }
            outcome.requests += 1
            onProgress?(min(targets.count, outcome.polished.count + outcome.failed), targets.count)
        }
        return outcome
    }

    // MARK: - 分批与解析（纯逻辑，可单测）

    static func makeBatches(_ indices: [Int], texts: [String]) -> [[Int]] {
        var batches: [[Int]] = []
        var current: [Int] = []
        var characters = 0
        for index in indices {
            let length = texts[index].count
            if !current.isEmpty,
               current.count >= batchSize || characters + length > batchCharacters {
                batches.append(current)
                current = []
                characters = 0
            }
            current.append(index)
            characters += length
        }
        if !current.isEmpty {
            batches.append(current)
        }
        return batches
    }

    /// 只认带编号的行：无编号的行一律忽略。模型折行时会丢掉下一段的编号，
    /// 把它拼到上一段会串段，宁可那一段保留原文。
    static func parseNumbered(_ reply: String, count: Int) -> [Int: String] {
        var result: [Int: String] = [:]
        for rawLine in reply.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let (number, text) = numberedLine(line), number >= 1, number <= count {
                result[number] = text
            }
        }
        return result
    }

    static func numberedLine(_ line: String) -> (Int, String)? {
        var text = line
        for prefix in ["- ", "* ", "• ", "**"] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        guard text.hasPrefix("["), let close = text.firstIndex(of: "]") else { return nil }
        let digits = text[text.index(after: text.startIndex)..<close]
        guard let number = Int(digits.trimmingCharacters(in: .whitespaces)) else { return nil }
        var rest = String(text[text.index(after: close)...])
            .trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("：") || rest.hasPrefix(":") {
            rest.removeFirst()
        }
        rest = rest.replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespaces)
        return (number, rest)
    }

    /// 去掉模型爱加的包裹符号（引号、反引号、行首的「润色：」）。
    static func clean(_ text: String?) -> String? {
        guard var value = text?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        for marker in ["润色：", "润色:", "Polish:", "润色后的文本："] where value.hasPrefix(marker) {
            value.removeFirst(marker.count)
            value = value.trimmingCharacters(in: .whitespaces)
        }
        while let first = value.first, ["\"", "“", "「", "`", "*"].contains(String(first)) {
            value.removeFirst()
        }
        while let last = value.last, ["\"", "”", "」", "`", "*"].contains(String(last)) {
            value.removeLast()
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
