import Foundation

/// Хранилище эмбеддингов голоса с поиском по косинусной близости.
///
/// JSON-файл лежит в `~/Library/Application Support/openXTranscriber/voices.json`.
/// Для каждого профиля можно держать несколько эмбеддингов — они накапливаются
/// при подтверждениях, что повышает устойчивость к настроению/микрофону/болезни.
actor VoiceLibrary {
    static let shared = VoiceLibrary()

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private var cached: VoiceLibraryFile?

    private init() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    // MARK: - Public API

    func voices() throws -> [VoiceProfile] {
        try load().voices
    }

    func match(
        embedding: [Float],
        autoThreshold: Float,
        suggestThreshold: Float
    ) throws -> (profile: VoiceProfile, similarity: Float, decision: SpeakerMatchDecision)? {
        let library = try load()
        guard !library.voices.isEmpty else { return nil }

        var bestProfile: VoiceProfile?
        var bestScore: Float = -1

        for profile in library.voices {
            for stored in profile.embeddings {
                let score = Self.cosine(stored, embedding)
                if score > bestScore {
                    bestScore = score
                    bestProfile = profile
                }
            }
        }

        guard let bestProfile else { return nil }

        let decision: SpeakerMatchDecision
        if bestScore >= autoThreshold {
            decision = .autoLabeled
        } else if bestScore >= suggestThreshold {
            decision = .suggestion
        } else {
            decision = .unknown
        }
        return (bestProfile, bestScore, decision)
    }

    @discardableResult
    func create(name: String, embedding: [Float]) throws -> VoiceProfile {
        var library = try load()
        let dim = library.dim == 0 ? embedding.count : library.dim
        try assertDimension(embedding, expected: dim, libraryEmpty: library.voices.isEmpty)

        let profile = VoiceProfile(
            name: name,
            embeddings: [embedding],
            sampleCount: 1
        )
        library.voices.append(profile)
        if library.dim == 0 {
            library.dim = embedding.count
        }
        try save(library)
        return profile
    }

    @discardableResult
    func appendEmbedding(profileID: UUID, embedding: [Float]) throws -> VoiceProfile? {
        var library = try load()
        guard let index = library.voices.firstIndex(where: { $0.id == profileID }) else {
            return nil
        }
        try assertDimension(embedding, expected: library.dim, libraryEmpty: false)
        library.voices[index].embeddings.append(embedding)
        library.voices[index].sampleCount += 1
        library.voices[index].updatedAt = Date()
        try save(library)
        return library.voices[index]
    }

    func rename(profileID: UUID, to newName: String) throws {
        var library = try load()
        guard let index = library.voices.firstIndex(where: { $0.id == profileID }) else { return }
        library.voices[index].name = newName
        library.voices[index].updatedAt = Date()
        try save(library)
    }

    func delete(profileID: UUID) throws {
        var library = try load()
        library.voices.removeAll { $0.id == profileID }
        try save(library)
    }

    func eraseAll() throws {
        let url = try fileURL()
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        cached = nil
    }

    /// Сбрасывает кэш и форсирует перечитывание при следующем обращении.
    func invalidate() {
        cached = nil
    }

    func storageURL() throws -> URL {
        try fileURL()
    }

    // MARK: - Internals

    private func load() throws -> VoiceLibraryFile {
        if let cached { return cached }
        let url = try fileURL()
        guard fileManager.fileExists(atPath: url.path) else {
            let empty = VoiceLibraryFile(
                version: VoiceLibraryFile.currentVersion,
                model: VoiceLibraryFile.defaultModel,
                dim: 0,
                voices: []
            )
            cached = empty
            return empty
        }
        let data = try Data(contentsOf: url)
        let parsed = try decoder.decode(VoiceLibraryFile.self, from: data)
        cached = parsed
        return parsed
    }

    private func save(_ library: VoiceLibraryFile) throws {
        let url = try fileURL()
        let data = try encoder.encode(library)
        try data.write(to: url, options: .atomic)
        cached = library
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
        return directory.appendingPathComponent("voices.json", isDirectory: false)
    }

    private func assertDimension(_ embedding: [Float], expected: Int, libraryEmpty: Bool) throws {
        guard !embedding.isEmpty else {
            throw VoiceLibraryError.invalidEmbedding(reason: "Embedding is empty.")
        }
        guard libraryEmpty || expected == 0 || embedding.count == expected else {
            throw VoiceLibraryError.dimensionMismatch(expected: expected, actual: embedding.count)
        }
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        let count = min(a.count, b.count)
        guard count > 0 else { return -1 }
        var dot: Float = 0
        var na: Float = 0
        var nb: Float = 0
        for i in 0..<count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = (na.squareRoot()) * (nb.squareRoot())
        guard denom > 0 else { return -1 }
        return dot / denom
    }
}

enum VoiceLibraryError: LocalizedError {
    case invalidEmbedding(reason: String)
    case dimensionMismatch(expected: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case let .invalidEmbedding(reason):
            return "Invalid voice embedding: \(reason)"
        case let .dimensionMismatch(expected, actual):
            return "Voice library dimension mismatch (expected \(expected), got \(actual)). Reset the library or switch back to the matching embedding model."
        }
    }
}
