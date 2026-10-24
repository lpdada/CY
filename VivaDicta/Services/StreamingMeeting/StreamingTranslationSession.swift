import Foundation
import os
import Presets

/// Minimal streaming translation for streaming meetings: a final ASR
/// segment arrives, and its translation streams out through
/// `AIService.generateVariation` as partial results arrive.
///
/// Scope limits, by design:
/// - Finals only. `handleFinalSegment` refuses provisional segments
///   (and empty text) outright; the meeting session also only forwards
///   finals, so an interim line can never start a translation.
/// - One translation per segment id, updated in place. A corrected
///   final for the same id re-runs translation for that id; partial
///   and final results are applied only while the segment's original
///   still equals the text being translated, so a stale run cannot
///   overwrite a newer correction.
/// - No TTS, no summary, no persistence here: the translated text lives
///   in `segments` for the view to show under the original. Saving a
///   translation still goes through the meeting record's own path.
///
/// Verified signature (AIService.swift): the task text quoted
/// `generateVariation(text:preset:onPartialResult:)`; the real method
/// is `generateVariation(text:preset:modeOverride:onPartialResult:)`
/// with `modeOverride` defaulted, so the three-label call below
/// compiles, and `onPartialResult` is `@MainActor (String) -> Void`.
/// When the active provider does not support response streaming,
/// `onPartialResult` simply never fires and only the returned tuple
/// is used — the code handles both shapes.
@MainActor
@Observable
final class StreamingTranslationSession {
    struct TranslatedSegment: Identifiable {
        /// Mirrors the meeting segment's `segment_id`.
        let segmentID: String
        var id: String { segmentID }
        var original: String
        var translation: String
        var isTranslating: Bool
        var error: String?
    }

    enum Language: String, CaseIterable {
        case chinese = "zh"
        case japanese = "ja"
        case english = "en"
        /// Automatic source: the prompt carries no source language
        /// and the AI detects it per segment. Never a translation
        /// target; the target picker lists only the three real
        /// languages.
        case automatic = "auto"

        var displayName: String {
            switch self {
            case .chinese: "中文"
            case .japanese: "日语"
            case .english: "英语"
            case .automatic: "自动"
            }
        }

        var translationName: String {
            switch self {
            case .chinese: "Chinese"
            case .japanese: "Japanese"
            case .english: "English"
            // Never read: the automatic branch builds its prompt
            // without a source name (see translationPreset).
            case .automatic: ""
            }
        }
    }

    var sourceLanguage: Language = .chinese
    var targetLanguage: Language = .japanese
    /// Master switch, on by default to preserve the previous
    /// always-on behavior. While off, no translation runs and the
    /// view hides existing translations; switching back on
    /// backfills finals that have none yet.
    var isEnabled = true
    var segments: [TranslatedSegment] = []

    private let aiService: AIService
    private let logger = Logger(category: .selfHostedTranslation)

    init(aiService: AIService) {
        self.aiService = aiService
    }

    func translation(for segmentID: String) -> TranslatedSegment? {
        segments.first { $0.segmentID == segmentID }
    }

    func reset() {
        segments = []
    }

    /// Translates one FINAL meeting segment. Provisional segments and
    /// empty text are ignored, never translated.
    func handleFinalSegment(_ segment: StreamingMeetingSession.Segment) async {
        guard isEnabled else { return }
        guard !segment.isProvisional else { return }
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if let index = segments.firstIndex(where: { $0.segmentID == segment.segmentID }) {
            segments[index].original = text
            segments[index].translation = ""
            segments[index].isTranslating = true
            segments[index].error = nil
        } else {
            segments.append(TranslatedSegment(
                segmentID: segment.segmentID,
                original: text,
                translation: "",
                isTranslating: true,
                error: nil
            ))
        }

        do {
            let preset = Self.translationPreset(from: sourceLanguage, to: targetLanguage)
            // Partial results update the segment's translation as
            // they arrive; the caller never waits for the full
            // translation to see output. The guard inside keeps a
            // stale run (superseded by a corrected final) from
            // overwriting the newer translation.
            let (translated, _) = try await aiService.generateVariation(
                text: text,
                preset: preset,
                onPartialResult: { [weak self] partial in
                    guard let self,
                          let index = self.segments.firstIndex(where: { $0.segmentID == segment.segmentID }),
                          self.segments[index].original == text
                    else { return }
                    self.segments[index].translation = partial
                }
            )
            guard let index = segments.firstIndex(where: { $0.segmentID == segment.segmentID }),
                  segments[index].original == text
            else { return }
            segments[index].translation = translated.trimmingCharacters(in: .whitespacesAndNewlines)
            segments[index].isTranslating = false
        } catch {
            logger.logError("流式翻译：翻译失败：\(error.localizedDescription)")
            guard let index = segments.firstIndex(where: { $0.segmentID == segment.segmentID }),
                  segments[index].original == text
            else { return }
            segments[index].isTranslating = false
            segments[index].error = "翻译失败：\(error.localizedDescription)"
        }
    }

    /// Same prompt shape as SelfHostedTranslationSession's private
    /// translation preset (that one is not reusable from here), so the
    /// output contract matches the old translation path: translation
    /// only, no explanation, notes, or quotation marks.
    private static func translationPreset(from: Language, to: Language) -> Preset {
        // Automatic source: no "from X" clause, so the AI detects
        // the segment's language itself instead of mistranslating
        // under a wrong fixed source (e.g. kanji-only Japanese read
        // as Chinese by the script heuristic).
        let instruction: String
        if from == .automatic {
            instruction = "Translate the following text to \(to.translationName). Output only the translation, without any explanation, notes, or quotation marks."
        } else {
            instruction = "Translate the following text from \(from.translationName) to \(to.translationName). Output only the translation, without any explanation, notes, or quotation marks."
        }
        return Preset(
            id: "streamingTranslation",
            name: "翻译",
            icon: "translate",
            category: "Translate",
            promptInstructions: instruction,
            useSystemTemplate: false
        )
    }
}
