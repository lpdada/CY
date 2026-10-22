import Foundation
import UIKit

/// Turns a saved translation record into a shareable file: plain TXT
/// or a paginated PDF rendered with the system font (CJK included).
enum TranslationSessionExporter {
    enum Format {
        case txt
        case pdf

        var fileExtension: String {
            switch self {
            case .txt: "txt"
            case .pdf: "pdf"
            }
        }

        var displayName: String {
            switch self {
            case .txt: "TXT"
            case .pdf: "PDF"
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
            data = pdfData(for: record)
        }
        let url = FileManager.default.temporaryDirectory
            .appending(path: "translation-record-\(record.id.uuidString).\(format.fileExtension)")
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func languageName(_ rawValue: String) -> String {
        SelfHostedTranslationSession.Language(rawValue: rawValue)?.displayName ?? rawValue
    }

    private static func pdfData(for record: TranslationSessionRecord) -> Data {
        let pageRect = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)
        let margin: CGFloat = 48
        let contentWidth = pageRect.width - margin * 2
        let maxY = pageRect.height - margin
        let font = UIFont.systemFont(ofSize: 14)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraphStyle,
        ]
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        return renderer.pdfData { context in
            var y = margin
            context.beginPage()
            for paragraph in text(for: record).components(separatedBy: "\n") {
                if paragraph.isEmpty {
                    y += 8
                    continue
                }
                let height = (paragraph as NSString).boundingRect(
                    with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: attributes,
                    context: nil
                ).height.rounded(.up)
                if y + height > maxY {
                    context.beginPage()
                    y = margin
                }
                (paragraph as NSString).draw(
                    in: CGRect(x: margin, y: y, width: contentWidth, height: height),
                    withAttributes: attributes
                )
                y += height + 4
            }
        }
    }
}
