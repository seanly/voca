import Foundation

/// Local history store backed by JSON file.
final class HistoryStore {
    static let shared = HistoryStore()

    private var entries: [LocalHistoryEntry] = []
    private let maxEntries = 500
    private let fileURL: URL

    struct LocalHistoryEntry: Codable, Identifiable {
        let id: UUID
        let timestamp: Date
        let rawText: String
        let refinedText: String
        let language: String
        let appContext: String
        let wasRefined: Bool
    }

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let vocaDir = appSupport.appendingPathComponent("Voca")
        try? FileManager.default.createDirectory(at: vocaDir, withIntermediateDirectories: true)
        fileURL = vocaDir.appendingPathComponent("history.json")
        load()
    }

    func add(raw: String, refined: String, language: String, appContext: String, wasRefined: Bool) {
        let entry = LocalHistoryEntry(
            id: UUID(),
            timestamp: Date(),
            rawText: raw,
            refinedText: refined,
            language: language,
            appContext: appContext,
            wasRefined: wasRefined
        )
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        save()
    }

    func list(limit: Int = 50) -> [LocalHistoryEntry] {
        Array(entries.prefix(limit))
    }

    func search(query: String, limit: Int = 50) -> [LocalHistoryEntry] {
        let q = query.lowercased()
        return entries.filter {
            $0.rawText.lowercased().contains(q) || $0.refinedText.lowercased().contains(q)
        }.prefix(limit).map { $0 }
    }

    func clear() {
        entries.removeAll()
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        entries = (try? JSONDecoder().decode([LocalHistoryEntry].self, from: data)) ?? []
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
