//
//  PinyinT9View.swift
//  VivaDictaKeyboard
//
//  汉语拼音九宫格（T9）输入视图，畅言 iOS 的 T9 引擎与字库移植。
//
//  布局（2026-10-22 置换版）：候选区永久置顶在最上面（两行：上行数字串
//  与同码音节、下行候选字与换页），空闲时两行空白占位、高度与打字时
//  一致，键盘总高度全程不变；工具条（✨/模式药丸/话筒）移到候选区与
//  按键之间、紧贴按键。4 列键阵，玻璃质感键面（浅顶深底渐变 + 顶部
//  高光 + 圆角），右列为功能键（删除、符号、双行高发送键，发送键
//  紫→青渐变 + 发光），底行左为“英文”键（点按切回英文键盘）、中间
//  为全圆角胶囊空格；回车键已并入双行发送键，不再单占候选栏位置。
//  左上 123 键切数字页（1–9、0 直接输数字本身，点 ABC 回字母页），
//  与符号页同机制；标点统一收进 ^^ 符号页。
//
//  输入逻辑（真输入法三件套）：数字串全部切分后查 3 万词词库，词候选
//  按词频排在单字候选前面（如 64426 → 你好），点词一次上屏并清空；
//  单字仍可逐个音节选（选字后从串头扣掉首段编码，剩余部分自动成为
//  下一音节的输入）。首选候选同步为文档里的 marked text（组字串），
//  宿主像真输入法一样显示正在组字的词。候选按每页 6 个分页，点“换页”
//  翻页（末页点“首页”回第一页）。^^ 键切符号页（9 个常用标点，删除
//  键两页都在，再点 ABC 回字母页）。候选区永久置顶、高度全程不变，
//  空闲时两行空白占位。
//

import SwiftUI
import UIKit

struct PinyinT9View<Toolbar: View>: View {
    let proxy: UITextDocumentProxy
    /// 切回 KeyboardKit 键盘（英文等语言布局）
    let onSwitchToAlphabet: () -> Void
    /// 工具条（✨/模式药丸/话筒）：由调用方传入，放在候选区与按键之间、紧贴按键。
    /// 候选区置顶后工具条不再是九宫格视图的上方，而是中间段。
    let toolbar: Toolbar

    init(
        proxy: UITextDocumentProxy,
        onSwitchToAlphabet: @escaping () -> Void,
        @ViewBuilder toolbar: () -> Toolbar
    ) {
        self.proxy = proxy
        self.onSwitchToAlphabet = onSwitchToAlphabet
        self.toolbar = toolbar()
    }

    @State private var digits: String = ""
    @State private var selectedSyllable: String?
    @State private var candidatePage: Int = 0
    @State private var symbolMode: Bool = false
    /// 数字键盘模式：与符号页同机制，键阵换成 1–9、0，直接输数字本身
    /// （九宫格字母键按下去是拼拼音，不是数字）。与 symbolMode 互斥。
    @State private var numberMode: Bool = false
    /// 整句译文：数字串停下 450 ms 后把首选中文发出去换一句学习语言，回来画在候选区下面。
    @State private var glossary = SentenceGlossState()

    // MARK: - 尺寸（v6 样板按 3x 换算为 pt：键 264x168px → 88x56pt，倒角 30px → 10pt）

    private let keyHeight: CGFloat = 56
    private let keyGap: CGFloat = 7
    private let rowGap: CGFloat = 6
    private let keyRadius: CGFloat = 10
    private let candidatePageSize = 6

    // MARK: - 派生状态

    /// 首段编码：数字串贪心最长匹配的第一段，决定当前候选。
    /// 连续输词时，选字后剩余部分重新切分，自动成为下一音节。
    private var firstCode: String? {
        PinyinEngine.t9FirstCode(forDigits: digits)
    }

    /// 首段编码对应的全部音节（按常用度排序）
    private var syllables: [String] {
        guard let firstCode else { return [] }
        return PinyinEngine.t9Syllables(forDigits: firstCode)
    }

