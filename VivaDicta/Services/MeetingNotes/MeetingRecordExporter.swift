import Foundation

/// Turns a saved meeting record into a shareable file, mirroring the
/// translation exporter: plain TXT, a PDF (a print of the HTML page),
/// or the standalone HTML page itself.
enum MeetingRecordExporter {
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

    static func text(for record: MeetingRecord) -> String {
        var lines: [String] = []
        lines.append("会议记录")
        lines.append("时间：\(record.startedAt.formatted(date: .abbreviated, time: .shortened))")
        lines.append("转写模型：\(record.asrModelName)")
        lines.append("")
        for segment in record.segments {
            lines.append("\(segment.speaker)：\(segment.text)")
        }
        if let summary = record.summary, !summary.isEmpty {
            lines.append("")
            lines.append("总结：")
            lines.append(summary)
        }
        return lines.joined(separator: "\n")
    }

    static func fileURL(for record: MeetingRecord, format: Format) throws -> URL {
        let data: Data
        switch format {
        case .txt:
            data = Data(text(for: record).utf8)
        case .pdf:
            data = RecordPDFPrinter.pdfData(html: RecordHTMLBuilder.meetingHTML(record: record))
        case .html:
            data = Data(RecordHTMLBuilder.meetingHTML(record: record).utf8)
        }
        let url = FileManager.default.temporaryDirectory
            .appending(path: "meeting-record-\(record.id.uuidString).\(format.fileExtension)")
        try data.write(to: url, options: .atomic)
        return url
    }
}
