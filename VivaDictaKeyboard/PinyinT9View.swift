//
//  PinyinT9View.swift
//  VivaDictaKeyboard
//
//  汉语拼音九宫格（T9）输入视图，畅言 iOS 的 T9 引擎与字库移植。
//
//  布局（2026-10-21 v6 样板定稿）：4 列键阵，玻璃质感键面（浅顶深底
//  渐变 + 顶部高光 + 圆角），右列为功能键（删除、符号、双行高发送键，
//  发送键紫→青渐变 + 发光），底行左为“英文”键（点按切回英文键盘）、
//  中间为全圆角胶囊空格。顶部候选栏只在输入时显示数字串，不再放
//  静态“拼音”二字；回车键已并入双行发送键，不再单占候选栏位置。
//
//  输入逻辑：数字串按最长匹配切音节，首段音节出候选；选字后从串头
//  扣掉首段编码，剩余部分自动成为下一音节的输入，可连续输词；候选
//  字按每页 6 个分页，点“换页”翻页（末页点“首页”回到第一页）。
//  ^^ 键切符号页（9 个常用标点，删除键两页都在，再点 ABC 回字母页）。
//

import SwiftUI
import UIKit

struct PinyinT9View: View {
    let proxy: UITextDocumentProxy
    /// 切回 KeyboardKit 键盘（英文等语言布局）
    let onSwitchToAlphabet: () -> Void

    @State private var digits: String = ""
    @State private var selectedSyllable: String?
    @State private var candidatePage: Int = 0
    @State private var symbolMode: Bool = false

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

    private var pageCount: Int {
        max(1, (allCandidateChars.count + candidatePageSize - 1) / candidatePageSize)
    }

    private var pageChars: [String] {
        let start = candidatePage * candidatePageSize
        guard start < allCandidateChars.count else { return [] }
        return Array(allCandidateChars[start..<min(start + candidatePageSize, allCandidateChars.count)])
    }

    var body: some View {
        VStack(spacing: 6) {
            candidateBar
            keyGrid
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }

    // MARK: - 候选栏（输入时显示数字串 + 同码音节 + 当页候选字 + 换页）

    private var candidateBar: some View {
        HStack(spacing: 6) {
            if !digits.isEmpty {
                Text(digits)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .leading)
                    .lineLimit(1)
            }

            // 同编码的其他音节：点按切换
            ForEach(syllables.dropFirst(), id: \.self) { syllable in
                Button {
                    selectedSyllable = syllable
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

            // 当页候选字：全局首选高亮
            ForEach(Array(pageChars.enumerated()), id: \.offset) { offset, char in
                let globalIndex = candidatePage * candidatePageSize + offset
                Button {
                    commit(char)
                } label: {
                    Text(char)
                        .font(.system(size: 18))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(
                            globalIndex == 0 && !digits.isEmpty
                                ? Color.primary
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 13)
                        )
                        .foregroundStyle(globalIndex == 0 && !digits.isEmpty ? Color(uiColor: .systemBackground) : .primary)
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
        .frame(height: 38)
        .onChange(of: digits) { _, _ in candidatePage = 0 }
        .onChange(of: selectedSyllable) { _, _ in candidatePage = 0 }
    }

    // MARK: - 键阵（4 列；右列功能键加宽，双行高发送键）

    private var keyGrid: some View {
        GeometryReader { geo in
            let total = geo.size.width
            let col4 = (total - 3 * keyGap) * 0.272
            let col = (total - 3 * keyGap - col4) / 3
            VStack(spacing: rowGap) {
                HStack(spacing: keyGap) {
                    if symbolMode {
                        symbolKey("，", width: col)
                        symbolKey("。", width: col)
                        symbolKey("？", width: col)
                        deleteKey(width: col4)
                    } else {
                        punctKey(width: col)
                        lettersKey("ABC", digit: "2", width: col)
                        lettersKey("DEF", digit: "3", width: col)
                        deleteKey(width: col4)
                    }
                }
                HStack(spacing: keyGap) {
                    if symbolMode {
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
                            if symbolMode {
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
                            englishKey(width: col)
                            spaceKey(width: col * 2 + keyGap)
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

    private func punctKey(width: CGFloat) -> some View {
        keyButton(width: width, height: keyHeight, cornerRadius: keyRadius, face: .glass) {
            commitFirstIfNeeded()
            proxy.insertText("，")
            HapticManager.lightImpact()
        } label: {
            Text("，。？!")
                .font(.system(size: 12))
                .foregroundStyle(.white)
        }
    }

    private func symbolModeKey(width: CGFloat) -> some View {
        keyButton(width: width, height: keyHeight, cornerRadius: keyRadius, face: .glass) {
            commitFirstIfNeeded()
            symbolMode = true
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
    }

    private func tapDelete() {
        if !digits.isEmpty {
            digits = String(digits.dropLast())
            selectedSyllable = nil
        } else {
            proxy.deleteBackward()
        }
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
    }

    private func commitFirstIfNeeded() {
        if let first = allCandidateChars.first {
            commit(first)
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
