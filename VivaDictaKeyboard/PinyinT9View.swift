//
//  PinyinT9View.swift
//  VivaDictaKeyboard
//
//  汉语拼音九宫格（T9）输入视图，畅言 iOS 的 T9 引擎与字库移植。
//
//  设计：候选栏（音节切换 + 候选字横滚）+ 4×3 键阵，键面沿用系统键盘
//  外观（白键面、底部硬阴影、功能键灰面）。与 KeyboardKit 英文键盘并存，
//  由 KeyboardCustomView 的输入模式状态切换（默认九宫格）。
//  交互与畅言一致：一字母一键等长，选字后按音节编码长度从数字串头部
//  扣减，支持连续输入多个音节；退格长按连删。
//

import SwiftUI
import UIKit

struct PinyinT9View: View {
    let proxy: UITextDocumentProxy
    /// 切回 KeyboardKit 键盘（英文等语言布局）
    let onSwitchToAlphabet: () -> Void

    @State private var digits: String = ""
    @State private var selectedSyllable: String?

    // MARK: - 派生状态

    private var syllables: [String] {
        PinyinEngine.t9Syllables(forDigits: digits)
    }

    private var currentSyllable: String? {
        if let selectedSyllable, syllables.contains(selectedSyllable) {
            return selectedSyllable
        }
        return syllables.first
    }

    private var candidateChars: [String] {
        guard let currentSyllable else { return [] }
        return PinyinEngine.candidates(for: currentSyllable)
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

    // MARK: - 候选栏

    private var candidateBar: some View {
        HStack(spacing: 6) {
            Text(digits.isEmpty ? "拼音" : digits)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
                .lineLimit(1)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
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
                    // 候选字：首选高亮
                    ForEach(Array(candidateChars.enumerated()), id: \.offset) { index, char in
                        Button {
                            commit(char)
                        } label: {
                            Text(char)
                                .font(.system(size: 18))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(
                                    index == 0 && !digits.isEmpty
                                        ? Color.primary
                                        : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 13)
                                )
                                .foregroundStyle(index == 0 && !digits.isEmpty ? Color(uiColor: .systemBackground) : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Button {
                commitFirstIfNeeded()
                proxy.insertText("\n")
                HapticManager.lightImpact()
            } label: {
                Image(systemName: "return")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
        }
        .frame(height: 38)
    }

    // MARK: - 键阵

    private var keyGrid: some View {
        VStack(spacing: 6) {
            keyRow([
                .punctuation,
                .digit("2", letters: "ABC"),
                .digit("3", letters: "DEF"),
            ])
            keyRow([
                .digit("4", letters: "GHI"),
                .digit("5", letters: "JKL"),
                .digit("6", letters: "MNO"),
            ])
            keyRow([
                .digit("7", letters: "PQRS"),
                .digit("8", letters: "TUV"),
                .digit("9", letters: "WXYZ"),
            ])
            keyRow([
                .switchKeyboard,
                .digit("0", letters: "空格"),
                .delete,
            ])
        }
    }

    private enum T9Key {
        case digit(String, letters: String)
        case punctuation
        case switchKeyboard
        case delete
    }

    private func keyRow(_ keys: [T9Key]) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                keyView(key)
            }
        }
    }

    @ViewBuilder
    private func keyView(_ key: T9Key) -> some View {
        switch key {
        case .digit(let digit, let letters):
            Button {
                tapDigit(digit)
            } label: {
                keyFace(isFunction: false) {
                    VStack(spacing: 0) {
                        Text(digit)
                            .font(.system(size: 21))
                        Text(letters)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .tracking(1)
                    }
                }
            }
            .buttonStyle(.plain)

        case .punctuation:
            Button {
                commitFirstIfNeeded()
                proxy.insertText("，")
                HapticManager.lightImpact()
            } label: {
                keyFace(isFunction: false) {
                    VStack(spacing: 0) {
                        Text("1")
                            .font(.system(size: 21))
                        Text("，。、")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)

        case .switchKeyboard:
            Button {
                onSwitchToAlphabet()
                HapticManager.selectionChanged()
            } label: {
                keyFace(isFunction: true) {
                    Text("英")
                        .font(.system(size: 16, weight: .medium))
                }
            }
            .buttonStyle(.plain)

        case .delete:
            RepeatDeleteButton(action: tapDelete)
        }
    }

    private func keyFace<Content: View>(isFunction: Bool, @ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(
                isFunction ? Color(uiColor: .systemGray3) : Color(uiColor: .systemBackground),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .shadow(color: .black.opacity(0.28), radius: 0, x: 0, y: 1)
    }

    // MARK: - 输入逻辑

    private func tapDigit(_ digit: String) {
        HapticManager.lightImpact()
        if digit == "0" {
            if digits.isEmpty {
                proxy.insertText(" ")
            } else {
                commitFirstIfNeeded()
            }
            return
        }
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

    /// 选中候选字：上屏，并从数字串头部扣掉这个音节对应的编码长度
    private func commit(_ char: String) {
        guard let syllable = currentSyllable else { return }
        proxy.insertText(char)
        HapticManager.lightImpact()
        let codeLength = PinyinEngine.t9Code(for: syllable).count
        digits = String(digits.dropFirst(min(codeLength, digits.count)))
        selectedSyllable = nil
    }

    private func commitFirstIfNeeded() {
        if let first = candidateChars.first {
            commit(first)
        }
    }
}

/// 退格键：点按删一个，按住 0.4 秒后以 60ms 间隔连删，松开即停。
/// 用 DragGesture 统一处理点按与长按，避免 SwiftUI 手势竞争双触发。
private struct RepeatDeleteButton: View {
    let action: () -> Void

    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(uiColor: .systemGray3))
                .shadow(color: .black.opacity(0.28), radius: 0, x: 0, y: 1)
            Image(systemName: "delete.left")
                .font(.system(size: 19))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 52)
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
