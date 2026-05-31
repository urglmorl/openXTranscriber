import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class TranscriberViewModel: ObservableObject {
    @Published var selectedFileURL: URL?
    @Published var outputURL: URL?
    @Published var logs: [String] = []
    @Published var stage: ProcessingStage = .preflight
    @Published var isProcessing = false
    @Published var errorMessage: String?
    @Published var blockCount: Int = 0
    @Published var runtimeState: RuntimePreparationState = .idle
    @Published var runtimeStatusMessage = String(localized: "Runtime has not been checked yet.")
    @Published var activePythonDisplayName = String(localized: "Not selected")
    @Published var readinessStatusMessage = String(localized: "Readiness has not been checked yet.")
    @Published var processingMode: ProcessingMode = .fullPipeline
    @Published var pendingSpeakerSuggestions: [SpeakerMatch] = []
    @Published var speakerNameMapping: [String: String] = [:]
    @Published var processedAudioURL: URL?

    @AppStorage("transcriptionLanguage") private var language = "ru"
    @AppStorage("whisperModel") private var whisperModel = "whisper-large-v3-turbo"
    @AppStorage("saveMode") private var saveModeRaw = SaveMode.nearSource.rawValue
    @AppStorage("fixedSaveFolderPath") private var fixedSaveFolderPath = ""
    @AppStorage("customPythonPath") private var customPythonPath = ""
    @AppStorage("voiceFingerprintingEnabled") private var voiceFingerprintingEnabled = true
    @AppStorage("voiceAutoLabelThreshold") private var voiceAutoLabelThreshold: Double = 0.80
    @AppStorage("voiceSuggestThreshold") private var voiceSuggestThreshold: Double = 0.65
    @AppStorage("transcriptionPrompt") var transcriptionPrompt = ""
    @AppStorage("twoPassTranscriptionEnabled") var twoPassTranscriptionEnabled = true
    @AppStorage("diarizationEnabled") var diarizationEnabled = true

    private let audioExtractor: AudioExtracting
    private let whisperService: WhisperServicing
    private let diarizationService: DiarizationServicing
    private let voiceEmbeddingService: VoiceEmbeddingServicing
    private let resultMerger: ResultMerging
    private let resultSaver: ResultSaving
    private let readinessChecker: ReadinessChecking
    private let runtimeManager: RuntimeManaging
    private let voiceLibrary: VoiceLibrary

    private var processingTask: Task<Void, Never>?
    private var internalCancelled = false
    private var lastBlocks: [DiarizedBlock] = []
    private var lastSpeakerEmbeddings: [String: SpeakerEmbedding] = [:]
    private var lastSourceURL: URL?
    private var lastSaveMode: SaveMode = .nearSource
    private var lastFixedFolder: URL?

    init(
        audioExtractor: AudioExtracting? = nil,
        whisperService: WhisperServicing? = nil,
        diarizationService: DiarizationServicing? = nil,
        voiceEmbeddingService: VoiceEmbeddingServicing? = nil,
        resultMerger: ResultMerging? = nil,
        resultSaver: ResultSaving? = nil,
        dependencyValidator: DependencyValidating? = nil,
        readinessChecker: ReadinessChecking? = nil,
        runtimeManager: RuntimeManaging? = nil,
        voiceLibrary: VoiceLibrary? = nil
    ) {
        let resolvedDependencyValidator = dependencyValidator ?? DependencyValidator()
        self.audioExtractor = audioExtractor ?? AudioExtractor()
        self.whisperService = whisperService ?? WhisperService()
        self.diarizationService = diarizationService ?? DiarizationService()
        self.voiceEmbeddingService = voiceEmbeddingService ?? VoiceEmbeddingService()
        self.resultMerger = resultMerger ?? ResultMerger()
        self.resultSaver = resultSaver ?? ResultSaver()
        self.readinessChecker = readinessChecker ?? ReadinessService(dependencyValidator: resolvedDependencyValidator)
        self.runtimeManager = runtimeManager ?? RuntimeManager.shared
        self.voiceLibrary = voiceLibrary ?? VoiceLibrary.shared
    }

    var stateTitle: String {
        if isProcessing {
            return String(localized: "Processing")
        }
        if outputURL != nil {
            return String(localized: "Result")
        }
        return String(localized: "Idle")
    }

    var canStart: Bool {
        selectedFileURL != nil && !isProcessing
    }

    var isPreparingRuntime: Bool {
        runtimeState == .checking || runtimeState == .installing
    }

    func setInputFile(_ url: URL) {
        errorMessage = nil
        outputURL = nil
        guard InputFileValidator.isSupported(url: url) else {
            errorMessage = PipelineError.unsupportedInput.localizedDescription
            return
        }
        selectedFileURL = url
        appendLog("Selected file: \(url.lastPathComponent)")
    }

    func selectFileWithPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        var allowedTypes: [UTType] = [.audio, .movie, .audiovisualContent, .quickTimeMovie, .mpeg4Movie]
        // WebM и Matroska не всегда имеют системный UTType — добавляем по идентификатору, если доступно.
        if let webm = UTType(filenameExtension: "webm") {
            allowedTypes.append(webm)
        }
        if let mkv = UTType(filenameExtension: "mkv") {
            allowedTypes.append(mkv)
        }
        panel.allowedContentTypes = allowedTypes
        if panel.runModal() == .OK, let url = panel.url {
            setInputFile(url)
        }
    }

    func processSelectedFile() {
        guard let selectedFileURL else { return }
        startProcessing(fileURL: selectedFileURL)
    }

    func startProcessing(fileURL: URL) {
        setInputFile(fileURL)
        guard errorMessage == nil else { return }
        processingTask?.cancel()
        internalCancelled = false
        logs.removeAll()
        outputURL = nil
        blockCount = 0
        isProcessing = true
        errorMessage = nil
        stage = .preflight
        appendLog("Starting pipeline...")

        processingTask = Task { [weak self] in
            guard let self else { return }
            let hasScopedAccess = fileURL.startAccessingSecurityScopedResource()
            defer {
                if hasScopedAccess {
                    fileURL.stopAccessingSecurityScopedResource()
                }
            }
            do {
                let python = try await self.prepareRuntimeIfNeeded(forceReinstall: false)
                let readiness = try await self.readinessChecker.evaluateReadiness(
                    python: python,
                    log: { message in
                        Task { @MainActor in
                            self.appendLog(message)
                        }
                    }
                )
                self.readinessStatusMessage = readiness.userMessage
                self.appendLog("Readiness: \(readiness.userMessage)")

                let effectiveMode: ProcessingMode
                if !self.diarizationEnabled {
                    effectiveMode = .transcriptionOnly
                    self.appendLog("Diarization disabled by user: running transcription only.")
                } else {
                    effectiveMode = readiness.recommendedMode
                    if readiness.recommendedMode == .transcriptionOnly {
                        self.appendLog("Beginner mode enabled: running transcription without speaker diarization.")
                    }
                }
                self.processingMode = effectiveMode
                try self.ensureNotCancelled()

                self.stage = .audioExtraction
                let wavURL = try await self.audioExtractor.extractToWav(
                    inputURL: fileURL,
                    preferredOutputURL: nil,
                    log: { message in
                        Task { @MainActor in
                            self.appendLog(message)
                        }
                    }
                )
                try self.ensureNotCancelled()

                let token = KeychainHelper.shared.loadToken() ?? ""
                let userPrompt = self.transcriptionPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                let segments = try await self.runTranscription(
                    audioURL: wavURL,
                    python: python,
                    token: token,
                    userPrompt: userPrompt
                )
                try self.ensureNotCancelled()

                var blocks: [DiarizedBlock]
                var pendingSuggestions: [SpeakerMatch] = []
                var nameMapping: [String: String] = [:]
                var embeddingsBySpeaker: [String: SpeakerEmbedding] = [:]
                if effectiveMode == .fullPipeline {
                    self.stage = .diarization
                    let diarizationStartedAt = Date()
                    let diarizationHeartbeatTask = Task { [weak self] in
                        guard let self else { return }
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(15))
                            await MainActor.run {
                                guard self.isProcessing, self.stage == .diarization else { return }
                                let elapsed = Int(Date().timeIntervalSince(diarizationStartedAt))
                                self.appendLog("Diarization is still running... \(elapsed)s elapsed.")
                            }
                        }
                    }
                    defer { diarizationHeartbeatTask.cancel() }
                    let intervals = try await self.diarizationService.diarize(
                        audioURL: wavURL,
                        python: python,
                        hfToken: token,
                        log: { message in
                            Task { @MainActor in
                                self.appendLog(message)
                            }
                        },
                        shouldCancel: { Task.isCancelled || self.internalCancelled }
                    )
                    try self.ensureNotCancelled()

                    if self.voiceFingerprintingEnabled {
                        self.stage = .voiceMatching
                        do {
                            let embeddings = try await self.voiceEmbeddingService.embed(
                                audioURL: wavURL,
                                intervals: intervals,
                                python: python,
                                hfToken: token,
                                log: { message in
                                    Task { @MainActor in
                                        self.appendLog(message)
                                    }
                                },
                                shouldCancel: { Task.isCancelled || self.internalCancelled }
                            )
                            try self.ensureNotCancelled()
                            embeddingsBySpeaker = Dictionary(
                                uniqueKeysWithValues: embeddings.map { ($0.speakerID, $0) }
                            )
                            let result = await self.matchAgainstLibrary(embeddings: embeddings)
                            nameMapping = result.mapping
                            pendingSuggestions = result.suggestions
                            self.logVoiceMatchingSummary(
                                mapping: result.mapping,
                                suggestions: result.suggestions,
                                totalSpeakers: embeddings.count
                            )
                        } catch {
                            self.appendLog("Voice fingerprinting skipped: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
                        }
                    }

                    self.stage = .merging
                    blocks = self.resultMerger.merge(
                        transcription: segments,
                        diarization: intervals
                    )
                } else {
                    self.stage = .merging
                    blocks = self.buildTranscriptionOnlyBlocks(from: segments)
                }
                if !nameMapping.isEmpty {
                    blocks = self.applyMapping(nameMapping, to: blocks)
                }
                self.blockCount = blocks.count
                try self.ensureNotCancelled()

                self.stage = .saving
                let saveMode = SaveMode(rawValue: self.saveModeRaw) ?? .nearSource
                let fixedFolderURL = self.fixedSaveFolderPath.isEmpty ? nil : URL(fileURLWithPath: self.fixedSaveFolderPath)
                let savedURL = try self.resultSaver.save(
                    blocks: blocks,
                    sourceURL: fileURL,
                    mode: saveMode,
                    fixedFolder: fixedFolderURL
                )

                self.lastBlocks = blocks
                self.lastSpeakerEmbeddings = embeddingsBySpeaker
                self.lastSourceURL = fileURL
                self.lastSaveMode = saveMode
                self.lastFixedFolder = fixedFolderURL
                self.processedAudioURL = wavURL
                self.speakerNameMapping = nameMapping
                self.pendingSpeakerSuggestions = pendingSuggestions
                self.stage = .finished
                self.outputURL = savedURL
                self.appendLog("Saved file: \(savedURL.path)")
                self.isProcessing = false

                let entry = HistoryEntry(
                    id: UUID(),
                    createdAt: Date(),
                    sourceURL: fileURL,
                    outputURL: savedURL,
                    sourceName: fileURL.lastPathComponent,
                    blockCount: blocks.count,
                    modeRaw: self.processingMode.rawValue
                )
                Task.detached {
                    try? await HistoryService.shared.append(entry)
                }
            } catch {
                self.runtimeState = .failed
                if case PipelineError.cancelled = error {
                    self.appendLog("Cancelled.")
                    self.errorMessage = PipelineError.cancelled.localizedDescription
                } else if error is CancellationError {
                    self.appendLog("Cancelled.")
                    self.errorMessage = PipelineError.cancelled.localizedDescription
                } else {
                    self.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    if let errorMessage = self.errorMessage {
                        self.appendLog("Error: \(errorMessage)")
                        if let savedLogURL = self.persistErrorLog(reason: errorMessage) {
                            self.appendLog("Error log saved: \(savedLogURL.path)")
                        }
                    }
                }
                self.isProcessing = false
            }
        }
    }

    func checkRuntime() {
        Task { [weak self] in
            guard let self else { return }
            runtimeState = .checking
            runtimeStatusMessage = String(localized: "Checking runtime...")
            do {
                if let python = await runtimeManager.resolveAvailableRuntime(customPythonPath: normalizedCustomPythonPath()) {
                    runtimeState = .ready
                    activePythonDisplayName = python.displayName
                    runtimeStatusMessage = String(localized: "Runtime available: \(python.displayName)")
                    appendLog(runtimeStatusMessage)
                    do {
                        let readiness = try await readinessChecker.evaluateReadiness(python: python, log: { _ in })
                        readinessStatusMessage = readiness.userMessage
                    } catch {
                        readinessStatusMessage = String(localized: "Readiness check failed: \(error.localizedDescription)")
                    }
                } else {
                    setRuntimeFailure("No Python runtime found. Install Python 3.10+ or configure a Python path in Settings.")
                }
            } catch {
                setRuntimeFailure((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    func reinstallRuntime() {
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.prepareRuntimeIfNeeded(forceReinstall: true)
            } catch {
                setRuntimeFailure((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    func cancelProcessing() {
        internalCancelled = true
        processingTask?.cancel()
        isProcessing = false
        appendLog("Cancellation requested.")
    }

    func dismissError() {
        errorMessage = nil
    }

    func openResultInFinder() {
        guard let outputURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([outputURL])
    }

    func openResultFile() {
        guard let outputURL else { return }
        NSWorkspace.shared.open(outputURL)
    }

    func resetForAnotherRun() {
        selectedFileURL = nil
        outputURL = nil
        logs.removeAll()
        errorMessage = nil
        stage = .preflight
        isProcessing = false
        blockCount = 0
        internalCancelled = false
        pendingSpeakerSuggestions = []
        speakerNameMapping = [:]
        processedAudioURL = nil
        lastBlocks = []
        lastSpeakerEmbeddings = [:]
        lastSourceURL = nil
        lastFixedFolder = nil
    }

    // MARK: - Voice fingerprinting

    var hasUnnamedSpeakers: Bool {
        !pendingSpeakerSuggestions.isEmpty
    }

    /// Подтверждение существующего голоса — добавляет эмбеддинг к нему
    /// и переименовывает спикера в выходном файле.
    func confirmSpeaker(_ match: SpeakerMatch, asExisting profile: VoiceProfile) {
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.voiceLibrary.appendEmbedding(profileID: profile.id, embedding: match.embedding)
                await self.applyNamingResult(speakerID: match.speakerID, name: profile.name, matchID: match.id)
            } catch {
                await MainActor.run {
                    self.appendLog("Failed to update voice library: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Создание нового профиля под этого спикера.
    func confirmSpeaker(_ match: SpeakerMatch, asNew name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.voiceLibrary.create(name: trimmed, embedding: match.embedding)
                await self.applyNamingResult(speakerID: match.speakerID, name: trimmed, matchID: match.id)
            } catch {
                await MainActor.run {
                    self.appendLog("Failed to add voice profile: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Пользователь решил оставить SPEAKER_XX — просто убираем из списка.
    func skipSpeaker(_ match: SpeakerMatch) {
        pendingSpeakerSuggestions.removeAll { $0.id == match.id }
    }

    func dismissAllSuggestions() {
        pendingSpeakerSuggestions.removeAll()
    }

    func currentVoices() async -> [VoiceProfile] {
        (try? await voiceLibrary.voices()) ?? []
    }

    func refreshRuntimeSummary() {
        Task { [weak self] in
            guard let self else { return }
            if let python = await runtimeManager.resolveAvailableRuntime(customPythonPath: normalizedCustomPythonPath()) {
                await MainActor.run {
                    activePythonDisplayName = python.displayName
                    runtimeStatusMessage = "Runtime available."
                    if runtimeState == .idle || runtimeState == .failed {
                        runtimeState = .ready
                    }
                }
                    do {
                        let readiness = try await readinessChecker.evaluateReadiness(python: python, log: { _ in })
                        await MainActor.run {
                            readinessStatusMessage = readiness.userMessage
                        }
                    } catch {
                        await MainActor.run {
                            readinessStatusMessage = String(localized: "Readiness check failed: \(error.localizedDescription)")
                        }
                    }
            } else {
                await MainActor.run {
                    activePythonDisplayName = "Not found"
                    runtimeStatusMessage = "Runtime is not configured."
                        readinessStatusMessage = "Readiness unavailable until runtime is configured."
                    runtimeState = .failed
                }
            }
        }
    }

    /// Запускает транскрипцию. В двухпроходном режиме делает первый прогон с
    /// пользовательским контекстом, извлекает имена/термины и прогоняет ещё раз
    /// с расширенным промптом. В однопроходном — обычный единственный вызов.
    private func runTranscription(
        audioURL: URL,
        python: PythonCommand,
        token: String,
        userPrompt: String
    ) async throws -> [TranscriptionSegment] {
        let logger: (String) -> Void = { message in
            Task { @MainActor in
                self.appendLog(message)
            }
        }
        let cancel: () -> Bool = { Task.isCancelled || self.internalCancelled }

        guard twoPassTranscriptionEnabled else {
            stage = .transcription
            if !userPrompt.isEmpty {
                appendLog("Whisper prompt: \(previewPrompt(userPrompt))")
            }
            return try await whisperService.transcribe(
                audioURL: audioURL,
                python: python,
                language: language,
                model: whisperModel,
                prompt: userPrompt,
                hfToken: token,
                log: logger,
                shouldCancel: cancel
            )
        }

        stage = .transcriptionFirstPass
        if !userPrompt.isEmpty {
            appendLog("Pass 1 prompt: \(previewPrompt(userPrompt))")
        } else {
            appendLog("Pass 1: no user context, running cold.")
        }
        let firstPassSegments = try await whisperService.transcribe(
            audioURL: audioURL,
            python: python,
            language: language,
            model: whisperModel,
            prompt: userPrompt,
            hfToken: token,
            log: logger,
            shouldCancel: cancel
        )
        try ensureNotCancelled()

        stage = .contextAnalysis
        let voices = await currentVoices()
        let voiceNames = voices
            .map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let hints = extractContextHints(
            from: firstPassSegments,
            voiceNames: voiceNames,
            language: language
        )
        if !hints.mentionedNames.isEmpty {
            appendLog("Detected names from library: \(hints.mentionedNames.joined(separator: ", "))")
        }
        if !hints.rareTerms.isEmpty {
            appendLog("Recurring terms: \(hints.rareTerms.joined(separator: ", "))")
        }
        if hints.mentionedNames.isEmpty && hints.rareTerms.isEmpty {
            appendLog("No additional context found in pass 1.")
        }
        let refinedPrompt = buildRefinedPrompt(
            userPrompt: userPrompt,
            mentionedNames: hints.mentionedNames,
            rareTerms: hints.rareTerms
        )
        try ensureNotCancelled()

        stage = .transcriptionSecondPass
        appendLog("Pass 2 prompt: \(previewPrompt(refinedPrompt))")
        return try await whisperService.transcribe(
            audioURL: audioURL,
            python: python,
            language: language,
            model: whisperModel,
            prompt: refinedPrompt,
            hfToken: token,
            log: logger,
            shouldCancel: cancel
        )
    }

    /// Whisper'овский лимит initial_prompt — ~224 токена; обрезаем под ~800
    /// символов с запасом.
    private func buildRefinedPrompt(
        userPrompt: String,
        mentionedNames: [String],
        rareTerms: [String]
    ) -> String {
        var pieces: [String] = []
        if !userPrompt.isEmpty {
            pieces.append(userPrompt)
        }
        if !mentionedNames.isEmpty {
            let label = String(localized: "Mentioned: ")
            pieces.append(label + mentionedNames.joined(separator: ", ") + ".")
        }
        if !rareTerms.isEmpty {
            let label = String(localized: "Key terms: ")
            pieces.append(label + rareTerms.joined(separator: ", ") + ".")
        }
        return String(pieces.joined(separator: " ").prefix(800))
    }

    /// Из первого прохода вытаскиваем (а) имена из библиотеки голосов, реально
    /// упомянутые в тексте, и (б) часто повторяющиеся неслужебные слова.
    /// Имена сравниваем по стему (первая половина), чтобы ловить «Алиса/Алисе/Алисой».
    private func extractContextHints(
        from segments: [TranscriptionSegment],
        voiceNames: [String],
        language: String,
        maxRareTerms: Int = 20
    ) -> (mentionedNames: [String], rareTerms: [String]) {
        let fullText = segments.map(\.text).joined(separator: " ")
        guard !fullText.isEmpty else { return ([], []) }
        let lowerText = fullText.lowercased()

        let mentionedNames = voiceNames.filter { name in
            let lowerName = name.lowercased()
            let stemLength = max(4, lowerName.count - 2)
            let stem = String(lowerName.prefix(stemLength))
            return lowerText.contains(stem)
        }
        let mentionedNamesLower = Set(mentionedNames.map { $0.lowercased() })

        let stopwords = stopwords(for: language)
        var counts: [String: (count: Int, original: String)] = [:]
        let separators = CharacterSet.alphanumerics.inverted
        for token in fullText.components(separatedBy: separators) {
            guard token.count > 3 else { continue }
            if token.allSatisfy({ $0.isNumber }) { continue }
            let lower = token.lowercased()
            if stopwords.contains(lower) { continue }
            if mentionedNamesLower.contains(lower) { continue }
            if let existing = counts[lower] {
                counts[lower] = (existing.count + 1, existing.original)
            } else {
                counts[lower] = (1, token)
            }
        }

        let rareTerms = counts
            .filter { $0.value.count >= 2 }
            .sorted { lhs, rhs in
                if lhs.value.count != rhs.value.count { return lhs.value.count > rhs.value.count }
                return lhs.key < rhs.key
            }
            .prefix(maxRareTerms)
            .map { $0.value.original }

        return (mentionedNames, Array(rareTerms))
    }

    private func stopwords(for language: String) -> Set<String> {
        switch language.lowercased() {
        case "ru":
            return Self.russianStopwords
        case "de":
            return Self.germanStopwords
        case "fr":
            return Self.frenchStopwords
        case "es":
            return Self.spanishStopwords
        case "it":
            return Self.italianStopwords
        default:
            return Self.englishStopwords
        }
    }

    private static let englishStopwords: Set<String> = [
        "about", "after", "again", "also", "another", "because", "been", "before",
        "being", "between", "could", "does", "doing", "down", "during", "each",
        "even", "ever", "every", "from", "going", "have", "having", "here", "into",
        "just", "know", "like", "make", "many", "more", "most", "much", "must",
        "never", "only", "other", "over", "really", "said", "same", "should",
        "some", "still", "such", "than", "that", "their", "them", "then", "there",
        "these", "they", "thing", "things", "think", "this", "those", "through",
        "very", "want", "well", "were", "what", "when", "where", "which", "while",
        "will", "with", "would", "your", "you're", "yeah", "okay", "right", "thats"
    ]

    private static let russianStopwords: Set<String> = [
        "будет", "была", "были", "было", "быть", "вообще", "ведь", "вместе",
        "вокруг", "впрочем", "всего", "всем", "всех", "всю", "вдруг", "даже",
        "других", "если", "ещё", "если", "знать", "именно", "иначе", "когда",
        "конечно", "которая", "которой", "котором", "которому", "которые",
        "которым", "которых", "который", "кстати", "может", "можно", "много",
        "мочь", "наверное", "надо", "наша", "наше", "наши", "нашего", "нашей",
        "нашему", "наши", "немного", "нельзя", "никакой", "никогда", "никто",
        "ничего", "ничто", "нужно", "однако", "около", "оно", "очень", "пока",
        "потом", "потому", "почему", "почти", "просто", "против", "просто",
        "сами", "самих", "самим", "самих", "себе", "себя", "сейчас", "сказать",
        "снова", "сразу", "среди", "также", "такие", "такой", "такая", "такое",
        "тогда", "только", "тоже", "точно", "хотя", "часто", "через", "чтобы",
        "что-то", "этих", "этой", "этом", "этот", "эта", "эти", "это", "ваш",
        "ваша", "ваши", "ваше", "ваших", "вашего", "вашей", "была"
    ]

    private static let germanStopwords: Set<String> = [
        "aber", "alle", "allen", "alles", "andere", "auch", "auf", "auch",
        "beim", "dann", "dass", "denn", "diese", "dieser", "dieses", "doch",
        "durch", "eine", "einem", "einen", "einer", "eines", "etwa", "ganz",
        "gegen", "haben", "habe", "hatte", "hier", "immer", "kann", "kein",
        "keine", "können", "lassen", "machen", "mehr", "müssen", "nach", "nicht",
        "noch", "nicht", "nur", "oder", "oben", "ohne", "schon", "sehr", "sein",
        "sich", "sind", "soll", "sondern", "über", "unter", "viel", "vom", "von",
        "war", "waren", "weil", "weiter", "welche", "welcher", "welches", "wenn",
        "werden", "wieder", "wird", "worden", "wurde", "wurden", "ihre", "ihrer",
        "ihrem", "ihren", "ihres"
    ]

    private static let frenchStopwords: Set<String> = [
        "alors", "aussi", "autre", "avant", "avec", "avoir", "beaucoup", "bien",
        "cela", "ceci", "cette", "celui", "celle", "comme", "comment", "dans",
        "donc", "elle", "elles", "encore", "entre", "était", "étaient", "être",
        "faire", "faut", "fois", "gens", "ici", "jour", "leur", "leurs", "lui",
        "mais", "même", "moins", "moi", "nous", "notre", "nous", "parce", "pas",
        "peu", "peut", "plus", "pour", "pouvoir", "qu'il", "quand", "quelque",
        "quelques", "qui", "quoi", "sans", "sauf", "selon", "ses", "son", "sont",
        "sous", "tous", "tout", "toutes", "très", "trop", "votre", "vous", "même"
    ]

    private static let spanishStopwords: Set<String> = [
        "ahora", "algo", "algunos", "ante", "antes", "aquí", "aquel", "aquella",
        "como", "cuando", "desde", "donde", "entre", "esta", "estaba", "están",
        "estar", "este", "estos", "estoy", "estás", "estés", "fueron", "hace",
        "hacer", "hasta", "lugar", "luego", "menos", "mientras", "mucho", "muchos",
        "muy", "nada", "nosotros", "nuestra", "nuestro", "nunca", "otra", "otras",
        "otro", "otros", "para", "pero", "poder", "porque", "pues", "puede",
        "queda", "quien", "saber", "según", "sido", "siempre", "sino", "sobre",
        "solo", "sólo", "somos", "soy", "tanto", "también", "tener", "tiene",
        "tienen", "todo", "todos", "una", "unos", "vamos", "vez"
    ]

    private static let italianStopwords: Set<String> = [
        "altro", "ancora", "anche", "avere", "anche", "ancora", "avrebbe",
        "avuto", "bene", "ciò", "come", "cosa", "così", "dalla", "dello",
        "della", "delle", "degli", "deve", "devo", "dove", "dopo", "ecco",
        "essere", "fare", "fatto", "fino", "forse", "infatti", "invece",
        "lavoro", "loro", "meno", "mentre", "mezzo", "molti", "molto", "nella",
        "nelle", "nello", "ogni", "perché", "però", "poco", "poi", "posso",
        "potere", "prima", "proprio", "qualche", "quale", "quali", "quando",
        "quanto", "quello", "questa", "questi", "questo", "sempre", "senza",
        "sono", "sopra", "sotto", "stato", "tanto", "troppo", "tutti", "tutto",
        "vedere", "vero", "volta", "volte", "vostro"
    ]

    private func previewPrompt(_ prompt: String) -> String {
        let limit = 120
        if prompt.count <= limit { return prompt }
        return String(prompt.prefix(limit)) + "…"
    }

    private func ensureNotCancelled() throws {
        if Task.isCancelled || internalCancelled {
            throw PipelineError.cancelled
        }
    }

    private func appendLog(_ message: String) {
        logs.append(message)
    }

    private func buildTranscriptionOnlyBlocks(from segments: [TranscriptionSegment]) -> [DiarizedBlock] {
        segments.map { segment in
            DiarizedBlock(
                start: segment.start,
                speakerID: "SPEECH",
                text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    private func matchAgainstLibrary(
        embeddings: [SpeakerEmbedding]
    ) async -> (mapping: [String: String], suggestions: [SpeakerMatch]) {
        var mapping: [String: String] = [:]
        var suggestions: [SpeakerMatch] = []
        let autoThreshold = Float(voiceAutoLabelThreshold)
        let suggestThreshold = Float(voiceSuggestThreshold)

        for embedding in embeddings {
            let result = try? await voiceLibrary.match(
                embedding: embedding.embedding,
                autoThreshold: autoThreshold,
                suggestThreshold: suggestThreshold
            )
            switch result?.decision {
            case .autoLabeled:
                guard let profile = result?.profile, let similarity = result?.similarity else { break }
                mapping[embedding.speakerID] = profile.name
                _ = try? await voiceLibrary.appendEmbedding(profileID: profile.id, embedding: embedding.embedding)
                appendLog(String(format: "Auto-labeled %@ as \"%@\" (cosine %.2f)", embedding.speakerID, profile.name, similarity))
            case .suggestion:
                let match = SpeakerMatch(
                    speakerID: embedding.speakerID,
                    embedding: embedding.embedding,
                    bestMatchVoiceID: result?.profile.id,
                    bestMatchName: result?.profile.name,
                    bestSimilarity: result?.similarity ?? 0,
                    decision: .suggestion,
                    sampleStart: embedding.sampleStart,
                    sampleEnd: embedding.sampleEnd,
                    totalSeconds: embedding.totalSeconds
                )
                suggestions.append(match)
            case .unknown, .none:
                let match = SpeakerMatch(
                    speakerID: embedding.speakerID,
                    embedding: embedding.embedding,
                    bestMatchVoiceID: nil,
                    bestMatchName: nil,
                    bestSimilarity: result?.similarity ?? 0,
                    decision: .unknown,
                    sampleStart: embedding.sampleStart,
                    sampleEnd: embedding.sampleEnd,
                    totalSeconds: embedding.totalSeconds
                )
                suggestions.append(match)
            }
        }
        return (mapping, suggestions)
    }

    private func logVoiceMatchingSummary(
        mapping: [String: String],
        suggestions: [SpeakerMatch],
        totalSpeakers: Int
    ) {
        let auto = mapping.count
        let toName = suggestions.count
        appendLog("Voice matching: \(totalSpeakers) speaker(s), \(auto) auto-labeled, \(toName) need confirmation.")
    }

    private func applyMapping(_ mapping: [String: String], to blocks: [DiarizedBlock]) -> [DiarizedBlock] {
        guard !mapping.isEmpty else { return blocks }
        return blocks.map { block in
            DiarizedBlock(
                start: block.start,
                speakerID: mapping[block.speakerID] ?? block.speakerID,
                text: block.text
            )
        }
    }

    /// Применяет переименование к сохранённому файлу и обновляет кэш блоков.
    private func applyNamingResult(speakerID: String, name: String, matchID: UUID) async {
        let updatedBlocks = applyMapping([speakerID: name], to: lastBlocks)
        var updatedMapping = speakerNameMapping
        updatedMapping[speakerID] = name

        guard let sourceURL = lastSourceURL else {
            await MainActor.run {
                self.speakerNameMapping = updatedMapping
                self.pendingSpeakerSuggestions.removeAll { $0.id == matchID }
                self.appendLog("Speaker \(speakerID) labeled as \"\(name)\" (no source file to re-save).")
            }
            return
        }

        do {
            let savedURL = try resultSaver.save(
                blocks: updatedBlocks,
                sourceURL: sourceURL,
                mode: lastSaveMode,
                fixedFolder: lastFixedFolder
            )
            await MainActor.run {
                self.lastBlocks = updatedBlocks
                self.speakerNameMapping = updatedMapping
                self.outputURL = savedURL
                self.pendingSpeakerSuggestions.removeAll { $0.id == matchID }
                self.appendLog("Speaker \(speakerID) labeled as \"\(name)\". File updated.")
            }
        } catch {
            await MainActor.run {
                self.appendLog("Failed to save updated file: \(error.localizedDescription)")
            }
        }
    }

    private func prepareRuntimeIfNeeded(forceReinstall: Bool) async throws -> PythonCommand {
        runtimeState = forceReinstall ? .installing : .checking
        runtimeStatusMessage = forceReinstall ? "Reinstalling managed runtime..." : "Checking runtime..."
        appendLog(runtimeStatusMessage)
        do {
            let python = try await runtimeManager.prepareRuntimeIfNeeded(
                customPythonPath: normalizedCustomPythonPath(),
                forceReinstall: forceReinstall,
                log: { message in
                    Task { @MainActor in
                        self.appendLog(message)
                    }
                },
                shouldCancel: { Task.isCancelled || self.internalCancelled }
            )
            runtimeState = .ready
            activePythonDisplayName = python.displayName
            runtimeStatusMessage = "Runtime ready: \(python.displayName)"
            appendLog(runtimeStatusMessage)
            do {
                let readiness = try await readinessChecker.evaluateReadiness(python: python, log: { _ in })
                readinessStatusMessage = readiness.userMessage
                appendLog("Readiness: \(readiness.userMessage)")
            } catch {
                readinessStatusMessage = "Readiness check failed: \(error.localizedDescription)"
            }
            return python
        } catch {
            if case PipelineError.cancelled = error {
                runtimeState = .idle
                runtimeStatusMessage = "Runtime preparation cancelled."
            } else {
                setRuntimeFailure((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
            throw error
        }
    }

    private func normalizedCustomPythonPath() -> String? {
        let value = customPythonPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func setRuntimeFailure(_ message: String) {
        runtimeState = .failed
        runtimeStatusMessage = message
        errorMessage = message
        appendLog("Runtime error: \(message)")
        if let savedLogURL = persistErrorLog(reason: message) {
            appendLog("Error log saved: \(savedLogURL.path)")
        }
    }

    private func persistErrorLog(reason: String) -> URL? {
        do {
            let logsDirectory = try errorLogsDirectory()
            let fileURL = logsDirectory.appendingPathComponent("error-\(errorTimestamp()).log")

            var lines: [String] = []
            lines.append("Date: \(ISO8601DateFormatter().string(from: Date()))")
            lines.append("Error: \(reason)")
            lines.append("Stage: \(stage.rawValue)")
            lines.append("Runtime State: \(runtimeState.rawValue)")
            lines.append("Runtime Message: \(runtimeStatusMessage)")
            lines.append("Selected File: \(selectedFileURL?.path ?? "N/A")")
            lines.append("Output File: \(outputURL?.path ?? "N/A")")
            lines.append("")
            lines.append("Logs:")
            lines.append(contentsOf: logs)
            let payload = lines.joined(separator: "\n")

            try payload.write(to: fileURL, atomically: true, encoding: .utf8)
            return fileURL
        } catch {
            appendLog("Failed to save error log: \(error.localizedDescription)")
            return nil
        }
    }

    private func errorLogsDirectory() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = appSupport
            .appendingPathComponent("openXTranscriber", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func errorTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
