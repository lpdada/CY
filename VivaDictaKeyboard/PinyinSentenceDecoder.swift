//
//  PinyinSentenceDecoder.swift
//  VivaDictaKeyboard
//
//  T9 整句解码：把九宫格数字串解码成覆盖**全部数字**的 N-best 整句候选。
//
//  与 PinyinEngine.wordCandidates 的区别：
//  - wordCandidates 只把整串数字当**一个词**去查（词库最长 4 字），所以整句
//    输入必然落空，候选区只剩首音节单字。
//  - 这里把数字串当成音节格（lattice）：每个位置可以起 1–6 位的音节编码，
//    每个音节映射到若干汉字；词典 trie 允许把连续音节拼成词。搜索用 beam
//    search，代价 = 一元语言模型（词/字频）+ 二元语言模型（词接词）+ 每 token
//    的插入惩罚，最后返回整句 N-best。
//
//  约束：候选只由**用户按下的数字**构成，绝不自动补音节。所以“你在干什么”
//  的 64924426743663 不会因为补一个 “ma” 而变成“你在干什么吗”。
//

import Foundation

/// 一个整句候选。`text` 覆盖全部输入数字；`score` 越小越可信。
/// `syllables` 是这句的音节切分（与 `text` 同一次解码得到），供输入框
/// 组字串显示拼音用——例如“你在干什么”对应 ["ni", "zai", "gan", "shen", "me"]。
/// 注意：trie 是按拼音字母走的，同一个词可能被 “ha”+“o” 这样的错误切分
/// 走到（字母拼起来一样），所以不能直接记 walk 的步数；这里记的是每个
/// token 的拼音字母串，末尾再用最长匹配切回音节（见 `segmentPinyin`）。
struct PinyinSentenceCandidate: Identifiable, Equatable {
    let text: String
    let score: Double
    let syllables: [String]

    var id: String { text }
}

enum PinyinSentenceDecoder {

    // MARK: - 调参

    /// 每多一个 token（字或词）加一次惩罚。没有它，越长的切分总代价越低，
    /// 单字序列会永远压过整词/整句。
    static let insertionPenalty: Double = 4.0
    /// 每个位置保留的状态数
    static let beamWidth = 64
    /// 一次解码返回的整句数
    static let maxCandidates = 12
    /// 二元模型权重，其余给一元回退
    private static let bigramWeight = 0.7
    /// 每个音节最多取几个同音字（降分支因子，16 → 8 质量不变但快 30%）
    private static let charBranch = 8
    /// 每个 trie 节点最多取几个同音词
    private static let wordBranch = 12
    /// 单层状态硬上限，防止极端输入把扩展内存打爆
    private static let layerLimit = 12_000

    // MARK: - 词典 trie

    private final class TrieNode {
        var children: [Character: TrieNode] = [:]
        /// 走到这里能组出的词（按词频 rank 升序）
        var words: [(word: String, rank: Int)] = []
    }