    private var currentSyllable: String? {
        if let selectedSyllable, syllables.contains(selectedSyllable) {
            return selectedSyllable
        }
        return syllables.first
    }

    private var allCandidateChars: [String] {
        guard let currentSyllable else { return [] }
        return PinyinEngine.candidates(for: currentSyllable)
    }

    /// 词候选：数字串全部切分后查词库，按全局词频排序
    private var wordCandidates: [String] {
        PinyinEngine.wordCandidates(forDigits: digits)
    }

    /// 整句译文要翻的那段中文：先用整句解码的第一条（读得通的那句），
    /// 拼不出来才退回「词库覆盖整串的词」，再退回按音节取首选字。
    private var sentenceSource: String? {
        if let whole = SentenceDecoder.sentenceCandidates(forDigits: digits, limit: 1).first?.text,
           whole.count >= 2 {
            return whole
        }
        if let whole = wordCandidates.first, whole.count >= 2 {
            return whole
        }
        var rest = digits
        var sentence = ""
        while !rest.isEmpty {
            guard let code = PinyinEngine.t9FirstCode(forDigits: rest),
                  let syllable = PinyinEngine.t9Syllables(forDigits: code).first,
                  let first = PinyinEngine.candidates(for: syllable).first
            else { break }
            sentence.append(contentsOf: first)
            rest = String(rest.dropFirst(code.count))
        }
        return sentence.count >= 2 ? sentence : nil
    }

    /// 展示用候选：整句解码的第一条排最前，其后是词库候选与首段单字。
    /// 整句那条才是「你在干什么」这种一口气读得通的读法，词候选只是备选。
    private var displayCandidates: [String] {
        var seen = Set<String>()
        let merged = SentenceDecoder.sentenceCandidates(forDigits: digits).map(\.text)
            + wordCandidates
            + allCandidateChars
        return merged.filter { seen.insert($0).inserted }
    }

    private var pageCount: Int {
        max(1, (displayCandidates.count + candidatePageSize - 1) / candidatePageSize)
    }

    private var pageChars: [String] {
        let start = candidatePage * candidatePageSize
        guard start < displayCandidates.count else { return [] }
        return Array(displayCandidates[start..<min(start + candidatePageSize, displayCandidates.count)])
    }

    var body: some View {
        VStack(spacing: 0) {
            // 候选区永久置顶：空闲时两行空白占位，高度与打字时一致，
            // 键盘总高度全程不变，首按键不再跳。
            candidateArea
                .padding(.horizontal, 6)
                .padding(.top, 4)
                .padding(.bottom, 4)
            // 整句译文并进首选候选卡片（见 candidateArea），不再单占一行
            toolbar
            keyGrid
                .padding(.horizontal, 6)
                .padding(.top, 4)
                .padding(.bottom, 6)
        }
        // 切回拼音页时若数字串还在，把组字串重新同步给宿主
        .onAppear { syncMarkedText() }
        // 每次数字串变化都重排译文请求：停手 450 ms 才真发，之前那条取消。
        // 翻的是整段（sentenceSource），不是排第一的那个候选词
        .onChange(of: digits) { _, _ in
            glossary.schedule(for: sentenceSource)
        }
    }

    // MARK: - 候选区（永久置顶，两行：上行数字串 + 同码音节，下行候选字 + 换页）

