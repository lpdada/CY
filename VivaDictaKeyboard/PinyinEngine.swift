import Foundation

/// 拼音引擎：输入串 → 切音节 → 查候选。
/// 候选按字频排序，只做单字（不组词），够日常打字用。
enum PinyinEngine {
    /// 贪心最长匹配切音节。输入里的 v 当 ü（词典里 ü 存的是 v）。
    static func segment(_ input: String) -> [String] {
        var rest = input.lowercased()
        var result: [String] = []
        while !rest.isEmpty {
            var matched: String?
            // 最长 6 个字母（zhuang/chuang/shuang）
            for len in stride(from: min(6, rest.count), through: 1, by: -1) {
                let head = String(rest.prefix(len))
                if PinyinData.syllables.contains(head) {
                    matched = head
                    break
                }
            }
            guard let m = matched else {
                // 切不出来：吞掉首字母，避免死循环
                rest = String(rest.dropFirst())
                continue
            }
            result.append(m)
            rest = String(rest.dropFirst(m.count))
        }
        return result
    }

    /// 每个音节的候选字串
    static func candidates(for syllable: String) -> [String] {
        guard let chars = PinyinData.dictionary[syllable] else { return [] }
        return chars.map { String($0) }
    }

    /// 输入串的全部候选：按音节分组，[(音节, [候选字])]
    static func candidates(forInput input: String) -> [(syllable: String, chars: [String])] {
        segment(input).map { ($0, candidates(for: $0)) }
    }
}

// MARK: - 九宫格（T9）支持
//
// 数字键映射：2=abc 3=def 4=ghi 5=jkl 6=mno 7=pqrs 8=tuv 9=wxyz。
// 每个字母恰好一个键，所以音节与其 T9 编码等长：选完一个音节的字后，
// 从数字缓冲头部扣掉同等长度即可，连续输入多音节天然成立。
extension PinyinEngine {
    private static let t9Groups: [Character: String] = [
        "2": "abc", "3": "def", "4": "ghi", "5": "jkl",
        "6": "mno", "7": "pqrs", "8": "tuv", "9": "wxyz",
    ]

    /// 音节 → T9 编码
    static func t9Code(for syllable: String) -> String {
        var code = ""
        for ch in syllable {
            for (digit, letters) in t9Groups where letters.contains(ch) {
                code.append(digit)
                break
            }
        }
        return code
    }

    /// 数字串 → 与之完全匹配的音节（按常用度排序）。
    /// 预先算好全表映射后按编码查，避免每次遍历全部音节。
    static func t9Syllables(forDigits digits: String) -> [String] {
        guard !digits.isEmpty else { return [] }
        return t9Index[digits] ?? []
    }

    /// 数字串的首段编码：从头取最长有效 T9 编码前缀（最长 6 位）。
    /// 连续输词就靠它：选字后扣掉首段，剩余部分下次重切，自动成为
    /// 下一音节；整串只按单音节精确匹配时，多音节连输会无候选。
    /// 歧义时取最长匹配（与 segment() 的贪心策略一致）；逐个音节
    /// 选字一定准，整词连输时个别歧义（如西安/先）以最长匹配为准。
    static func t9FirstCode(forDigits digits: String) -> String? {
        guard !digits.isEmpty else { return nil }
        for len in stride(from: min(6, digits.count), through: 1, by: -1) {
            let head = String(digits.prefix(len))
            if !t9Syllables(forDigits: head).isEmpty { return head }
        }
        return nil
    }

    /// 高频音节优先序（同编码多音节时排序与默认选中用）：
    /// 表里越靠前越常用；不在表里的排后面、按字母序。
    private static let hotSyllables: [String] = [
        "de", "shi", "wo", "ni", "ta", "zai", "you", "le", "ma", "bu",
        "ren", "zhe", "ge", "lai", "dao", "shang", "zhong", "guo", "wei", "he",
        "xiang", "yao", "shuo", "neng", "jiu", "ke", "yi", "dou", "hao", "xian",
        "hou", "men", "zi", "li", "la", "ba", "ne", "me", "ri", "tian",
        "nian", "jin", "ming", "shui", "da", "xiao", "yu", "er", "san", "si",
    ]
    private static let hotRank: [String: Int] = {
        var m: [String: Int] = [:]
        for (i, s) in hotSyllables.enumerated() { m[s] = i }
        return m
    }()

    private static let t9Index: [String: [String]] = {
        var index: [String: [String]] = [:]
        for syllable in PinyinData.syllables {
            index[t9Code(for: syllable), default: []].append(syllable)
        }
        for (code, list) in index {
            index[code] = list.sorted { a, b in
                let ra = hotRank[a] ?? Int.max
                let rb = hotRank[b] ?? Int.max
                if ra != rb { return ra < rb }
                return a < b
            }
        }
        return index
    }()
}