    private static let trie: TrieNode = {
        let root = TrieNode()
        for line in PinyinData.wordTableRaw.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count >= 2 else { continue }
            var node = root
            for ch in parts[0] {
                if let next = node.children[ch] {
                    node = next
                } else {
                    let next = TrieNode()
                    node.children[ch] = next
                    node = next
                }
            }
            var words: [(word: String, rank: Int)] = []
            for token in parts.dropFirst() {
                let kv = token.split(separator: ":")
                guard kv.count == 2, let rank = Int(kv[1]) else { continue }
                words.append((word: String(kv[0]), rank: rank))
            }
            words.sort { $0.1 < $1.1 }
            node.words = Array(words.prefix(wordBranch))
        }
        return root
    }()

    // MARK: - 语言模型表

    private struct LanguageModel {
        var ids: [String: Int32] = [:]
        var freqs: [Double] = []
        var contextTotals: [Int32: Double] = [:]
        var bigrams: [Int64: Double] = [:]
    }

    private static let lm: LanguageModel = {
        var model = LanguageModel()
        var index: Int32 = 0
        for line in PinyinLanguageModel.wordFreqRaw.split(separator: "\n") {
            let parts = line.split(separator: "\t")
            guard parts.count == 2, let freq = Double(parts[1]) else { continue }
            model.ids[String(parts[0])] = index
            model.freqs.append(freq)
            index += 1
        }
        for line in PinyinLanguageModel.bigramRaw.split(separator: "\n") {
            let parts = line.split(separator: "\t")
            guard parts.count == 3,
                  let first = Int32(parts[0]),
                  let second = Int32(parts[1]),
                  let count = Double(parts[2]) else { continue }
            model.bigrams[(Int64(first) << 32) | Int64(second)] = count
            model.contextTotals[first, default: 0] += count
        }
        return model
    }()

    /// 单字频率兜底（词表里只有 2–4 字词，单字只在这里）
    private static let charFreqs: [Character: Double] = {
        var table: [Character: Double] = [:]
        for token in PinyinLanguageModel.charFreqRaw.split(separator: " ") {
            let kv = token.split(separator: ":")
            guard kv.count == 2, let freq = Double(kv[1]), let ch = kv[0].first else { continue }
            table[ch] = freq
        }
        return table
    }()

    // MARK: - 打分

    private static func unigramCost(_ token: String) -> Double {
        if let id = lm.ids[token] {
            let freq = max(lm.freqs[Int(id)], 1)
            return -log(freq / PinyinLanguageModel.totalTokens)
        }
        if let ch = token.first, token.count == 1, let freq = charFreqs[ch] {
            return -log(max(freq, 1) / PinyinLanguageModel.totalTokens)
        }
        return 12.0
    }

    /// 接在 `previous` 后面的 token 的代价（负对数概率 + 插入惩罚）。
    private static func cost(after previous: String?, token: String) -> Double {
        let unigram = unigramCost(token)
        guard let previous,
              let previousId = lm.ids[previous],
              let tokenId = lm.ids[token] else {
            return unigram + insertionPenalty
        }
        let pairCount = lm.bigrams[(Int64(previousId) << 32) | Int64(tokenId)] ?? 0
        let contextTotal = lm.contextTotals[previousId] ?? 0
        let conditional = contextTotal > 0 ? pairCount / contextTotal : 0
        let mixed = bigramWeight * conditional + (1 - bigramWeight) * exp(-unigram)
        return -log(max(mixed, 1e-9)) + insertionPenalty
    }

    // MARK: - 搜索

    private struct State {
        let cost: Double
        let text: String
        let last: String?
        /// 每个 token 的拼音字母串（如 "nihao"、"hao"），末尾统一切音节。
        let readings: [String]
    }

    private struct Key: Hashable {
        let text: String
        let last: String?
    }

    /// 从 `start` 开始，枚举所有“读到这里正好是一个词”的终点。
    /// 回调同时带上该词的拼音字母串（沿 trie 走过的字母拼起来，如 "nihao"）。
    /// 故意不直接记音节：trie 按字母走，"hao" 既能一步走到，也能
    /// "ha"+"o" 两步走到，记步数会得到错误的音节切分。
    private static func forEachWord(
        _ digits: [Character],
        from start: Int,
        _ body: (Int, String, String) -> Void
    ) {
        func walk(_ node: TrieNode, _ position: Int, _ letters: String) {
            for entry in node.words {
                body(position, entry.word, letters)
            }
            guard position < digits.count else { return }
            let maxLength = min(6, digits.count - position)
            for length in 1...maxLength {
                let slice = String(digits[position..<(position + length)])
                for syllable in PinyinEngine.t9Syllables(forDigits: slice) {
                    var current = node
                    var matched = true
                    for ch in syllable {
                        if let next = current.children[ch] {
                            current = next
                        } else {
                            matched = false
                            break
                        }
                    }
                    if matched {
                        walk(current, position + length, letters + syllable)
                    }
                }
            }
        }
        walk(trie, start, "")
    }

    /// 拼音字母串 → 音节：贪心最长匹配（音节表即词典的 key）。
    /// 最长匹配保证 "hao" 不会被切成 "ha"+"o"、"shijie" 不会切成
    /// "shi"+"ji"+"e"。已知极少数例外：叠词跨界恰好拼出另一音节时
    /// （如 "nana" 会切成 "nan"+"a"），只影响输入框拼音显示，不影响上屏文字。
    private static let syllableSet: Set<String> = Set(PinyinData.dictionary.keys)

    private static func segmentPinyin(_ letters: String) -> [String] {
        var rest = letters
        var result: [String] = []
        while !rest.isEmpty {
            var matched: String?
            for length in stride(from: min(6, rest.count), through: 1, by: -1) {
                let head = String(rest.prefix(length))
                if syllableSet.contains(head) {
                    matched = head
                    break
                }
            }
            if let matched {
                result.append(matched)
                rest = String(rest.dropFirst(matched.count))
            } else {
                // 不该发生（词表里的拼音都由合法音节组成），保底前进一格防死循环。
                result.append(String(rest.prefix(1)))
                rest = String(rest.dropFirst(1))
            }
        }
        return result
    }

    /// 数字串 → 整句候选（按可信度降序）。返回空数组表示无法完整覆盖。
    static func decode(_ digits: String) -> [PinyinSentenceCandidate] {
        let chars = Array(digits)
        guard !chars.isEmpty else { return [] }

        var layers = [[State]](repeating: [], count: chars.count + 1)
        layers[0] = [State(cost: 0, text: "", last: nil, readings: [])]
        var finals: [State] = []

        for position in 0...chars.count {
            guard !layers[position].isEmpty else { continue }

            // 同一 (文本, 前一个 token) 只留最便宜的一条（整条 State 留下，
            // 不能只留 cost，否则该条的音节切分就丢了）。
            var unique: [Key: State] = [:]
            unique.reserveCapacity(layers[position].count)
            for state in layers[position] {
                let key = Key(text: state.text, last: state.last)
                if let existing = unique[key], existing.cost <= state.cost { continue }
                unique[key] = state
            }

            var states = Array(unique.values)
            states.sort { $0.cost < $1.cost }
            if states.count > beamWidth {
                states.removeSubrange(beamWidth..<states.count)
            }

            if position == chars.count {
                finals = states
                break
            }

            // 这一层所有可选 token 只算一次。放进 state 循环会被重复算 beamWidth 遍，
            // 而音节反查与 trie 遍历与 state 无关——这是解码耗时的大头。
            var options: [(end: Int, token: String, reading: String)] = []
            for length in 1...min(6, chars.count - position) {
                let slice = String(chars[position..<(position + length)])
                for syllable in PinyinEngine.t9Syllables(forDigits: slice) {
                    guard let pool = PinyinData.dictionary[syllable] else { continue }
                    for ch in pool.prefix(charBranch) {
                        options.append((position + length, String(ch), syllable))
                    }
                }
            }
            forEachWord(chars, from: position) { end, word, letters in
                options.append((end, word, letters))
            }

            for state in states {
                for option in options {
                    let next = State(
                        cost: state.cost + cost(after: state.last, token: option.token),
                        text: state.text + option.token,
                        last: option.token,
                        readings: state.readings + [option.reading]
                    )
                    if layers[option.end].count < layerLimit { layers[option.end].append(next) }
                }
            }
        }

        var seen = Set<String>()
        var results: [PinyinSentenceCandidate] = []
        for state in finals {
            guard seen.insert(state.text).inserted else { continue }
            results.append(PinyinSentenceCandidate(
                text: state.text,
                score: state.cost,
                syllables: state.readings.flatMap(segmentPinyin)
            ))
            if results.count >= maxCandidates { break }
        }
        return results
    }

    /// 预热：触发 trie 与语言模型表的 lazy 初始化。
    /// 41k 词 + 22k 二元组首次构建约 100ms，放在键盘出现时做，避免第一次按键卡顿。
    static func warmUp() {
        _ = trie
        _ = lm
        _ = charFreqs
    }

    /// 只取首选文本（缓存或快速路径用）
    static func bestSentence(_ digits: String) -> String? {
        decode(digits).first?.text
    }
}
