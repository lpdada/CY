import AVFoundation
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
    @State private var player = MeetingAudioPlayer()
    @State private var isPolishing = false
    @State private var polishDone = 0
    @State private var polishTotal = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(record.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.headline)
                    .foregroundStyle(.secondary)
                if let audioURL = store.audioURL(for: record) {
                    MeetingAudioPlayerCard(player: player, url: audioURL)
                }
                ForEach(record.segments) { segment in
                    HStack(alignment: .top, spacing: 8) {
                        Text(segment.speaker)
                            .font(.footnote)
                            .bold()
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(segment.speaker == "A" ? Color.blue : Color.orange)
                            .clipShape(Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text(segment.text)
                            if let raw = segment.rawText, !raw.isEmpty {
                                (Text("原文 · ").foregroundStyle(.tertiary)
                                 + Text(raw).foregroundStyle(.secondary))
                                    .font(.caption)
                            }
                        }
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
                if isPolishing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(polishTotal > 0 ? "润色中 \(polishDone)/\(polishTotal)" : "润色中…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else if !status.isEmpty {
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
                HStack(spacing: 10) {
                    Button("润色") {
                        Task { await polish() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(record.segments.isEmpty || isPolishing || isSummarizing)
                    if hasOriginal {
                        Button("还原原文") {
                            restoreOriginal()
                        }
                        .buttonStyle(.bordered)
                        .disabled(isPolishing || isSummarizing)
                    }
                    Button("总结") {
                        Task { await summarize() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(record.segments.isEmpty || isSummarizing || isPolishing)
                    Menu("分享") {
                        Button("导出 TXT") { share(format: .txt) }
                        Button("导出 PDF") { share(format: .pdf) }
                        Button("导出 HTML") { share(format: .html) }
                        if store.audioURL(for: record) != nil {
                            Divider()
                            Button("分享录音（WAV）") { shareAudio() }
                        }
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

    private var hasOriginal: Bool {
        record.segments.contains { ($0.rawText?.isEmpty == false) }
    }

    private var summaryLanguageName: String {
        MeetingSummarizer.Language(rawValue: record.summaryLanguage ?? "")?.displayName
            ?? (record.summaryLanguage ?? "")
    }

    /// 对已保存的记录整场润色：分批请求，逐段回填，原文存进 rawText。
    private func polish() async {
        guard !isPolishing, !isSummarizing else { return }
        isPolishing = true
        polishDone = 0
        polishTotal = record.segments.count
        defer {
            isPolishing = false
            polishTotal = 0
        }
        let outcome = await MeetingTextPolisher.polish(
            record.segments.map(\.text),
            aiService: aiService,
            onProgress: { done, total in
                self.polishDone = done
                self.polishTotal = total
            }
        )
        for (index, segment) in record.segments.enumerated() {
            guard let polished = outcome.polished[index], polished != segment.text else { continue }
            record.segments[index].rawText = segment.rawText ?? segment.text
            record.segments[index].text = polished
        }
        if store.save(record) {
            status = outcome.failed == 0
                ? "已润色 \(outcome.polished.count) 段（\(outcome.requests) 次请求）"
                : "润色完成，\(outcome.failed) 段保留原文"
        } else {
            status = "润色已生成，保存失败"
        }
    }

    private func restoreOriginal() {
        for index in record.segments.indices {
            if let raw = record.segments[index].rawText {
                record.segments[index].text = raw
                record.segments[index].rawText = nil
            }
        }
        status = store.save(record) ? "已还原原文" : "还原失败"
    }

    private func shareAudio() {
        guard let url = store.audioURL(for: record) else {
            status = "这条记录没有录音"
            return
        }
        shareItems = [url]
        isSharing = true
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


// MARK: - 历史详情里的整场录音

/// Plays one saved meeting WAV. Kept next to the detail view so the
/// history screen stays a single file: no second recorder, no second
/// store, just a player over `Documents/MeetingNotes/<id>.wav`.
@MainActor
@Observable
final class MeetingAudioPlayer {
    private(set) var isPlaying = false
    private(set) var time: TimeInterval = 0
    private(set) var duration: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var ticker: Task<Void, Never>?
    private var loadedURL: URL?

    func load(_ url: URL) {
        guard loadedURL != url else { return }
        stop()
        loadedURL = url
        player = try? AVAudioPlayer(contentsOf: url)
        player?.prepareToPlay()
        duration = player?.duration ?? 0
        time = 0
    }

    func toggle() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            ticker?.cancel()
            ticker = nil
            isPlaying = false
            return
        }
        // 录音/别的页面可能把 session 留在 playAndRecord，切到 playback 才出声。
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.duckOthers])
        try? session.setActive(true)
        if player.currentTime >= player.duration - 0.05 {
            player.currentTime = 0
        }
        player.play()
        isPlaying = true
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, let player = self.player, player.isPlaying else { return }
                self.time = player.currentTime
            }
        }
    }

    func seek(to value: TimeInterval) {
        guard let player else { return }
        let clamped = min(max(0, value), max(0, duration))
        player.currentTime = clamped
        time = clamped
    }

    func stop() {
        player?.stop()
        player = nil
        loadedURL = nil
        ticker?.cancel()
        ticker = nil
        isPlaying = false
        time = 0
    }
}

/// Peak envelope of a WAV, used as the static waveform in history.
/// Read off the main actor: a 30-minute file is ~57 MB of Int16.
enum MeetingAudioWaveform {
    static func peaks(url: URL, buckets: Int = 64) async -> [Float] {
        await Task.detached(priority: .utility) { () -> [Float] in
            guard let file = try? AVAudioFile(forReading: url), file.length > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                frameCapacity: 4096)
            else { return [] }
            let total = Int(file.length)
            let perBucket = max(1, total / buckets)
            var peaks = [Float](repeating: 0, count: buckets)
            var index = 0
            while index < total {
                let want = AVAudioFrameCount(min(4096, total - index))
                do {
                    try file.read(into: buffer, frameCount: want)
                } catch {
                    break
                }
                let frames = Int(buffer.frameLength)
                guard frames > 0, let samples = buffer.floatChannelData?[0] else { break }
                for frame in 0..<frames {
                    let bucket = min(buckets - 1, (index + frame) / perBucket)
                    peaks[bucket] = max(peaks[bucket], abs(samples[frame]))
                }
                index += frames
            }
            let loudest = peaks.max() ?? 0
            if loudest > 0 {
                peaks = peaks.map { $0 / loudest }
            }
            return peaks
        }.value
    }
}

private struct MeetingAudioPlayerCard: View {
    let player: MeetingAudioPlayer
    let url: URL

    @State private var peaks: [Float] = []

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Button {
                    player.toggle()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color(.tertiarySystemFill)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.isPlaying ? "暂停录音" : "播放录音")

                waveform

                Text(timeLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }

            Slider(
                value: Binding(
                    get: { player.time },
                    set: { player.seek(to: $0) }
                ),
                in: 0...max(player.duration, 0.1)
            )
            .controlSize(.mini)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .task {
            player.load(url)
            peaks = await MeetingAudioWaveform.peaks(url: url)
        }
        .onDisappear {
            player.stop()
        }
    }

    private var waveform: some View {
        GeometryReader { geometry in
            let count = max(peaks.count, 1)
            let width = max(1.5, (geometry.size.width - CGFloat(count - 1) * 1.5) / CGFloat(count))
            HStack(alignment: .center, spacing: 1.5) {
                ForEach(Array(peaks.enumerated()), id: \.offset) { _, peak in
                    Capsule()
                        .fill(Color.accentColor.opacity(0.55))
                        .frame(width: width,
                               height: max(2, CGFloat(peak) * geometry.size.height))
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(height: 24)
    }

    private var timeLabel: String {
        guard player.duration > 0 else { return "" }
        return "\(Self.format(player.time)) / \(Self.format(player.duration))"
    }

    private static func format(_ time: TimeInterval) -> String {
        let total = Int(time.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
