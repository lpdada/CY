import SwiftUI

/// Saved self-hosted translation sessions, newest first. Tap a row to
/// open the full bilingual record, summarize it, export it, or share it.
struct TranslationHistoryView: View {
    let aiService: AIService

    @Environment(\.dismiss) private var dismiss
    @State private var store = TranslationSessionStore()

    var body: some View {
        NavigationStack {
            Group {
                if store.records.isEmpty {
                    Text("暂无保存的翻译记录")
                        .foregroundStyle(.secondary)
                } else {
                    List {
                        ForEach(store.records) { record in
                            NavigationLink {
                                TranslationRecordDetailView(record: record, store: store, aiService: aiService)
                            } label: {
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
                        }
                        .onDelete { indexSet in
                            for index in indexSet {
                                store.delete(store.records[index])
                            }
                        }
                    }
                }
            }
            .navigationTitle("翻译记录")
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
