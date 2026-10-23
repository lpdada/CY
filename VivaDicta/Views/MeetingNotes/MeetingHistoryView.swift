import SwiftUI

/// Saved meeting records: newest first, tap for detail, swipe to delete.
/// Detail can re-run the AI summary in another language; it writes back
/// to the same record file.
struct MeetingHistoryView: View {
    let aiService: AIService

    @Environment(\.dismiss) private var dismiss
    @State private var store = MeetingRecordStore()

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.records) { record in
                    NavigationLink {
                        MeetingRecordDetailView(record: record, aiService: aiService, store: store)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.startedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.headline)
                            Text("\(record.segments.count) 段 · \(record.asrModelName)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            if record.summary != nil {
                                Text("已有总结")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        store.delete(store.records[index])
                    }
                }
            }
            .navigationTitle("会议记录历史")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .onAppear {
                store.load()
            }
        }
    }
}

private struct MeetingRecordDetailView: View {
    @State var record: MeetingRecord
    let aiService: AIService
    let store: MeetingRecordStore

    @State private var summaryLanguage: MeetingSummarizer.Language = .chinese
    @State private var isSummarizing = false
    @State private var status = ""
    @State private var isSharing = false
    @State private var shareItems: [Any] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(record.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.headline)
                    .foregroundStyle(.secondary)
                ForEach(record.segments) { segment in
                    HStack(alignment: .top, spacing: 8) {
                        Text(segment.speaker)
                            .font(.footnote)
                            .bold()
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(segment.speaker == "A" ? Color.blue : Color.orange)
                            .clipShape(Circle())
                        Text(segment.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let summary = record.summary {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("总结（\(summaryLanguageName)）")
                            .font(.headline)
                        SummarySectionsView(text: summary)
                    }
                }
                if !status.isEmpty {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Picker("总结语言", selection: $summaryLanguage) {
                    ForEach(MeetingSummarizer.Language.allCases, id: \.self) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(isSummarizing)
                HStack(spacing: 12) {
                    Button("总结") {
                        Task { await summarize() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(record.segments.isEmpty || isSummarizing)
                    Menu("分享") {
                        Button("导出 TXT") { share(format: .txt) }
                        Button("导出 PDF") { share(format: .pdf) }
                        Button("导出 HTML") { share(format: .html) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(record.segments.isEmpty)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("会议详情")
        .sheet(isPresented: $isSharing) {
            ActivityView(activityItems: shareItems)
        }
        .onAppear {
            if let saved = record.summaryLanguage,
               let language = MeetingSummarizer.Language(rawValue: saved) {
                summaryLanguage = language
            }
        }
    }

    private var summaryLanguageName: String {
        MeetingSummarizer.Language(rawValue: record.summaryLanguage ?? "")?.displayName
            ?? (record.summaryLanguage ?? "")
    }

    private func summarize() async {
        guard !isSummarizing else { return }
        isSummarizing = true
        defer { isSummarizing = false }
        do {
            let text = try await MeetingSummarizer.summarize(
                segments: record.segments,
                language: summaryLanguage,
                aiService: aiService
            )
            record.summary = text
            record.summaryLanguage = summaryLanguage.rawValue
            if store.save(record) {
                status = "总结已保存"
            } else {
                status = "总结已生成，保存失败"
            }
        } catch {
            status = "总结失败：\(error.localizedDescription)"
        }
    }

    private func share(format: MeetingRecordExporter.Format) {
        do {
            let url = try MeetingRecordExporter.fileURL(for: record, format: format)
            shareItems = [url]
            isSharing = true
        } catch {
            status = "导出失败：\(error.localizedDescription)"
        }
    }
}
