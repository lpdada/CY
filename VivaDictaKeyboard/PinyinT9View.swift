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
    /// 点“译”：把当前句（组字串会先上屏）翻成日语并写回输入框
    let onTranslate: () -> Void
    /// 工具条（✨/模式药丸/话筒）：由调用方传入，放在候选区与按键之间、紧贴按键。
    /// 候选区置顶后工具条不再是九宫格视图的上方，而是中间段。
    let toolbar: Toolbar

    init(
        proxy: UITextDocumentProxy,
        onSwitchToAlphabet: @escaping () -> Void,
        onTranslate: @escaping () -> Void,
        @ViewBuilder toolbar: () -> Toolbar
    ) {
        self.proxy = proxy
        self.onSwitchToAlphabet = onSwitchToAlphabet
        self.onTranslate = onTranslate
        self.toolbar = toolbar()
    }

    @State private var digits: String = ""
    @State private var selectedSyllable: String?
    /// 整句候选缓存：只在数字串变化时重算，不放进 body 的 computed property。
    /// 解码一次约 10–40ms，放进 body 会在每次重绘时重复跑，键盘会卡。
    @State private var sentenceCandidates: [String] = []
    @State private var candidatePage: Int = 0
    @State private var symbolMode: Bool = false
    /// 数字键盘模式：与符号页同机制，键阵换成 1–9、0，直接输数字本身
    /// （九宫格字母键按下去是拼拼音，不是数字）。与 symbolMode 互斥。
    @State private var numberMode: Bool = false

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

    /// 展示用候选：整句（覆盖全部数字）→ 整词 → 首段单字。
    /// 整句候选由 PinyinSentenceDecoder 用一元+二元语言模型解码得到，
    /// 不会出现“只给单字”的情况，也不会自动补用户没按的音节。
    private var displayCandidates: [String] {
        var result = sentenceCandidates
        var seen = Set(result)
        for word in wordCandidates where !seen.contains(word) {
            seen.insert(word)
            result.append(word)
        }
        for char in allCandidateChars where !seen.contains(char) {
            seen.insert(char)
            result.append(char)
        }
        return result
    }

    /// 数字串变化后重算整句候选（唯一的解码入口）
    private func refreshSentences() {
        sentenceCandidates = digits.isEmpty
            ? []
            : PinyinSentenceDecoder.decode(digits).map(\.text)
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
            toolbar
            keyGrid
                .padding(.horizontal, 6)
                .padding(.top, 4)
                .padding(.bottom, 6)
        }
        // 切回拼音页时若数字串还在，把组字串重新同步给宿主
        .onAppear {
            refreshSentences()
            syncMarkedText()
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

                Spacer(minLength: 4)

                // 译：中文 → 日语。组字串先上屏，翻译只作用于光标前最后一句。
                Button {
                    tapTranslate()
                } label: {
                    Text("译")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("翻译成日语")
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
                            Text(char)
                                .font(.system(size: 18))
                                .lineLimit(1)
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
            .frame(height: 38)
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
                        symbolModeKey(width: col4)
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

    private func symbolModeKey(width: CGFloat) -> some View {
        keyButton(width: width, height: keyHeight, cornerRadius: keyRadius, face: .glass) {
            commitFirstIfNeeded()
            symbolMode = true
            numberMode = false
            HapticManager.selectionChanged()
        } label: {
            VStack(spacing: 0) {
                Text("^^")
                    .font(.system(size: 11))
                Text("—")
                    .font(.system(size: 11))
            }
            .foregroundStyle(.white)
        }
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
        refreshSentences()
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
        refreshSentences()
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
        refreshSentences()
        syncMarkedText()
    }

    /// 点展示候选：词候选覆盖整串数字，一次上屏并清空；单字走首段扣减。
    /// 词恒为多字、单字恒为单字，按是否在词候选里区分是安全的。
    private func commitDisplay(_ item: String) {
        // 整句和整词都覆盖全部数字：一次上屏、清空输入。
        // 单字只覆盖首段音节，走 commit(_:) 扣掉首段编码。
        if sentenceCandidates.contains(item) || wordCandidates.contains(item) {
            proxy.insertText(item)
            HapticManager.lightImpact()
            digits = ""
            selectedSyllable = nil
            candidatePage = 0
            refreshSentences()
            syncMarkedText()
        } else {
            commit(item)
        }
    }

    /// 译：先把正在组字的整句上屏（否则翻译读到的是旧文本），再交给外层。
    private func tapTranslate() {
        commitFirstIfNeeded()
        onTranslate()
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
