import Foundation
import os

/// One transcribed meeting segment: who spoke (volume heuristic) and what
/// was said. Speaker is stored as "A"/"B" so the JSON stays readable.
struct MeetingSegmentRecord: Codable, Identifiable, Hashable {
    let id: UUID
    let speaker: String
    /// 界面/导出用的正文：润色过就是润色稿，否则是 ASR 原文。
    var text: String
    /// 润色前的 ASR 原文。润色后才有值，用于「还原原文」和对照显示；
    /// 老记录没有这个字段，解码为 nil。
    var rawText: String?

    init(id: UUID = UUID(), speaker: String, text: String, rawText: String? = nil) {
        self.id = id
        self.speaker = speaker
        self.text = text
        self.rawText = rawText
    }
}

/// One saved meeting-notes session. Stored as plain JSON in
/// Documents/MeetingNotes (not SwiftData): the fork must not touch the
/// app's CloudKit-backed schema for a side feature.
struct MeetingRecord: Codable, Identifiable, Hashable {
    let id: UUID
    let startedAt: Date
    let asrModelName: String
    var segments: [MeetingSegmentRecord]
    var summary: String?
    var summaryLanguage: String?
    /// File name (inside Documents/MeetingNotes) of the session's audio,
    /// one WAV from start to stop. Nil for records saved before audio
    /// was kept, and for sessions where recording failed.
    var audioFileName: String?

    init(
        id: UUID = UUID(),
        startedAt: Date,
        asrModelName: String,
        segments: [MeetingSegmentRecord],
        summary: String? = nil,
        summaryLanguage: String? = nil,
        audioFileName: String? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.asrModelName = asrModelName
        self.segments = segments
        self.summary = summary
        self.summaryLanguage = summaryLanguage
        self.audioFileName = audioFileName
    }
}

@MainActor
@Observable
final class MeetingRecordStore {
    private(set) var records: [MeetingRecord] = []

    private let logger = Logger(category: .selfHostedTranslation)

    private static var meetingsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "MeetingNotes")
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    func load() {
        let directory = Self.meetingsDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else {
            records = []
            return
        }
        var loaded: [MeetingRecord] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let record = try? Self.decoder.decode(MeetingRecord.self, from: data)
            else { continue }
            loaded.append(record)
        }
        records = loaded.sorted { $0.startedAt > $1.startedAt }
    }

    /// Upsert by id: saving the same record again (e.g. after a summary
    /// is added) overwrites its file instead of duplicating it.
    @discardableResult
    func save(_ record: MeetingRecord) -> Bool {
        let directory = Self.meetingsDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try Self.encoder.encode(record)
            try data.write(to: directory.appending(path: "\(record.id.uuidString).json"))
            if let index = records.firstIndex(where: { $0.id == record.id }) {
                records[index] = record
            } else {
                records.insert(record, at: 0)
            }
            records.sort { $0.startedAt > $1.startedAt }
            return true
        } catch {
            logger.logError("会议记录：保存失败：\(error.localizedDescription)")
            return false
        }
    }

    /// Absolute URL of a stored audio file by file name.
    func audioURL(fileName: String) -> URL {
        Self.meetingsDirectory.appending(path: fileName)
    }

    /// Absolute URL of a record's audio file (nil when it has none).
    /// Falls back to `<recordID>.wav` when the JSON predates the field
    /// but the file is on disk anyway.
    func audioURL(for record: MeetingRecord) -> URL? {
        if let name = record.audioFileName, !name.isEmpty {
            let url = Self.meetingsDirectory.appending(path: name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        let fallback = Self.meetingsDirectory.appending(path: "\(record.id.uuidString).wav")
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }

    /// Moves the session's temp WAV next to its JSON and returns the
    /// file name to store in the record. Nil means "keep no audio".
    func importAudio(from source: URL, recordID: UUID) -> String? {
        let directory = Self.meetingsDirectory
        let name = "\(recordID.uuidString).wav"
        let destination = directory.appending(path: name)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: source, to: destination)
            return name
        } catch {
            logger.logError("会议记录：音频保存失败：\(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    func delete(_ record: MeetingRecord) -> Bool {
        let file = Self.meetingsDirectory.appending(path: "\(record.id.uuidString).json")
        if let audio = audioURL(for: record) {
            try? FileManager.default.removeItem(at: audio)
        }
        do {
            try FileManager.default.removeItem(at: file)
            records.removeAll { $0.id == record.id }
            return true
        } catch {
            logger.logError("会议记录：删除失败：\(error.localizedDescription)")
            return false
        }
    }
}
