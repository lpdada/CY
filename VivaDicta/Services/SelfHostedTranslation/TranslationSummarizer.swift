import Foundation
import Presets

/// One-tap AI summary for a translation record, shared by the live
/// session view and the saved-record detail view. It distills the key
/// points, gives a short summary, and points out and fixes obvious
/// transcription or translation mistakes in the record.
enum TranslationSummarizer {
    static func summarize(record: TranslationSessionRecord, aiService: AIService) async throws -> String {
        let body = record.pairs
            .filter { !$0.original.isEmpty }
            .map { pair in
                if let source = pair.sourceLanguage, let target = pair.targetLanguage,
                   let sourceName = SelfHostedTranslationSession.Language(rawValue: source)?.displayName,
                   let targetName = SelfHostedTranslationSession.Language(rawValue: target)?.displayName {
                    if let translation = pair.translation, !translation.isEmpty {
                        return "原文（\(sourceName)）：\(pair.original)\n译文（\(targetName)）：\(translation)"
                    }
                    return "原文（\(sourceName)）：\(pair.original)\n译文：（未翻译）"
                }
                if let translation = pair.translation, !translation.isEmpty {
                    return "原文：\(pair.original)\n译文：\(translation)"
                }
                return "原文：\(pair.original)\n译文：（未翻译）"
            }
            .joined(separator: "\n\n")
        let preset = Preset(
            id: "selfHostedTranslationSummary",
            name: "翻译总结",
            icon: "doc.text",
            category: "Summary",
            promptInstructions: "你是翻译记录的整理助手。请基于以下双语记录完成三件事：1）归纳核心观点；2）给出简明总结；3）指出并修正记录中明显的转写或翻译错误。输出用与记录相同的语言，分点陈述，不要复述全部原文。",
            useSystemTemplate: false
        )
        let (text, _) = try await aiService.generateVariation(text: body, preset: preset)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One summary over several records, oldest first. The input is
    /// capped so a long selection cannot blow up the prompt; the cap
    /// note is part of the input, so the model knows it saw a part.
    static func summarize(records: [TranslationSessionRecord], aiService: AIService) async throws -> String {
        let ordered = records.sorted { $0.startedAt < $1.startedAt }
        var body = ordered.map { record in
            var lines = ["【\(record.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(record.asrModelName)】"]
            for pair in record.pairs where !pair.original.isEmpty {
                if let translation = pair.translation, !translation.isEmpty {
                    lines.append("原文：\(pair.original)\n译文：\(translation)")
                } else {
                    lines.append("原文：\(pair.original)\n译文：（未翻译）")
                }
            }
            return lines.joined(separator: "\n\n")
        }.joined(separator: "\n\n")
        if body.count > 10000 {
            body = String(body.prefix(10000)) + "\n（以上为截取的部分内容）"
        }
        let preset = Preset(
            id: "selfHostedTranslationSummaryBatch",
            name: "多条翻译记录总结",
            icon: "doc.text",
            category: "Summary",
            promptInstructions: "你是翻译记录的整理助手。请基于以下多条双语记录完成三件事：1）归纳核心观点；2）给出简明总结；3）指出并修正记录中明显的转写或翻译错误。输出用与记录相同的语言，分点陈述，不要复述全部原文。",
            useSystemTemplate: false
        )
        let (text, _) = try await aiService.generateVariation(text: body, preset: preset)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
