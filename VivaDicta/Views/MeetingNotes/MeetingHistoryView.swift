import SwiftUI

/// Saved meeting records: newest first, tap for detail, swipe to delete.
/// Detail can re-run the AI summary in another language; it writes back
/// to the same record file. "选择" enters multi-select mode: check rows,
/// then batch-delete, batch-export (one merged document) or run one
/// summary over the selection.
struct MeetingHistoryView: View {
    let aiService: AIService

    @Environment(\.dismiss) private var dismiss
    @State private var store = MeetingRecordStore()
    @State private var isSelecting = false
    @State private var selection: Set<UUID> = []
    @State private var showDeleteConfirm = false
    @State private var exportError = ""
    @State private var isSharing = false
    @State private var shareItems: [Any] = []
    @State private var showBatchSummary = false

    private var selectedRecords: [MeetingRecord] {
        store.records.filter { selection.contains($0.id) }
    }

    private var allSelected: Bool {
        !store.records.isEmpty && selection.count == store.records.count
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.records) { record in
                    if isSelecting {
                        Button {
                            toggleSelection(record)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: selection.contains(record.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selection.contains(record.id) ? .blue : .secondary)
                                MeetingHistoryRowContent(record: record)
                            }
                        }
                        .buttonStyle(.plain)
                    } else {
                        NavigationLink {
                            MeetingRecordDetailView(record: record, aiService: aiService, store: store)
                        } label: {
                            MeetingHistoryRowContent(record: record)
                        }
                    }
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        store.delete(store.records[index])
                    }
                }
                .deleteDisabled(isSelecting)
            }
            .navigationTitle("会议记录历史")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if isSelecting {
                        Button("取消") { exitSelection() }
                    } else {
                        Button("关闭") { dismiss() }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if isSelecting {
                        Button(allSelected ? "取消全选" : "全选") { toggleAll() }
                            .disabled(store.records.isEmpty)
                    } else {
                        Button("选择") { isSelecting = true }
                            .disabled(store.records.isEmpty)
                    }
                }
                if isSelecting {
                    ToolbarItem(placement: .bottomBar) {
                        HStack {
                            Button("删除 (\(selection.count))", role: .destructive) {
                                showDeleteConfirm = true
                            }
                            .disabled(selection.isEmpty)
                            Spacer()
                            Menu("导出") {
                                Button("导出 TXT") { shareBatch(format: .txt) }
                                Button("导出 PDF") { shareBatch(format: .pdf) }
                                Button("导出 HTML") { shareBatch(format: .html) }
                            }
                            .disabled(selection.isEmpty)
                            Button("总结分析") { showBatchSummary = true }
                                .disabled(selection.isEmpty)
                        }
                    }
                }
            }
            .alert("删除 \(selection.count) 条记录？", isPresented: $showDeleteConfirm) {
                Button("删除", role: .destructive) { deleteSelected() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("删除后无法恢复。")
            }
            .alert(
                "导出失败",
                isPresented: Binding(
                    get: { !exportError.isEmpty },
                    set: { if !$0 { exportError = "" } }
                )
            ) {
                Button("好", role: .cancel) {}
            } message: {
                Text(exportError)
            }
            .sheet(isPresented: $isSharing) {
                ActivityView(activityItems: shareItems)
            }
            .sheet(isPresented: $showBatchSummary) {
                BatchSummarySheet(title: "多条会议记录总结", showLanguagePicker: true) { language in
                    try await MeetingSummarizer.summarize(records: selectedRecords, language: language, aiService: aiService)
                }
            }
            .onAppear {
                store.load()
            }
        }
    }

    private func toggleSelection(_ record: MeetingRecord) {
        if selection.contains(record.id) {
            selection.remove(record.id)
        } else {
            selection.insert(record.id)
        }
    }

    private func toggleAll() {
        if allSelected {
            selection.removeAll()
        } else {
            selection = Set(store.records.map(\.id))
        }
    }

    private func exitSelection() {
        isSelecting = false
        selection.removeAll()
    }

    private func deleteSelected() {
        for record in selectedRecords {
            store.delete(record)
        }
        exitSelection()
    }

    private func shareBatch(format: MeetingRecordExporter.Format) {
        do {
            let url = try MeetingRecordExporter.fileURL(for: selectedRecords, format: format)
            shareItems = [url]
            isSharing = true
        } catch {
            exportError = "导出失败：\(error.localizedDescription)"
        }
    }
}

private struct MeetingHistoryRowContent: View {
    let record: MeetingRecord

    var body: some View {
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
