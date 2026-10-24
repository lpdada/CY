import SwiftUI

/// One-off AI summary over several selected records. The result is shown
/// here only; it is not written back to any record. The caller supplies
/// the summary work (the language argument is ignored by callers that
/// have no language choice); the sheet owns progress, error, display
/// and sharing. The summary starts automatically when the sheet opens;
/// the button re-runs it, e.g. after an error or a language change.
struct BatchSummarySheet: View {
    let title: String
    let showLanguagePicker: Bool
    let summarize: (MeetingSummarizer.Language) async throws -> String

    @Environment(\.dismiss) private var dismiss
    @State private var language: MeetingSummarizer.Language = .chinese
    @State private var isSummarizing = false
    @State private var summary = ""
    @State private var errorMessage = ""
    @State private var isSharing = false
    @State private var shareItems: [Any] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if showLanguagePicker {
                        Picker("总结语言", selection: $language) {
                            ForEach(MeetingSummarizer.Language.allCases, id: \.self) { language in
                                Text(language.displayName).tag(language)
                            }
                        }
                        .pickerStyle(.segmented)
                        .disabled(isSummarizing)
                    }
                    Button("总结分析") {
                        Task { await run() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isSummarizing)
                    if isSummarizing {
                        HStack(spacing: 6) {
                            ProgressView()
                            Text("总结中…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !errorMessage.isEmpty {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                    if !summary.isEmpty {
                        SummarySectionsView(text: summary)
                        Text("本次总结仅在此展示，不保存到记录。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("分享总结") {
                            share()
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .sheet(isPresented: $isSharing) {
                ActivityView(activityItems: shareItems)
            }
            .task {
                await run()
            }
            .onChange(of: language) { _, _ in
                summary = ""
                errorMessage = ""
            }
        }
    }

    private func run() async {
        guard !isSummarizing else { return }
        isSummarizing = true
        errorMessage = ""
        defer { isSummarizing = false }
        do {
            summary = try await summarize(language)
        } catch {
            errorMessage = "总结失败：\(error.localizedDescription)"
        }
    }

    private func share() {
        let url = FileManager.default.temporaryDirectory.appending(path: "batch-summary.txt")
        do {
            try Data(summary.utf8).write(to: url, options: .atomic)
            shareItems = [url]
            isSharing = true
        } catch {
            errorMessage = "导出失败：\(error.localizedDescription)"
        }
    }
}
