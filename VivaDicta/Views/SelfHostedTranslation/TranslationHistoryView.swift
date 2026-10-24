import SwiftUI

/// Saved self-hosted translation sessions, newest first. Tap a row to
/// open the full bilingual record, summarize it, export it, or share it.
/// "选择" enters multi-select mode: check rows, then batch-delete,
/// batch-export (one merged document) or run one summary over the
/// selection.
struct TranslationHistoryView: View {
    let aiService: AIService

    @Environment(\.dismiss) private var dismiss
    @State private var store = TranslationSessionStore()
    @State private var isSelecting = false
    @State private var selection: Set<UUID> = []
    @State private var showDeleteConfirm = false
    @State private var exportError = ""
    @State private var isSharing = false
    @State private var shareItems: [Any] = []
    @State private var showBatchSummary = false

    private var selectedRecords: [TranslationSessionRecord] {
        store.records.filter { selection.contains($0.id) }
    }

    private var allSelected: Bool {
        !store.records.isEmpty && selection.count == store.records.count
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.records.isEmpty {
                    Text("暂无保存的翻译记录")
                        .foregroundStyle(.secondary)
                } else {
                    List {
                        ForEach(store.records) { record in
                            if isSelecting {
                                Button {
                                    toggleSelection(record)
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: selection.contains(record.id) ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(selection.contains(record.id) ? .blue : .secondary)
                                        TranslationHistoryRowContent(record: record)
                                    }
                                }
                                .buttonStyle(.plain)
                            } else {
                                NavigationLink {
                                    TranslationRecordDetailView(record: record, store: store, aiService: aiService)
                                } label: {
                                    TranslationHistoryRowContent(record: record)
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
                }
            }
            .navigationTitle("翻译记录")
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
                BatchSummarySheet(title: "多条翻译记录总结", showLanguagePicker: false) { _ in
                    try await TranslationSummarizer.summarize(records: selectedRecords, aiService: aiService)
                }
            }
            .onAppear {
                store.load()
            }
        }
    }

    private func toggleSelection(_ record: TranslationSessionRecord) {
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

    private func shareBatch(format: TranslationSessionExporter.Format) {
        do {
            let url = try TranslationSessionExporter.fileURL(for: selectedRecords, format: format)
            shareItems = [url]
            isSharing = true
        } catch {
            exportError = "导出失败：\(error.localizedDescription)"
        }
    }
}

private struct TranslationHistoryRowContent: View {
    let record: TranslationSessionRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(record.startedAt.formatted(date: .abbreviated, time: .shortened))
            Text("\(languageName(record.sourceLanguage)) → \(languageName(record.targetLanguage)) · \(record.asrModelName) · \(record.pairs.count) 句")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if record.summary != nil {
                Text("已有总结")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func languageName(_ rawValue: String) -> String {
        SelfHostedTranslationSession.Language(rawValue: rawValue)?.displayName ?? rawValue
    }
}

private struct TranslationRecordDetailView: View {
    @State var record: TranslationSessionRecord
    let store: TranslationSessionStore
    let aiService: AIService

    @Environment(\.dismiss) private var dismiss
    @State private var isSummarizing = false
    @State private var summaryError = ""
    @State private var isSharing = false
    @State private var shareItems: [Any] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.headline)
                    Text("\(languageName(record.sourceLanguage)) → \(languageName(record.targetLanguage)) · \(record.asrModelName)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let summary = record.summary {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("总结")
                            .font(.headline)
                        SummarySectionsView(text: summary)
                    }
                }
                if isSummarizing {
                    HStack(spacing: 6) {
                        ProgressView()
                        Text("总结中…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                if !summaryError.isEmpty {
                    Text(summaryError)
                        .foregroundStyle(.red)
                }
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(record.pairs) { pair in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(pair.original)
                                .foregroundStyle(.secondary)
                            if let translation = pair.translation {
                                Text(translation)
                            } else {
                                Text("（未翻译）")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                HStack(spacing: 12) {
                    Button("总结") {
                        Task { await summarize() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isSummarizing)
                    Menu("分享") {
                        Button("导出 TXT") { share(format: .txt) }
                        Button("导出 PDF") { share(format: .pdf) }
                        Button("导出 HTML") { share(format: .html) }
                    }
                    .buttonStyle(.bordered)
                    Button("删除", role: .destructive) {
                        store.delete(record)
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
        }
        .navigationTitle("记录详情")
        .sheet(isPresented: $isSharing) {
            ActivityView(activityItems: shareItems)
        }
    }

    private func summarize() async {
        guard !isSummarizing else { return }
        isSummarizing = true
        summaryError = ""
        defer { isSummarizing = false }
        do {
            let summary = try await TranslationSummarizer.summarize(record: record, aiService: aiService)
            record.summary = summary
            store.save(record)
        } catch {
            summaryError = "总结失败：\(error.localizedDescription)"
        }
    }

    private func share(format: TranslationSessionExporter.Format) {
        do {
            let url = try TranslationSessionExporter.fileURL(for: record, format: format)
            shareItems = [url]
            isSharing = true
        } catch {
            summaryError = "导出失败：\(error.localizedDescription)"
        }
    }

    private func languageName(_ rawValue: String) -> String {
        SelfHostedTranslationSession.Language(rawValue: rawValue)?.displayName ?? rawValue
    }
}