    /// 候选区永远在最上面、永远占据同样高度：空闲时两行空白占位，
    /// 打字时上行放数字串与同码音节、下行放候选字与换页。
    /// 两行分开后候选字一行不再与数字串、音节挤在同一行，
    /// 之前截断成 …、互相重叠的问题也随之缓解。
    private var candidateArea: some View {
        VStack(spacing: 4) {
            // 上行：数字串 + 同编码的其他音节（点按切换）
            HStack(spacing: 6) {
                if !digits.isEmpty {
                    Text(digits)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .leading)
                        .lineLimit(1)

                    ForEach(syllables.dropFirst(), id: \.self) { syllable in
                        Button {
                            selectedSyllable = syllable
                            candidatePage = 0
                            syncMarkedText()
                            HapticManager.selectionChanged()
                        } label: {
                            Text(syllable)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 28)
            .frame(maxWidth: .infinity, alignment: .leading)

            // 下行：当页候选（全局首选高亮，多段时首位是整词）+ 换页
            HStack(spacing: 6) {
                if !digits.isEmpty {
                    ForEach(Array(pageChars.enumerated()), id: \.offset) { offset, char in
                        let globalIndex = candidatePage * candidatePageSize + offset
                        Button {
                            commitDisplay(char)
                        } label: {
                            // 首选是一个上下两行的卡片：上面中文、下面整句译文；
                            // 其余候选保持单行，横向空间不被日语吃掉
                            VStack(spacing: 1) {
                                Text(char)
                                    .font(.system(size: 18))
                                    .lineLimit(1)
                                if globalIndex == 0, let gloss = glossary.text, !gloss.isEmpty {
                                    Text(gloss)
                                        .font(.system(size: 11))
                                        .lineLimit(1)
                                        .opacity(0.85)
                                }
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(
                                globalIndex == 0
                                    ? Color.primary
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 13)
                            )
                            .foregroundStyle(globalIndex == 0 ? Color(uiColor: .systemBackground) : .primary)
                        }
                        .buttonStyle(.plain)
                    }

                    // 换页：多页时出现，末页点“首页”回到第一页
                    if pageCount > 1 {
                        Button {
                            nextPage()
                        } label: {
                            Text(candidatePage >= pageCount - 1 ? "首页" : "换页")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 56)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: digits) { _, _ in candidatePage = 0 }
        .onChange(of: selectedSyllable) { _, _ in candidatePage = 0 }
    }

    // MARK: - 键阵（4 列等宽，双行高发送键）

    private var keyGrid: some View {
        GeometryReader { geo in
            let total = geo.size.width
            let col = (total - 3 * keyGap) / 4
            let col4 = col
            VStack(spacing: rowGap) {
                HStack(spacing: keyGap) {
                    if numberMode {
                        numberKey("1", width: col)
                        numberKey("2", width: col)
                        numberKey("3", width: col)
                        deleteKey(width: col4)
                    } else if symbolMode {
                        symbolKey("，", width: col)
                        symbolKey("。", width: col)
                        symbolKey("？", width: col)
                        deleteKey(width: col4)
                    } else {
                        numberModeKey(width: col)
                        lettersKey("ABC", digit: "2", width: col)
                        lettersKey("DEF", digit: "3", width: col)
                        deleteKey(width: col4)
                    }
                }
                HStack(spacing: keyGap) {
                    if numberMode {
                        numberKey("4", width: col)
                        numberKey("5", width: col)
                        numberKey("6", width: col)
                        backToLettersKey(width: col4)
                    } else if symbolMode {
                        symbolKey("、", width: col)
                        symbolKey("；", width: col)
                        symbolKey("：", width: col)
                        backToLettersKey(width: col4)
                    } else {
                        lettersKey("GHI", digit: "4", width: col)
                        lettersKey("JKL", digit: "5", width: col)
                        lettersKey("MNO", digit: "6", width: col)
                        punctuationKey(width: col4)
                    }
                }
                HStack(spacing: keyGap) {
                    VStack(spacing: rowGap) {
                        HStack(spacing: keyGap) {
                            if numberMode {
                                numberKey("7", width: col)
                                numberKey("8", width: col)
                                numberKey("9", width: col)
                            } else if symbolMode {
                                symbolKey("（", width: col)
                                symbolKey("）", width: col)
                                symbolKey("！", width: col)
                            } else {
                                lettersKey("PQRS", digit: "7", width: col)
                                lettersKey("TUV", digit: "8", width: col)
                                lettersKey("WXYZ", digit: "9", width: col)
                            }
                        }
                        HStack(spacing: keyGap) {
                            if numberMode {
                                // 数字页底行：0 + 空格（电话号码分段用）；
                                // 回字母页走第二行末尾的 ABC，英文键在字母页。
                                numberKey("0", width: col)
                                spaceKey(width: col * 2 + keyGap)
                            } else {
                                englishKey(width: col)
                                spaceKey(width: col * 2 + keyGap)
                            }
                        }
                    }
                    .frame(width: col * 3 + 2 * keyGap)
                    sendKey(width: col4)
                }
            }
        }
        .frame(height: keyHeight * 4 + rowGap * 3)
    }

    // MARK: - 键面

    private enum KeyFace {
        case glass
        case send
    }

    private func faceBackground(_ face: KeyFace) -> LinearGradient {
        switch face {
        case .glass:
            return LinearGradient(
                colors: [Color(red: 74 / 255, green: 80 / 255, blue: 108 / 255),
                         Color(red: 36 / 255, green: 40 / 255, blue: 60 / 255)],
                startPoint: .top, endPoint: .bottom)
        case .send:
            return LinearGradient(
                colors: [Color(red: 168 / 255, green: 85 / 255, blue: 247 / 255),
                         Color(red: 34 / 255, green: 211 / 255, blue: 238 / 255)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private func faceBorder(_ face: KeyFace) -> Color {
        face == .send
            ? Color(red: 190 / 255, green: 140 / 255, blue: 255 / 255)
            : Color(red: 115 / 255, green: 124 / 255, blue: 158 / 255)
    }

    private func keyButton<Label: View>(
        width: CGFloat, height: CGFloat, cornerRadius: CGFloat, face: KeyFace,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button(action: action) {
            label()
                .frame(width: width, height: height)
                .background(faceBackground(face), in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(faceBorder(face), lineWidth: 0.7)
                )
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(.white.opacity(0.25))
                        .frame(height: 1)
                        .padding(.top, 2)
                        .padding(.horizontal, cornerRadius)
                }
                .shadow(
                    color: face == .send
                        ? Color(red: 150 / 255, green: 80 / 255, blue: 255 / 255).opacity(0.5)
                        : .clear,
                    radius: 12, x: 0, y: 0)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 各键

    private func lettersKey(_ letters: String, digit: String, width: CGFloat) -> some View {
        keyButton(width: width, height: keyHeight, cornerRadius: keyRadius, face: .glass) {
            tapDigit(digit)
        } label: {
            Text(letters)
                .font(.system(size: 14))
                .foregroundStyle(.white)
                .tracking(1)
        }
    }

    /// 数字键盘入口（左上）：先把未完成的组字上屏，再切数字页。
    /// 原来的 ，。？! 键只输 ，、键面却印四个符号，且 ，。？ 在符号页
    /// 里已有，两处标点重合，故换成九宫格缺失的直接输数字入口。
    private func numberModeKey(width: CGFloat) -> some View {
        keyButton(width: width, height: keyHeight, cornerRadius: keyRadius, face: .glass) {
            commitFirstIfNeeded()
            numberMode = true
            symbolMode = false
            HapticManager.selectionChanged()
        } label: {
            Text("123")
                .font(.system(size: 14))
                .foregroundStyle(.white)
                .tracking(1)
        }
    }

    /// 数字页的数字键：直接上屏数字本身（字母页按 2–9 是在拼拼音）。
    private func numberKey(_ digit: String, width: CGFloat) -> some View {
        keyButton(width: width, height: keyHeight, cornerRadius: keyRadius, face: .glass) {
            commitFirstIfNeeded()
            proxy.insertText(digit)
            HapticManager.lightImpact()
        } label: {
            Text(digit)
                .font(.system(size: 14))
                .foregroundStyle(.white)
                .tracking(1)
        }
    }

    /// 标点键：点一下出「，」；按住 350 ms 进符号页（9 个常用标点）。
    /// 原来这一格是 `^^` 符号页入口——用户找不到逗号句号，所以把最常用的两个摊到键面上。
    private func punctuationKey(width: CGFloat) -> some View {
        PunctuationKey(
            width: width,
            height: keyHeight,
            cornerRadius: keyRadius,
            onTap: {
                commitFirstIfNeeded()
                proxy.insertText("，")
                HapticManager.lightImpact()
            },
            onLongPress: {
                commitFirstIfNeeded()
                symbolMode = true
                numberMode = false
                HapticManager.selectionChanged()
            }
        )
    }

    private func backToLettersKey(width: CGFloat) -> some View {
        keyButton(width: width, height: keyHeight, cornerRadius: keyRadius, face: .glass) {
            symbolMode = false
            numberMode = false
            HapticManager.selectionChanged()
        } label: {
            Text("ABC")
                .font(.system(size: 14))
                .foregroundStyle(.white)
                .tracking(1)
        }
    }

    private func symbolKey(_ symbol: String, width: CGFloat) -> some View {
        keyButton(width: width, height: keyHeight, cornerRadius: keyRadius, face: .glass) {
            commitFirstIfNeeded()
            proxy.insertText(symbol)
            HapticManager.lightImpact()
        } label: {
            Text(symbol)
                .font(.system(size: 14))
                .foregroundStyle(.white)
        }
    }

    private func englishKey(width: CGFloat) -> some View {
        keyButton(width: width, height: keyHeight, cornerRadius: keyRadius, face: .glass) {
            onSwitchToAlphabet()
            HapticManager.selectionChanged()
        } label: {
            Text("英文")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
        }
    }

    private func spaceKey(width: CGFloat) -> some View {
        keyButton(width: width, height: keyHeight, cornerRadius: keyHeight / 2, face: .glass) {
            if digits.isEmpty {
                proxy.insertText(" ")
            } else {
                commitFirstIfNeeded()
            }
            HapticManager.lightImpact()
        } label: {
            Text("空格")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
        }
    }

    private func deleteKey(width: CGFloat) -> some View {
        RepeatDeleteButton(width: width, height: keyHeight, action: tapDelete)
    }

    private func sendKey(width: CGFloat) -> some View {
        keyButton(width: width, height: keyHeight * 2 + rowGap, cornerRadius: keyRadius, face: .send) {
            commitFirstIfNeeded()
            proxy.insertText("\n")
            HapticManager.lightImpact()
        } label: {
            VStack(spacing: 12) {
                Image(systemName: "return")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.white)
                Text("发送")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
    }

    // MARK: - 输入逻辑

    private func tapDigit(_ digit: String) {
        HapticManager.lightImpact()
        digits += digit
        selectedSyllable = nil
        candidatePage = 0
        syncMarkedText()
    }

    private func tapDelete() {
        if !digits.isEmpty {
            digits = String(digits.dropLast())
            selectedSyllable = nil
            candidatePage = 0
        } else {
            proxy.deleteBackward()
        }
        syncMarkedText()
    }

    private func nextPage() {
        if candidatePage >= pageCount - 1 {
            candidatePage = 0
        } else {
            candidatePage += 1
        }
        HapticManager.selectionChanged()
    }

    /// 选中候选字：上屏，并从数字串头部扣掉首段音节对应的编码长度；
    /// 剩余部分下次重切，自动成为下一音节的输入，连续输词即由此成立。
    private func commit(_ char: String) {
        guard currentSyllable != nil, let code = firstCode else { return }
        proxy.insertText(char)
        HapticManager.lightImpact()
        digits = String(digits.dropFirst(min(code.count, digits.count)))
        selectedSyllable = nil
        // 页码显式复位（候选区现为永久保留，onChange 也会复位，
        // 这里再保一层，避免上屏后停在旧页）。
        candidatePage = 0
        syncMarkedText()
    }

    /// 点展示候选：整句和词候选都覆盖整串数字，一次上屏并清空；
    /// 单字候选恒为一个字，走首段扣减。
    private func commitDisplay(_ item: String) {
        if item.count >= 2 || wordCandidates.contains(item) {
            proxy.insertText(item)
            HapticManager.lightImpact()
            digits = ""
            selectedSyllable = nil
            candidatePage = 0
            syncMarkedText()
        } else {
            commit(item)
        }
    }

    /// 把首选候选同步为文档里的 marked text（组字串），让宿主像真输入法
    /// 一样显示正在组字的词；不支持 marked text 的宿主会忽略它，选字流程不受影响。
    private func syncMarkedText() {
        if digits.isEmpty || displayCandidates.isEmpty {
            proxy.unmarkText()
        } else if let top = displayCandidates.first {
            proxy.setMarkedText(top, selectedRange: NSRange(location: top.utf16.count, length: 0))
        }
    }

    private func commitFirstIfNeeded() {
        if let first = displayCandidates.first {
            commitDisplay(first)
        }
    }
}

/// 退格键：点按删一个，按住 0.4 秒后以 60ms 间隔连删，松开即停。
/// 用 DragGesture 统一处理点按与长按，避免 SwiftUI 手势竞争双触发。
private struct RepeatDeleteButton: View {
    let width: CGFloat
    let height: CGFloat
    let action: () -> Void

    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(LinearGradient(
                    colors: [Color(red: 74 / 255, green: 80 / 255, blue: 108 / 255),
                             Color(red: 36 / 255, green: 40 / 255, blue: 60 / 255)],
                    startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color(red: 115 / 255, green: 124 / 255, blue: 158 / 255), lineWidth: 0.7)
                )
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(.white.opacity(0.25))
                        .frame(height: 1)
                        .padding(.top, 2)
                        .padding(.horizontal, 10)
                }
            Image(systemName: "delete.left")
                .font(.system(size: 20))
                .foregroundStyle(.white)
        }
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard repeatTask == nil else { return }
                    action()
                    HapticManager.lightImpact()
                    repeatTask = Task {
                        try? await Task.sleep(for: .milliseconds(400))
                        while !Task.isCancelled {
                            action()
                            try? await Task.sleep(for: .milliseconds(60))
                        }
                    }
                }
                .onEnded { _ in
                    repeatTask?.cancel()
                    repeatTask = nil
                }
        )
    }
}

// MARK: - 整句译文

/// 整句译文的状态机：停手 450 ms 才发、旧请求取消、拿不到就保留上一条。
/// 词库和候选仍在 `PinyinT9View` 里，这里只管「一句话的译文」这一件事。
@MainActor
@Observable
final class SentenceGlossState {
    private(set) var text: String?
    private(set) var isLoading = false

    private var task: Task<Void, Never>?

    /// `source` 是当前首选中文；不到两个字就当没在打句子，直接清空。
    func schedule(for source: String?) {
        task?.cancel()
        guard let source, source.count >= 2 else {
            text = nil
            isLoading = false
            return
        }
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard let self, !Task.isCancelled else { return }
            self.isLoading = true
            let result = await SentenceTranslator.shared.translate(source)
            guard !Task.isCancelled else { return }
            self.isLoading = false
            if let result {
                self.text = result
            }
        }
    }
}

/// 标点键：点一下出「，」，按住 350 ms 进符号页。
/// 自己画键面而不复用 `keyButton`，因为要在同一块区域区分点按与长按。
private struct PunctuationKey: View {
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat
    let onTap: () -> Void
    let onLongPress: () -> Void

    @State private var longPressed = false
    @State private var holdTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 1) {
            Text("，")
                .font(.system(size: 17, weight: .medium))
            Text("。")
                .font(.system(size: 12))
                .opacity(0.72)
        }
        .foregroundStyle(.white)
        .frame(width: width, height: height)
        .background(
            LinearGradient(
                colors: [Color(red: 74 / 255, green: 80 / 255, blue: 108 / 255),
                         Color(red: 36 / 255, green: 40 / 255, blue: 60 / 255)],
                startPoint: .top, endPoint: .bottom),
            in: RoundedRectangle(cornerRadius: cornerRadius)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(Color(red: 115 / 255, green: 124 / 255, blue: 158 / 255), lineWidth: 0.7)
        )
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard holdTask == nil else { return }
                    holdTask = Task {
                        try? await Task.sleep(for: .milliseconds(350))
                        guard !Task.isCancelled else { return }
                        longPressed = true
                        onLongPress()
                    }
                }
                .onEnded { _ in
                    holdTask?.cancel()
                    holdTask = nil
                    if !longPressed { onTap() }
                    longPressed = false
                }
        )
    }
}
