import Foundation

/// 整句解码：数字串 → 词图 → Viterbi 选一条总分最高的路径。
///
/// 现在 `PinyinEngine.wordCandidates` 只是「列出所有覆盖整串的词」，谁排前面完全看词频，
/// 于是 `64426744543`（你在干什么）会被更常见的「你在 + 好奇 + 恶魔」压过去——
/// 句子被切得越碎、单字越多，读起来越不像话。
///
/// 这里给每条路径算总分：`-log(rank)` 打底，每个词收一笔固定成本、单字再重罚一笔。
/// 词数少、词长、词频高的那条路径才会赢。调参就看两个常数，不用动算法。
enum SentenceDecoder {
    /// 每多一个词收的罚分：「你在 + 干什么」两词，「你在 + 好奇 + 恶魔」三词，
    /// 后者多付一次，才压得住它更高的词频。
    private static let wordPenalty = 2.4

    /// 单字成词额外再罚：整句里一串单字基本读不通。
    private static let singleCharPenalty = 3.2

    /// 一条路径最多几个词，防止长串上 DFS 炸开。
    private static let maxWords = 12

    /// 一条边最多几个音节：词库里没有更长的词。
    private static let maxSyllablesPerWord = 6

    struct Candidate: Equatable {
        let text: String
        let words: [String]
        let score: Double
    }

    /// 覆盖整串数字的整句候选，按分数从高到低。
    /// 词库一个都拼不出来时返回空数组，调用方照旧用单词候选。
    static func sentenceCandidates(forDigits digits: String, limit: Int = 6) -> [Candidate] {
        guard digits.count >= 2 else { return [] }

        let chars = Array(digits)
        let n = chars.count
        var best = [Double](repeating: -.infinity, count: n + 1)
        var back = [(prev: Int, word: String)?](repeating: nil, count: n + 1)
        var wordCount = [Int](repeating: 0, count: n + 1)
        best[0] = 0

        for i in 0..<n where best[i] > -.infinity {
            for edge in edges(at: i, in: chars) {
                let score = best[i] + edge.score
                let count = wordCount[i] + 1
                guard count <= maxWords else { continue }
                if score > best[edge.end] {
                    best[edge.end] = score
                    back[edge.end] = (i, edge.word)
                    wordCount[edge.end] = count
                }
            }
        }

        guard best[n] > -.infinity else { return [] }

        var words: [String] = []
        var cursor = n
        while cursor > 0, let step = back[cursor] {
            words.append(step.word)
            cursor = step.prev
        }
        words.reverse()
        guard !words.isEmpty else { return [] }

        var results = [Candidate(text: words.joined(), words: words, score: best[n])]

        // 次优：把最优路径的第一段拆短（换一个同前缀的词），给用户一条备选。
        // 不做完整 k-best——这里只要「第一条不对时还有一条能点」。
        if limit > 1, let alternative = secondBest(forWords: words, digits: chars) {
            results.append(alternative)
        }
        return Array(results.prefix(limit))
    }

    // MARK: - 词图

    private struct Edge {
        let end: Int
        let word: String
        let score: Double
    }

    /// 从第 `start` 个数字位出发的所有词边：把这一段数字切成音节、拼成拼音串，
    /// 词表里存在的就收一条边。
    private static func edges(at start: Int, in chars: [Character]) -> [Edge] {
        var result: [Edge] = []
        var budget = 4000

        func walk(_ position: Int, _ joined: String, _ depth: Int) {
            guard budget > 0, position < chars.count, depth <= maxSyllablesPerWord else { return }
            let restCount = chars.count - position
            for length in stride(from: min(6, restCount), through: 1, by: -1) {
                let code = String(chars[position..<(position + length)])
                for syllable in PinyinEngine.t9Syllables(forDigits: code) {
                    budget -= 1
                    guard budget > 0 else { return }
                    let pinyin = joined + syllable
                    let next = position + length

                    if let entries = PinyinEngine.wordTable[pinyin], !entries.isEmpty {
                        // 词频用 rank 近似：rank 越小越常用
                        let rank = Double(entries.map { $0.rank }.min() ?? 99_999)
                        var score = -log(rank + 1) - wordPenalty
                        if pinyin.count <= 2 { score -= singleCharPenalty }  // 单字词
                        for entry in entries {
                            result.append(Edge(end: next, word: entry.word, score: score))
                        }
                    }

                    // 还可能是更长词的前缀才继续往下接
                    if PinyinEngine.wordKeyPrefixes.contains(pinyin) {
                        walk(next, pinyin, depth + 1)
                    }
                }
            }
        }

        walk(start, "", 1)
        return result
    }

    /// 把最优路径的第一段换成一个更短的词，得到「差一点」的另一条整句。
    private static func secondBest(forWords words: [String], digits: [Character]) -> Candidate? {
        guard words.count > 1 else { return nil }
        let first = words[0]
        let rest = words.dropFirst().joined()
        // 只换个读法：把第一个词换成首字，剩下不动
        guard let head = first.first else { return nil }
        let candidate = String(head) + rest
        guard candidate != words.joined() else { return nil }
        return Candidate(text: candidate, words: [String(head)] + Array(words.dropFirst()), score: -.infinity)
    }
}
