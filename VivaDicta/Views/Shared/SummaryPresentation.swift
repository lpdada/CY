import SwiftUI
import UIKit

/// One parsed chunk of an AI summary: an optional numbered section title
/// ("1) 核心观点与讨论要点") followed by paragraphs and bullets.
/// Both the in-app summary view and the HTML/PDF exports render from this
/// single parse, so the three outputs always show the same structure.
struct SummarySection {
    let title: String?
    var blocks: [SummaryBlock]
}

enum SummaryBlock {
    case paragraph(String)
    case bullet(String)
}

enum SummaryParser {
    static func parse(_ text: String) -> [SummarySection] {
        var sections: [SummarySection] = []
        var currentTitle: String?
        var currentBlocks: [SummaryBlock] = []
        func flush() {
            if !currentBlocks.isEmpty || currentTitle != nil {
                sections.append(SummarySection(title: currentTitle, blocks: currentBlocks))
            }
            currentBlocks = []
        }
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if isSectionHeader(line) {
                flush()
                currentTitle = line
            } else if let bullet = bulletText(from: line) {
                currentBlocks.append(.bullet(bullet))
            } else {
                currentBlocks.append(.paragraph(line))
            }
        }
        flush()
        if sections.isEmpty {
            sections.append(SummarySection(title: nil, blocks: []))
        }
        return sections
    }

    /// A numbered section header: "1) …", "1、…", "1. …", "1）…".
    /// Western markers ("." / ")") need a space after, otherwise a decimal
    /// like "1.5倍" would be misread as a header. Section numbers are
    /// single or double digit; a year like "2024. …" is not a header.
    private static func isSectionHeader(_ line: String) -> Bool {
        var index = line.startIndex
        var digitCount = 0
        while index < line.endIndex, line[index].isNumber {
            digitCount += 1
            index = line.index(after: index)
        }
        guard digitCount >= 1, digitCount <= 2, index < line.endIndex else { return false }
        let marker = line[index]
        let afterMarker = line.index(after: index)
        switch marker {
        case "、", "）":
            break
        case ".", ")":
            guard afterMarker < line.endIndex, line[afterMarker] == " " else { return false }
        default:
            return false
        }
        let rest = line[afterMarker...].trimmingCharacters(in: .whitespaces)
        return !rest.isEmpty
    }

    private static func bulletText(from line: String) -> String? {
        for prefix in ["- ", "• ", "* "] where line.hasPrefix(prefix) {
            let rest = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty {
                return rest
            }
        }
        return nil
    }
}

/// The summary as structured sections instead of one wall of text:
/// numbered headings, indented bullets, breathing room between sections.
struct SummarySectionsView: View {
    let text: String

