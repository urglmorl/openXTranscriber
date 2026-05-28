import Foundation

enum ProcessingStage: String, CaseIterable {
    case preflight = "Dependency Check"
    case audioExtraction = "Audio Extraction"
    case transcription = "Transcription"
    case transcriptionFirstPass = "Transcription (pass 1)"
    case contextAnalysis = "Context Analysis"
    case transcriptionSecondPass = "Transcription (pass 2)"
    case diarization = "Diarization"
    case voiceMatching = "Voice Matching"
    case merging = "Result Generation"
    case saving = "Saving Result"
    case finished = "Finished"

    var displayTitle: String {
        switch self {
        case .preflight: return String(localized: "Dependency Check")
        case .audioExtraction: return String(localized: "Audio Extraction")
        case .transcription: return String(localized: "Transcription")
        case .transcriptionFirstPass: return String(localized: "Transcription (pass 1)")
        case .contextAnalysis: return String(localized: "Context Analysis")
        case .transcriptionSecondPass: return String(localized: "Transcription (pass 2)")
        case .diarization: return String(localized: "Diarization")
        case .voiceMatching: return String(localized: "Voice Matching")
        case .merging: return String(localized: "Result Generation")
        case .saving: return String(localized: "Saving Result")
        case .finished: return String(localized: "Finished")
        }
    }
}

nonisolated enum ProcessingMode: String, Sendable {
    case fullPipeline
    case transcriptionOnly

    var title: String {
        switch self {
        case .fullPipeline:
            return String(localized: "Transcription + diarization")
        case .transcriptionOnly:
            return String(localized: "Transcription only")
        }
    }
}

enum RuntimePreparationState: String {
    case idle
    case checking
    case installing
    case ready
    case failed

    var displayTitle: String {
        switch self {
        case .idle: return String(localized: "Idle")
        case .checking: return String(localized: "Checking")
        case .installing: return String(localized: "Installing")
        case .ready: return String(localized: "Ready")
        case .failed: return String(localized: "Failed")
        }
    }
}

enum SaveMode: String, CaseIterable, Identifiable {
    case nearSource
    case fixedFolder

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nearSource:
            return String(localized: "Next to source file")
        case .fixedFolder:
            return String(localized: "Fixed folder")
        }
    }
}

struct TranscriptionWord: Codable, Hashable {
    let start: TimeInterval
    let end: TimeInterval
    let word: String
}

struct TranscriptionSegment: Codable, Hashable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    let words: [TranscriptionWord]?
}

struct DiarizationInterval: Codable, Hashable {
    let start: TimeInterval
    let end: TimeInterval
    let speakerID: String

    private enum CodingKeys: String, CodingKey {
        case start
        case end
        case speakerID = "speaker_id"
    }
}

struct DiarizedBlock: Hashable {
    let start: TimeInterval
    let speakerID: String
    let text: String
}

struct TranscriptionPayload: Codable {
    let segments: [TranscriptionSegment]
}

struct DiarizationPayload: Codable {
    let intervals: [DiarizationInterval]
}

struct ProcessingResult {
    let outputURL: URL
    let blockCount: Int
}

nonisolated struct HistoryEntry: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let createdAt: Date
    let sourceURL: URL
    let outputURL: URL
    let sourceName: String
    let blockCount: Int
    let modeRaw: String

    var modeTitle: String {
        ProcessingMode(rawValue: modeRaw)?.title ?? modeRaw
    }
}

nonisolated struct HistoryFile: Codable, Sendable {
    var version: Int
    var entries: [HistoryEntry]

    static let currentVersion = 1
}

// MARK: - Voice fingerprinting

/// Эмбеддинг одного спикера, полученный из embed.py.
struct SpeakerEmbedding: Codable, Hashable {
    let speakerID: String
    let embedding: [Float]
    let samples: Int
    let totalSeconds: TimeInterval
    let sampleStart: TimeInterval
    let sampleEnd: TimeInterval

    private enum CodingKeys: String, CodingKey {
        case speakerID = "speaker_id"
        case embedding
        case samples
        case totalSeconds = "total_seconds"
        case sampleStart = "sample_start"
        case sampleEnd = "sample_end"
    }
}

struct SpeakerEmbeddingPayload: Codable {
    let embeddings: [SpeakerEmbedding]
}

/// Профиль голоса в локальной библиотеке.
struct VoiceProfile: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var embeddings: [[Float]]
    var createdAt: Date
    var updatedAt: Date
    var sampleCount: Int

    init(
        id: UUID = UUID(),
        name: String,
        embeddings: [[Float]],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        sampleCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.embeddings = embeddings
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sampleCount = sampleCount
    }
}

/// Файл с библиотекой голосов на диске.
struct VoiceLibraryFile: Codable {
    var version: Int
    var model: String
    var dim: Int
    var voices: [VoiceProfile]

    static let currentVersion = 1
    static let defaultModel = "pyannote/wespeaker-voxceleb-resnet34-LM"
}

/// Решение по сопоставлению спикера с библиотекой.
enum SpeakerMatchDecision: String, Codable, Equatable {
    case autoLabeled
    case suggestion
    case unknown
}

/// Результат сопоставления одного SPEAKER_XX из диаризации.
struct SpeakerMatch: Identifiable, Hashable {
    let id: UUID
    let speakerID: String
    let embedding: [Float]
    let bestMatchVoiceID: UUID?
    let bestMatchName: String?
    let bestSimilarity: Float
    var decision: SpeakerMatchDecision
    let sampleStart: TimeInterval
    let sampleEnd: TimeInterval
    let totalSeconds: TimeInterval

    init(
        id: UUID = UUID(),
        speakerID: String,
        embedding: [Float],
        bestMatchVoiceID: UUID?,
        bestMatchName: String?,
        bestSimilarity: Float,
        decision: SpeakerMatchDecision,
        sampleStart: TimeInterval,
        sampleEnd: TimeInterval,
        totalSeconds: TimeInterval
    ) {
        self.id = id
        self.speakerID = speakerID
        self.embedding = embedding
        self.bestMatchVoiceID = bestMatchVoiceID
        self.bestMatchName = bestMatchName
        self.bestSimilarity = bestSimilarity
        self.decision = decision
        self.sampleStart = sampleStart
        self.sampleEnd = sampleEnd
        self.totalSeconds = totalSeconds
    }
}

struct ReadinessReport {
    let transcriptionReady: Bool
    let diarizationReady: Bool
    let recommendedMode: ProcessingMode
    let userMessage: String
}

struct PythonCommand: Hashable {
    let executable: String
    let prefixArguments: [String]
    let displayName: String

    func makeArguments(_ arguments: [String]) -> [String] {
        prefixArguments + arguments
    }
}

enum PipelineError: LocalizedError {
    case unsupportedInput
    case missingHFToken
    case missingScript(name: String)
    case invalidScriptOutput(name: String)
    case dependencyMissing(message: String)
    case runtimeSetupFailed(message: String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unsupportedInput:
            return String(localized: "Unsupported input file format.")
        case .missingHFToken:
            return String(localized: "HuggingFace token is missing. Open Settings and add it.")
        case let .missingScript(name):
            return String(localized: "Script \(name) is missing. Please ensure it exists in Scripts.")
        case let .invalidScriptOutput(name):
            return String(localized: "Script \(name) returned invalid data.")
        case let .dependencyMissing(message):
            return message
        case let .runtimeSetupFailed(message):
            return message
        case .cancelled:
            return String(localized: "Operation cancelled.")
        }
    }
}
