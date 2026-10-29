import SwiftUI
import AICore
import KeyboardKit

/// 工具栏上的「译」键：把光标前最后一句中文就地翻成学习语言，**替换**原文。
///
/// 和自动译文卡片的分工：
/// - 卡片是「你还在打字」时的提示，不动文档；
/// - 这个键是「打完了，翻掉它」，一次点击直接改写。
///
/// 没有可用凭据时置灰，点一下弹一句人话提示，不再静默无反应。
struct TranslateToolbarButton: View {
    weak var controller: KeyboardViewController?

    @State private var isWorking = false
    @State private var hint: String?

    private var isReady: Bool { SharedAIConfig.isConfigured }

    var body: some View {
        Button {
            Task { await translate() }
        } label: {
            Group {
                if isWorking {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "character.bubble")
                        .font(.system(size: 15, weight: .medium))
                }
            }
            .foregroundStyle(isReady ? .primary : .secondary)
            .frame(width: 30, height: 30)
            .background {
                Circle()
                    .fill(Color.secondary.opacity(isReady ? 0.22 : 0.10))
            }
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
        .opacity(isReady ? 1 : 0.5)
        .accessibilityLabel("翻译光标前一句")
        .overlay(alignment: .bottom) {
            if let hint {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: 220)
                    .offset(y: 34)
                    .transition(.opacity)
            }
        }
    }

    private func translate() async {
        guard isReady else {
            hint = SharedAIConfig.unavailableHint
            HapticManager.error()
            Task {
                try? await Task.sleep(for: .seconds(3))
                hint = nil
            }
            return
        }
        guard let proxy = controller?.textDocumentProxy,
              let context = proxy.documentContextBeforeInput,
              let sentence = lastSentence(in: context) else {
            HapticManager.error()
            return
        }

        isWorking = true
        defer { isWorking = false }

        guard let translated = await SentenceTranslator.shared.translate(sentence) else {
            HapticManager.error()
            return
        }

        // 整句替换：删掉原句的每个字，再插译文。
        // 不用 selectedText——键盘里通常没有选区，且各宿主行为不一致。
        for _ in sentence {
            proxy.deleteBackward()
        }
        proxy.insertText(translated)
        HapticManager.lightImpact()
    }

    /// 光标前那段里最后一个句子：中文按 。！？ 切，落在换行上也切。
    private func lastSentence(in context: String) -> String? {
        let separators: Set<Character> = ["。", "！", "？", "!", "?", ".", "\n"]
        var buffer = ""
        for character in context.reversed() {
            if separators.contains(character) {
                if !buffer.isEmpty { break }
                continue
            }
            buffer.append(character)
        }
        let sentence = String(buffer.reversed()).trimmingCharacters(in: .whitespacesAndNewlines)
        return sentence.count >= 2 ? sentence : nil
    }
}