    var body: some View {
        let sections = SummaryParser.parse(text)
        VStack(alignment: .leading, spacing: 16) {
            ForEach(sections.indices, id: \.self) { sectionIndex in
                let section = sections[sectionIndex]
                VStack(alignment: .leading, spacing: 8) {
                    if let title = section.title {
                        Text(title)
                            .font(.headline)
                    }
                    ForEach(section.blocks.indices, id: \.self) { blockIndex in
                        switch section.blocks[blockIndex] {
                        case .paragraph(let content):
                            Text(content)
                        case .bullet(let content):
                            HStack(alignment: .top, spacing: 8) {
                                Text("•")
                                Text(content)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Builds the standalone single-file HTML page shared by the HTML export
/// and the PDF export (the PDF is a print of this page, so both outputs
/// look identical). No external resources: inline CSS only, UTF-8, so the
/// file opens correctly in any browser after sharing.
enum RecordHTMLBuilder {
    static func meetingHTML(record: MeetingRecord) -> String {
        var body = "<h1>会议记录</h1>"
        body += "<p class=\"meta\">\(escape(record.startedAt.formatted(date: .abbreviated, time: .shortened))) · \(escape(record.asrModelName))</p>"
        if let summary = record.summary, !summary.isEmpty {
            body += "<section class=\"summary\"><div class=\"summary-title\">总结</div>"
            body += summaryHTML(summary)
            body += "</section>"
        }
        body += "<h2>内容</h2>"
        for segment in record.segments {
            let speakerClass = segment.speaker == "A" ? "speaker-a" : "speaker-b"
            body += "<div class=\"segment\"><span class=\"speaker \(speakerClass)\">\(escape(segment.speaker))</span><p>\(escape(segment.text))</p></div>"
        }
        return pageHTML(title: "会议记录", body: body)
    }

    static func translationHTML(record: TranslationSessionRecord) -> String {
        var body = "<h1>自建翻译记录</h1>"
        body += "<p class=\"meta\">\(escape(record.startedAt.formatted(date: .abbreviated, time: .shortened))) · \(escape(languageName(record.sourceLanguage))) → \(escape(languageName(record.targetLanguage))) · \(escape(record.asrModelName))</p>"
        if let summary = record.summary, !summary.isEmpty {
            body += "<section class=\"summary\"><div class=\"summary-title\">总结</div>"
            body += summaryHTML(summary)
            body += "</section>"
        }
        body += "<h2>内容</h2>"
        for pair in record.pairs {
            body += "<div class=\"pair\"><p class=\"original\">\(escape(pair.original))</p>"
            if let translation = pair.translation, !translation.isEmpty {
                body += "<p class=\"translation\">\(escape(translation))</p>"
            } else {
                body += "<p class=\"translation missing\">（未翻译）</p>"
            }
            body += "</div>"
        }
        return pageHTML(title: "自建翻译记录", body: body)
    }

    private static func summaryHTML(_ summary: String) -> String {
        var html = ""
        for section in SummaryParser.parse(summary) {
            if let title = section.title {
                html += "<h2>\(escape(title))</h2>"
            }
            var bullets: [String] = []
            for block in section.blocks {
                switch block {
                case .paragraph(let content):
                    if !bullets.isEmpty {
                        html += "<ul>" + bullets.joined() + "</ul>"
                        bullets = []
                    }
                    html += "<p>\(escape(content))</p>"
                case .bullet(let content):
                    bullets.append("<li>\(escape(content))</li>")
                }
            }
            if !bullets.isEmpty {
                html += "<ul>" + bullets.joined() + "</ul>"
            }
        }
        return html
    }

    private static func pageHTML(title: String, body: String) -> String {
        """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <style>
        body { font-family: -apple-system, "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", sans-serif; max-width: 720px; margin: 0 auto; padding: 24px 16px; color: #1d1d1f; line-height: 1.7; }
        h1 { font-size: 24px; margin: 0 0 4px; }
        h2 { font-size: 17px; margin: 24px 0 8px; }
        .meta { color: #86868b; font-size: 14px; margin: 0 0 16px; }
        .summary { background: #f5f5f7; border-radius: 12px; padding: 16px 20px; }
        .summary h2 { margin-top: 16px; }
        .summary h2:first-of-type { margin-top: 0; }
        .summary-title { font-size: 18px; font-weight: 700; margin-bottom: 4px; }
        .segment { display: flex; gap: 10px; margin: 12px 0; }
        .segment p { margin: 0; }
        .speaker { flex-shrink: 0; width: 22px; height: 22px; line-height: 22px; text-align: center; border-radius: 50%; color: #fff; font-size: 12px; font-weight: 700; }
        .speaker-a { background: #007aff; }
        .speaker-b { background: #ff9500; }
        .pair { margin: 14px 0; }
        .pair p { margin: 2px 0; }
        .pair .original { color: #86868b; }
        .pair .translation.missing { color: #86868b; }
        @media (prefers-color-scheme: dark) {
          body { background: #000; color: #f5f5f7; }
          .summary { background: #1c1c1e; }
          .meta, .pair .original, .pair .translation.missing { color: #98989d; }
        }
        </style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    private static func languageName(_ rawValue: String) -> String {
        SelfHostedTranslationSession.Language(rawValue: rawValue)?.displayName ?? rawValue
    }

    private static func escape(_ string: String) -> String {
        var result = ""
        for char in string {
            switch char {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            default: result.append(char)
            }
        }
        return result
    }
}

/// Prints a record's HTML page to PDF. This replaces the old line-by-line
/// PDF renderer, whose output came out blank for CJK content: WebKit
/// handles CJK fonts, so the PDF shows the same text as the HTML page.
/// Runs on the main thread (all share actions do).
enum RecordPDFPrinter {
    static func pdfData(html: String) -> Data {
        let printRenderer = RecordPrintRenderer()
        printRenderer.addPrintFormatter(UIMarkupTextPrintFormatter(markupText: html), startingAtPageAt: 0)
        let pageRect = printRenderer.paperRect
        return UIGraphicsPDFRenderer(bounds: pageRect).pdfData { context in
            for pageIndex in 0..<printRenderer.numberOfPages {
                context.beginPage()
                // Draws into the PDF context that UIGraphicsPDFRenderer
                // makes current inside this closure.
                printRenderer.drawPage(at: pageIndex, in: printRenderer.printableRect)
            }
        }
    }

    private final class RecordPrintRenderer: UIPrintPageRenderer {
        // UIPrintPageRenderer is MainActor-inferred in Swift 6, but these
        // geometry members are nonisolated in the base class: the overrides
        // (and the initializer) must say so explicitly, or the build fails
        // with an actor-isolation mismatch.
        override nonisolated var paperRect: CGRect { CGRect(x: 0, y: 0, width: 595.2, height: 841.8) }
        override nonisolated var printableRect: CGRect { paperRect.insetBy(dx: 48, dy: 48) }
        override nonisolated init() { super.init() }
    }
}
