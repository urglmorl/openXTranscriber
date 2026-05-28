import Foundation

actor HistoryService {
    static let shared = HistoryService()

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var cache: HistoryFile?

    private init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func entries() async throws -> [HistoryEntry] {
        let file = try loadOrCreate()
        return file.entries
    }

    func append(_ entry: HistoryEntry) async throws {
        var file = try loadOrCreate()
        file.entries.append(entry)
        try persist(file)
    }

    func delete(id: UUID) async throws {
        var file = try loadOrCreate()
        file.entries.removeAll { $0.id == id }
        try persist(file)
    }

    func clear() async throws {
        let file = HistoryFile(version: HistoryFile.currentVersion, entries: [])
        try persist(file)
    }

    private func loadOrCreate() throws -> HistoryFile {
        if let cache { return cache }
        let url = try fileURL()
        guard fileManager.fileExists(atPath: url.path) else {
            let empty = HistoryFile(version: HistoryFile.currentVersion, entries: [])
            cache = empty
            return empty
        }
        let data = try Data(contentsOf: url)
        let file = try decoder.decode(HistoryFile.self, from: data)
        cache = file
        return file
    }

    private func persist(_ file: HistoryFile) throws {
        let url = try fileURL()
        let data = try encoder.encode(file)
        try data.write(to: url, options: [.atomic])
        cache = file
    }

    private func fileURL() throws -> URL {
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = appSupport
            .appendingPathComponent("openXTranscriber", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("history.json", isDirectory: false)
    }
}
