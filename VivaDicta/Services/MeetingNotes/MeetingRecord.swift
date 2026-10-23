import Foundation
import os

/// One transcribed meeting segment: who spoke (volume heuristic) and what
/// was said. Speaker is stored as "A"/"B" so the JSON stays readable.
struct MeetingSegmentRecord: Codable, Identifiable, Hashable {
    let id: UUID
    let speaker: String
    let text: String

    init(id: UUID = UUID(), speaker: String, text: String) {
        self.id = id
        self.speaker = speaker
        self.text = text
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

    init(
        id: UUID = UUID(),
        startedAt: Date,
        asrModelName: String,
        segments: [MeetingSegmentRecord],
        summary: String? = nil,
        summaryLanguage: String? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.asrModelName = asrModelName
        self.segments = segments
        self.summary = summary
        self.summaryLanguage = summaryLanguage
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

    @discardableResult
    func delete(_ record: MeetingRecord) -> Bool {
        let file = Self.meetingsDirectory.appending(path: "\(record.id.uuidString).json")
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
