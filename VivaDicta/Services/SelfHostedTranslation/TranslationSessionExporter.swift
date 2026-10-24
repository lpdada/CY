import Foundation

/// Turns a saved translation record into a shareable file: plain TXT,
/// a PDF (a print of the HTML page), or the standalone HTML page itself.
enum TranslationSessionExporter {
    enum Format {
        case txt
        case pdf
        case html

        var fileExtension: String {
            switch self {
            case .txt: "txt"
            case .pdf: "pdf"
            case .html: "html"
            }
        }

        var displayName: String {
            switch self {
            case .txt: "TXT"
            case .pdf: "PDF"
            case .html: "HTML"
            }
        }
    }

    static func text(for record: TranslationSessionRecord) -> String {
        var lines: [String] = []
        lines.append("自建翻译记录")
        lines.append("时间：\(record.startedAt.formatted(date: .abbreviated, time: .shortened))")
        lines.append("语言：\(languageName(record.sourceLanguage)) → \(languageName(record.targetLanguage))")
        lines.append("转写模型：\(record.asrModelName)")
        lines.append("")
        for (index, pair) in record.pairs.enumerated() {
            lines.append("\(index + 1). 原文：\(pair.original)")
            if let translation = pair.translation, !translation.isEmpty {
                lines.append("   译文：\(translation)")
            } else {
                lines.append("   译文：（未翻译）")
            }
        }
        if let summary = record.summary, !summary.isEmpty {
            lines.append("")
            lines.append("总结：")
            lines.append(summary)
        }
        return lines.joined(separator: "\n")
    }

    static func fileURL(for record: TranslationSessionRecord, format: Format) throws -> URL {
        let data: Data
        switch format {
        case .txt:
            data = Data(text(for: record).utf8)
        case .pdf:
            data = RecordPDFPrinter.pdfData(html: RecordHTMLBuilder.translationHTML(record: record))
        case .html:
            data = Data(RecordHTMLBuilder.translationHTML(record: record).utf8)
        }
        let url = FileManager.default.temporaryDirectory
            .appending(path: "translation-record-\(record.id.uuidString).\(format.fileExtension)")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Several records merged into one document, oldest first. The UI
    /// only offers this with a non-empty selection; an empty list still
    /// yields a header-only file rather than a crash.
    static func fileURL(for records: [TranslationSessionRecord], format: Format) throws -> URL {
        let ordered = records.sorted { $0.startedAt < $1.startedAt }
        let data: Data
        switch format {
        case .txt:
            var lines = ["自建翻译记录（合并导出，共 \(ordered.count) 条）", ""]
            lines.append(ordered.map { text(for: $0) }.joined(separator: "\n\n----------\n\n"))
            data = Data(lines.joined(separator: "\n").utf8)
        case .pdf:
            data = RecordPDFPrinter.pdfData(html: RecordHTMLBuilder.combinedTranslationHTML(records: ordered))
        case .html:
            data = Data(RecordHTMLBuilder.combinedTranslationHTML(records: ordered).utf8)
        }
        let url = FileManager.default.temporaryDirectory
            .appending(path: "translation-records-combined.\(format.fileExtension)")
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func languageName(_ rawValue: String) -> String {
        SelfHostedTranslationSession.Language(rawValue: rawValue)?.displayName ?? rawValue
    }
}
