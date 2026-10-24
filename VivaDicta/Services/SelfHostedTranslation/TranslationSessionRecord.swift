import Foundation
import os

/// One saved self-hosted translation session. Stored as plain JSON in
/// Documents/TranslationSessions (not SwiftData): the fork must not
/// touch the app's CloudKit-backed schema for a side feature.
struct TranslationPairRecord: Codable, Identifiable, Hashable {
    let id: UUID
    let original: String
    let translation: String?
    /// Per-sentence direction, present for records saved after the
    /// conversation-mode change. Nil for older records, which only
    /// carried the session-level direction in the header.
    let sourceLanguage: String?
    let targetLanguage: String?

    init(id: UUID = UUID(), original: String, translation: String?, sourceLanguage: String? = nil, targetLanguage: String? = nil) {
        self.id = id
        self.original = original
        self.translation = translation
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
    }
}

struct TranslationSessionRecord: Codable, Identifiable, Hashable {
    let id: UUID
    let startedAt: Date
    let sourceLanguage: String
    let targetLanguage: String
    let asrModelName: String
    var pairs: [TranslationPairRecord]
    var summary: String?

    init(
        id: UUID = UUID(),
        startedAt: Date,
        sourceLanguage: String,
        targetLanguage: String,
        asrModelName: String,
        pairs: [TranslationPairRecord],
        summary: String? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.asrModelName = asrModelName
        self.pairs = pairs
        self.summary = summary
    }
}

@MainActor
@Observable
final class TranslationSessionStore {
    private(set) var records: [TranslationSessionRecord] = []

    private let logger = Logger(category: .selfHostedTranslation)

    private static var sessionsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "TranslationSessions")
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
        let directory = Self.sessionsDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else {
            records = []
            return
        }
        var loaded: [TranslationSessionRecord] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let record = try? Self.decoder.decode(TranslationSessionRecord.self, from: data)
            else {
                logger.logError("翻译记录：跳过无法解析的文件 \(file.lastPathComponent)")
                continue
            }
            loaded.append(record)
        }
        records = loaded.sorted { $0.startedAt > $1.startedAt }
    }

    /// Insert or overwrite a record, both in memory and on disk.
    @discardableResult
    func save(_ record: TranslationSessionRecord) -> Bool {
        let directory = Self.sessionsDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try Self.encoder.encode(record)
            try data.write(to: directory.appending(path: "\(record.id.uuidString).json"), options: .atomic)
        } catch {
            logger.logError("翻译记录：保存失败：\(error.localizedDescription)")
            return false
        }
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
            records.sort { $0.startedAt > $1.startedAt }
        }
        return true
    }

    @discardableResult
    func delete(_ record: TranslationSessionRecord) -> Bool {
        let file = Self.sessionsDirectory.appending(path: "\(record.id.uuidString).json")
        do {
            try FileManager.default.removeItem(at: file)
        } catch {
            logger.logError("翻译记录：删除失败：\(error.localizedDescription)")
            return false
        }
        records.removeAll { $0.id == record.id }
        return true
    }
}
