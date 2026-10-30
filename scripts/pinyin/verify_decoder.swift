//
//  verify_decoder.swift
//  Standalone harness for PinyinSentenceDecoder (no simulator needed).
//
//  Build & run on macOS:
//      scripts/pinyin/verify_decoder.sh
//
//  It compiles the pure-logic sources (PinyinData, PinyinEngine,
//  PinyinLanguageModel, PinyinSentenceDecoder) plus this file with swiftc
//  and checks the decoder against a fixed sentence set.
//

import Foundation

@main
struct VerifyDecoder {
    /// (pinyin, expected sentence)
    static let cases: [(String, String)] = [
        ("ni zai gan shen me", "你在干什么"),
        ("wo jin tian hen mang", "我今天很忙"),
        ("ming tian ji dian kai hui", "明天几点开会"),
        ("wan shang yi qi chi fan", "晚上一起吃饭"),
        ("ni zai gan ma", "你在干吗"),
        ("jin tian tian qi zen me yang", "今天天气怎么样"),
        ("wo xian zai zai jia", "我现在在家"),
        ("ni hao", "你好"),
        ("xie xie", "谢谢"),
        ("dui bu qi", "对不起"),
        ("wo xiang ni le", "我想你了"),
        ("ni chi fan le ma", "你吃饭了吗"),
        ("zhe ge duo shao qian", "这个多少钱"),
        ("qing wen xi shou jian zai na li", "请问洗手间在哪里"),
        ("wo ming tian qu shang ban", "我明天去上班"),
        ("ni you kong ma", "你有空吗"),
        ("wo ma shang dao", "我马上到"),
        ("zhe li bu neng ting che", "这里不能停车"),
        ("ni shuo shen me", "你说什么"),
        ("wo bu zhi dao", "我不知道"),
        ("ta shi wo de peng you", "他是我的朋友"),
        ("qing ni bang wo yi xia", "请你帮我一下"),
        ("zhe ge wen ti hen zhong yao", "这个问题很重要"),
        ("wo men ming tian jian", "我们明天见"),
    ]

    static func digits(_ pinyin: String) -> String {
        pinyin.split(separator: " ").map { PinyinEngine.t9Code(for: String($0)) }.joined()
    }

    static func main() {
        var top1 = 0
        var top5 = 0

        for (pinyin, expected) in cases {
            let code = digits(pinyin)
            let started = Date()
            let candidates = PinyinSentenceDecoder.decode(code)
            let elapsed = Date().timeIntervalSince(started) * 1000
            let texts = candidates.map(\.text)
            let hit1 = texts.first == expected
            let hit5 = texts.prefix(5).contains(expected)
            top1 += hit1 ? 1 : 0
            top5 += hit5 ? 1 : 0

            let mark = hit1 ? "✅" : (hit5 ? "🟡" : "❌")
            print(String(format: "%@ %@ → %@  (%.0f ms)", mark, pinyin, texts.first ?? "<空>", elapsed))
            if !hit1 {
                print("     期望: \(expected) · 候选: \(texts.prefix(5).joined(separator: " / "))")
            }
            assert(candidates.allSatisfy { !$0.text.isEmpty }, "empty candidate")
        }

        // 稳定性：同一数字串两次解码结果必须一致（解码器不得有随机性）
        let sample = digits("ni zai gan shen me")
        let first = PinyinSentenceDecoder.decode(sample).map(\.text)
        let second = PinyinSentenceDecoder.decode(sample).map(\.text)
        print("\n解码稳定性: \(first == second ? "一致" : "不一致（有随机性，必须修）")")

        print("\nTOP1 \(top1)/\(cases.count)   TOP5 \(top5)/\(cases.count)")
        if top5 < cases.count {
            print("❌ 有句子连前 5 都没进，先查 PinyinLanguageModel 是否漏文件")
            exit(1)
        }
        if top1 < cases.count - 2 {
            print("⚠️ TOP1 \(top1)/\(cases.count) 低于基线 22，检查插入惩罚/语言模型表")
            exit(2)
        }
        print("✅ decoder 验收通过")
    }
}
