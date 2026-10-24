import Foundation
import Presets

/// One-tap AI summary for a meeting record, shared by the live session
/// view and the saved-record detail view. The summary language is chosen
/// by the user (Japanese / Chinese / English) and the whole summary is
/// written in that language. A = the near speaker (phone holder),
/// B = the far speaker, by the session's volume heuristic.
enum MeetingSummarizer {
    enum Language: String, CaseIterable, Codable {
        case japanese
        case chinese
        case english

        var displayName: String {
            switch self {
            case .japanese: "日语"
            case .chinese: "中文"
            case .english: "英语"
            }
        }

        /// The language name as it appears inside the summary prompt,
        /// so the model writes the entire summary in that language.
        var promptName: String {
            switch self {
            case .japanese: "日语"
            case .chinese: "中文"
            case .english: "英语"
            }
        }

        var presetID: String {
            switch self {
            case .japanese: "selfHostedMeetingSummaryJa"
            case .chinese: "selfHostedMeetingSummaryZh"
            case .english: "selfHostedMeetingSummaryEn"
            }
        }
    }

    static func summarize(
        segments: [MeetingSegmentRecord],
        language: Language,
        aiService: AIService
    ) async throws -> String {
        let body = segments
            .filter { !$0.text.isEmpty }
            .map { "\($0.speaker)：\($0.text)" }
            .joined(separator: "\n")
        let preset = Preset(
            id: language.presetID,
            name: "会议总结",
            icon: "list.clipboard",
            category: "Summary",
            promptInstructions: "你是会议记录的整理助手。以下是一场会议的转写，A 是离手机近的发言人，B 是离手机远的发言人。请完成：1）归纳核心观点与讨论要点；2）给出简明总结；3）列出待办事项（如有）；4）指出并修正明显的转写错误。全文只用\(language.promptName)写，分点陈述，不要复述全部原文。",
            useSystemTemplate: false
        )
        let (text, _) = try await aiService.generateVariation(text: body, preset: preset)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One summary over several records, oldest first. The input is
    /// capped so a long selection cannot blow up the prompt; the cap
    /// note is part of the input, so the model knows it saw a part.
    static func summarize(
        records: [MeetingRecord],
        language: Language,
        aiService: AIService
    ) async throws -> String {
        let ordered = records.sorted { $0.startedAt < $1.startedAt }
        var body = ordered.map { record in
            var lines = ["【\(record.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(record.asrModelName)】"]
            for segment in record.segments where !segment.text.isEmpty {
                lines.append("\(segment.speaker)：\(segment.text)")
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
        if body.count > 10000 {
            body = String(body.prefix(10000)) + "\n（以上为截取的部分内容）"
        }
        let preset = Preset(
            id: "selfHostedMeetingSummaryBatch\(language.rawValue.capitalized)",
            name: "多条会议记录总结",
            icon: "list.clipboard",
            category: "Summary",
            promptInstructions: "你是会议记录的整理助手。以下是多场会议的转写，A 是离手机近的发言人，B 是离手机远的发言人。请完成：1）归纳核心观点与讨论要点；2）给出简明总结；3）列出待办事项（如有）；4）指出并修正明显的转写错误。全文只用\(language.promptName)写，分点陈述，不要复述全部原文。",
            useSystemTemplate: false
        )
        let (text, _) = try await aiService.generateVariation(text: body, preset: preset)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
