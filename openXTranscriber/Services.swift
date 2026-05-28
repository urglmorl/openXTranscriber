import AppKit
@preconcurrency import AVFoundation
import Foundation
import UniformTypeIdentifiers

private enum ScriptLocator {
    static func findScript(named name: String) -> URL? {
        if let bundled = Bundle.main.url(forResource: name, withExtension: "py", subdirectory: "Scripts") {
            return bundled
        }
        if let directBundle = Bundle.main.url(forResource: name, withExtension: "py") {
            return directBundle
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let cwdCandidate = cwd.appendingPathComponent("Scripts/\(name).py")
        if FileManager.default.fileExists(atPath: cwdCandidate.path) {
            return cwdCandidate
        }
        let projectCandidate = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Scripts/\(name).py")
        if FileManager.default.fileExists(atPath: projectCandidate.path) {
            return projectCandidate
        }
        if let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) {
            let runtimeCandidate = appSupport
                .appendingPathComponent("openXTranscriber/runtime/scripts/\(name).py")
            if FileManager.default.fileExists(atPath: runtimeCandidate.path) {
                return runtimeCandidate
            }
        }
        return nil
    }
}

protocol AudioExtracting {
    func extractToWav(
        inputURL: URL,
        preferredOutputURL: URL?,
        log: @escaping (String) -> Void
    ) async throws -> URL
}

protocol WhisperServicing {
    func transcribe(
        audioURL: URL,
        python: PythonCommand,
        language: String,
        model: String,
        prompt: String,
        hfToken: String,
        log: @escaping (String) -> Void,
        shouldCancel: @escaping () -> Bool
    ) async throws -> [TranscriptionSegment]
}

protocol DiarizationServicing {
    func diarize(
        audioURL: URL,
        python: PythonCommand,
        hfToken: String,
        log: @escaping (String) -> Void,
        shouldCancel: @escaping () -> Bool
    ) async throws -> [DiarizationInterval]
}

protocol VoiceEmbeddingServicing {
    func embed(
        audioURL: URL,
        intervals: [DiarizationInterval],
        python: PythonCommand,
        hfToken: String,
        log: @escaping (String) -> Void,
        shouldCancel: @escaping () -> Bool
    ) async throws -> [SpeakerEmbedding]
}

protocol ResultMerging {
    func merge(
        transcription: [TranscriptionSegment],
        diarization: [DiarizationInterval]
    ) -> [DiarizedBlock]
}

protocol ResultSaving {
    func save(
        blocks: [DiarizedBlock],
        sourceURL: URL,
        mode: SaveMode,
        fixedFolder: URL?
    ) throws -> URL
}

protocol DependencyValidating {
    func validate(
        requireDiarization: Bool,
        hfTokenRequired: Bool,
        python: PythonCommand,
        log: @escaping (String) -> Void
    ) async throws
}

protocol ReadinessChecking {
    func evaluateReadiness(
        python: PythonCommand,
        log: @escaping (String) -> Void
    ) async throws -> ReadinessReport
}

final class AudioExtractor: AudioExtracting {
    func extractToWav(
        inputURL: URL,
        preferredOutputURL: URL?,
        log: @escaping (String) -> Void
    ) async throws -> URL {
        let outputURL: URL
        if let preferredOutputURL {
            outputURL = preferredOutputURL
        } else {
            outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("wav")
        }

        log("Preparing audio track...")
        let ffmpegPath = findFFmpegPath()

        // Сразу определим, сколько аудио-дорожек в источнике — это нужно и AVFoundation-пути
        // (для корректного микса нескольких дорожек), и ffmpeg-фолбэку (чтобы построить filter_complex).
        let asset = AVURLAsset(url: inputURL)
        let probedTracks: [AVAssetTrack]
        do {
            probedTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            probedTracks = []
        }
        let audioStreamCount = max(probedTracks.count, 1)

        // Основной путь: AVFoundation напрямую пишет WAV 16k mono s16le.
        // Поддерживает QuickTime (.mov), MP4, M4A и другие контейнеры без ffmpeg.
        do {
            log("Extracting audio via AVFoundation (AVAssetReader -> WAV)...")
            try await extractWavWithAVFoundation(
                asset: asset,
                tracks: probedTracks,
                outputURL: outputURL,
                log: log
            )
            return outputURL
        } catch {
            log("AVFoundation extraction failed: \(error.localizedDescription)")
        }

        // Фолбэк 1: ffmpeg напрямую из исходника (webm, неподдерживаемые .mov-кодеки и т.п.).
        if let ffmpegPath {
            log("Trying ffmpeg fallback directly from source file...")
            do {
                try await convertToWav(
                    sourcePath: inputURL.path,
                    destinationPath: outputURL.path,
                    ffmpegPath: ffmpegPath,
                    audioStreamCount: audioStreamCount,
                    log: log
                )
                return outputURL
            } catch {
                log("ffmpeg fallback failed: \(error.localizedDescription)")
            }
        }

        // Фолбэк 2: если вход уже WAV — просто копируем.
        if inputURL.pathExtension.lowercased() == "wav" {
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }
            try FileManager.default.copyItem(at: inputURL, to: outputURL)
            return outputURL
        }

        throw PipelineError.dependencyMissing(
            message: "Audio extraction failed. The file may have no audio track or use a codec macOS cannot decode. Install ffmpeg (`brew install ffmpeg`) for broader format support."
        )
    }

    private func extractWavWithAVFoundation(
        asset: AVURLAsset,
        tracks: [AVAssetTrack],
        outputURL: URL,
        log: @escaping (String) -> Void
    ) async throws {
        guard !tracks.isEmpty else {
            throw PipelineError.unsupportedInput
        }
        let duration = try await asset.load(.duration)

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        // Настройки 16 kHz mono PCM s16le — ровно то, что ждут mlx-whisper и pyannote.
        let pcmSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: .zero, duration: duration)

        let readerOutput: AVAssetReaderOutput
        if tracks.count == 1 {
            let trackOutput = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: pcmSettings)
            trackOutput.alwaysCopiesSampleData = false
            readerOutput = trackOutput
        } else {
            // Несколько аудио-дорожек (типичный кейс — наша запись с системным звуком + микрофоном).
            // Шаг 1: замеряем пик каждой дорожки, чтобы выровнять громкости.
            log("Detected \(tracks.count) audio tracks — measuring per-track levels for normalization…")
            var peaks: [Float] = []
            for (idx, track) in tracks.enumerated() {
                let p = try await measureTrackPeak(asset: asset, track: track)
                log(String(format: "Audio track %d peak: %.4f", idx + 1, p))
                peaks.append(p)
            }

            // Шаг 2: считаем громкости. Цель — выровнять активные дорожки и гарантировать
            // отсутствие клиппинга в сумме. AVAudioMix допускает только громкость в [0, 1],
            // поэтому мы лишь приглушаем — самую тихую активную дорожку используем как референс.
            let activityFloor: Float = 0.01           // ниже -40 dBFS считаем «тишиной»
            let safeTargetPerTrack: Float = 0.9 / Float(tracks.count)
            let activePeaks = peaks.filter { $0 >= activityFloor }
            let referencePeak = activePeaks.min() ?? peaks.max() ?? safeTargetPerTrack
            let target = min(referencePeak, safeTargetPerTrack)

            let gains: [Float] = peaks.map { peak in
                let denom = max(peak, 1e-3)
                return min(target / denom, 1.0)
            }
            for (idx, g) in gains.enumerated() {
                log(String(format: "Audio track %d mix gain: %.2fx", idx + 1, g))
            }

            let mixOutput = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: pcmSettings)
            mixOutput.alwaysCopiesSampleData = false

            let audioMix = AVMutableAudioMix()
            audioMix.inputParameters = zip(tracks, gains).map { track, gain in
                let params = AVMutableAudioMixInputParameters(track: track)
                params.setVolume(gain, at: .zero)
                return params
            }
            mixOutput.audioMix = audioMix
            readerOutput = mixOutput
        }

        guard reader.canAdd(readerOutput) else {
            throw PipelineError.unsupportedInput
        }
        reader.add(readerOutput)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .wav)
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: pcmSettings)
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else {
            throw PipelineError.unsupportedInput
        }
        writer.add(writerInput)

        guard writer.startWriting() else {
            throw writer.error ?? PipelineError.unsupportedInput
        }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else {
            throw reader.error ?? PipelineError.unsupportedInput
        }

        let queue = DispatchQueue(label: "transcriber.audio.extraction")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writerInput.requestMediaDataWhenReady(on: queue) {
                while writerInput.isReadyForMoreMediaData {
                    if reader.status != .reading {
                        writerInput.markAsFinished()
                        if reader.status == .failed {
                            writer.cancelWriting()
                            continuation.resume(throwing: reader.error ?? PipelineError.unsupportedInput)
                            return
                        }
                        writer.finishWriting {
                            if writer.status == .completed {
                                continuation.resume(returning: ())
                            } else {
                                continuation.resume(throwing: writer.error ?? PipelineError.unsupportedInput)
                            }
                        }
                        return
                    }

                    guard let buffer = readerOutput.copyNextSampleBuffer() else {
                        writerInput.markAsFinished()
                        if reader.status == .failed {
                            writer.cancelWriting()
                            continuation.resume(throwing: reader.error ?? PipelineError.unsupportedInput)
                            return
                        }
                        writer.finishWriting {
                            if writer.status == .completed {
                                continuation.resume(returning: ())
                            } else {
                                continuation.resume(throwing: writer.error ?? PipelineError.unsupportedInput)
                            }
                        }
                        return
                    }

                    if !writerInput.append(buffer) {
                        reader.cancelReading()
                        writer.cancelWriting()
                        continuation.resume(throwing: writer.error ?? PipelineError.unsupportedInput)
                        return
                    }
                }
            }
        }
    }

    /// Однопроходно считывает дорожку как Float32 mono 16 kHz и возвращает максимальный абсолютный
    /// сэмпл — это наша оценка пика для последующего выравнивания громкости при миксе.
    private func measureTrackPeak(asset: AVURLAsset, track: AVAssetTrack) async throws -> Float {
        let floatSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false
        ]

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: floatSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw PipelineError.unsupportedInput
        }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? PipelineError.unsupportedInput
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Float, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var peak: Float = 0
                while reader.status == .reading {
                    guard let buffer = output.copyNextSampleBuffer() else { break }
                    if let blockBuffer = CMSampleBufferGetDataBuffer(buffer) {
                        var totalLength = 0
                        var dataPointer: UnsafeMutablePointer<Int8>?
                        let status = CMBlockBufferGetDataPointer(
                            blockBuffer,
                            atOffset: 0,
                            lengthAtOffsetOut: nil,
                            totalLengthOut: &totalLength,
                            dataPointerOut: &dataPointer
                        )
                        if status == kCMBlockBufferNoErr, let raw = dataPointer {
                            let count = totalLength / MemoryLayout<Float>.size
                            raw.withMemoryRebound(to: Float.self, capacity: count) { floatPtr in
                                for i in 0..<count {
                                    let v = Swift.abs(floatPtr[i])
                                    if v > peak { peak = v }
                                }
                            }
                        }
                    }
                }
                if reader.status == .failed {
                    continuation.resume(throwing: reader.error ?? PipelineError.unsupportedInput)
                } else {
                    continuation.resume(returning: peak)
                }
            }
        }
    }

    private func findFFmpegPath() -> String? {
        let ffmpegCandidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ]
        return ffmpegCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    private func convertToWav(
        sourcePath: String,
        destinationPath: String,
        ffmpegPath: String?,
        audioStreamCount: Int,
        log: @escaping (String) -> Void
    ) async throws {
        guard let ffmpegPath else {
            throw PipelineError.dependencyMissing(
                message: "ffmpeg is missing. Install it with `brew install ffmpeg`."
            )
        }

        var arguments: [String] = ["-y", "-i", sourcePath]

        // Если в источнике несколько аудио-потоков (наш .mov с системным звуком + микрофоном
        // через ffmpeg-фолбэк, либо чужой контейнер с несколькими дорожками) — нормализуем
        // громкость каждой дорожки через `loudnorm` и суммируем без дополнительного деления.
        if audioStreamCount > 1 {
            let n = audioStreamCount
            var parts: [String] = []
            var mixInputs: [String] = []
            for i in 0..<n {
                parts.append("[0:a:\(i)]loudnorm=I=-16:TP=-1.5:LRA=11[a\(i)]")
                mixInputs.append("[a\(i)]")
            }
            parts.append("\(mixInputs.joined())amix=inputs=\(n):normalize=0:duration=longest")
            arguments.append(contentsOf: ["-filter_complex", parts.joined(separator: ";")])
        }

        arguments.append(contentsOf: [
            "-ar", "16000",
            "-ac", "1",
            "-c:a", "pcm_s16le",
            destinationPath
        ])

        let output = try await ProcessRunner.shared.run(
            executable: ffmpegPath,
            arguments: arguments,
            onStderr: { line in
                if !line.isEmpty {
                    log(line)
                }
            }
        )

        if output.exitCode != 0 {
            throw PipelineError.dependencyMissing(
                message: "ffmpeg conversion failed. Source file could not be opened or decoded."
            )
        }
    }
}

final class WhisperService: WhisperServicing {
    func transcribe(
        audioURL: URL,
        python: PythonCommand,
        language: String,
        model: String,
        prompt: String,
        hfToken: String,
        log: @escaping (String) -> Void,
        shouldCancel: @escaping () -> Bool
    ) async throws -> [TranscriptionSegment] {
        guard let scriptURL = ScriptLocator.findScript(named: "transcribe") else {
            throw PipelineError.missingScript(name: "transcribe.py")
        }

        let resolvedModel = normalizeWhisperModel(model)
        let normalizedToken = hfToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        var didLogPayloadSummary = false

        var arguments: [String] = [
            scriptURL.path,
            "--input", audioURL.path,
            "--language", language,
            "--model", resolvedModel
        ]
        if !trimmedPrompt.isEmpty {
            arguments.append(contentsOf: ["--prompt", trimmedPrompt])
        }

        let output = try await ProcessRunner.shared.run(
            executable: python.executable,
            arguments: python.makeArguments(arguments),
            environment: [
                "HF_TOKEN": normalizedToken,
                "HUGGINGFACE_TOKEN": normalizedToken
            ],
            onStdout: { line in
                if !line.isEmpty {
                    if line.hasPrefix("{\"segments\":") {
                        if !didLogPayloadSummary {
                            didLogPayloadSummary = true
                            log("Transcription payload received.")
                        }
                        return
                    }
                    log(line)
                }
            },
            onStderr: { line in
                if !line.isEmpty {
                    log("stderr: \(line)")
                }
            },
            shouldCancel: shouldCancel
        )

        if shouldCancel() {
            throw PipelineError.cancelled
        }
        guard output.exitCode == 0 else {
            let detail = output.stderrLines.last ?? output.stdoutLines.last ?? "Unknown transcription error."
            throw PipelineError.dependencyMissing(message: "Transcription failed: \(detail)")
        }

        guard let payload: TranscriptionPayload = decodeLastJSONPayload(from: output.stdoutLines) else {
            throw PipelineError.dependencyMissing(
                message: "Transcription output did not include valid JSON payload. Check processing logs for details."
            )
        }
        return payload.segments
    }

    private func decodeLastJSONPayload<T: Decodable>(from lines: [String]) -> T? {
        let decoder = JSONDecoder()
        for line in lines.reversed() {
            guard let data = line.data(using: .utf8) else { continue }
            if let decoded = try? decoder.decode(T.self, from: data) {
                return decoded
            }
        }
        return nil
    }

    private func normalizeWhisperModel(_ model: String) -> String {
        switch model {
        case "tiny", "whisper-tiny":
            return "mlx-community/whisper-tiny"
        case "base", "whisper-base":
            return "mlx-community/whisper-base"
        case "small", "whisper-small":
            return "mlx-community/whisper-small"
        case "medium", "whisper-medium":
            return "mlx-community/whisper-medium"
        case "large-v3-turbo", "whisper-large-v3-turbo":
            return "mlx-community/whisper-large-v3-turbo"
        default:
            return model
        }
    }
}

final class DiarizationService: DiarizationServicing {
    func diarize(
        audioURL: URL,
        python: PythonCommand,
        hfToken: String,
        log: @escaping (String) -> Void,
        shouldCancel: @escaping () -> Bool
    ) async throws -> [DiarizationInterval] {
        guard let scriptURL = ScriptLocator.findScript(named: "diarize") else {
            throw PipelineError.missingScript(name: "diarize.py")
        }
        var didLogPayloadSummary = false

        let output = try await ProcessRunner.shared.run(
            executable: python.executable,
            arguments: python.makeArguments([
                scriptURL.path,
                "--input", audioURL.path
            ]),
            environment: [
                "HUGGINGFACE_TOKEN": hfToken
            ],
            onStdout: { line in
                if !line.isEmpty {
                    if line.hasPrefix("{\"intervals\":") {
                        if !didLogPayloadSummary {
                            didLogPayloadSummary = true
                            log("Diarization payload received.")
                        }
                        return
                    }
                    log(line)
                }
            },
            onStderr: { line in
                if !line.isEmpty {
                    log("stderr: \(line)")
                }
            },
            shouldCancel: shouldCancel
        )

        if shouldCancel() {
            throw PipelineError.cancelled
        }
        guard output.exitCode == 0 else {
            let detail = output.stderrLines.last ?? output.stdoutLines.last ?? "Unknown diarization error."
            throw PipelineError.dependencyMissing(message: "Diarization failed: \(detail)")
        }

        guard let payload: DiarizationPayload = decodeLastJSONPayload(from: output.stdoutLines) else {
            throw PipelineError.dependencyMissing(
                message: "Diarization output did not include valid JSON payload. Check processing logs for details."
            )
        }
        return payload.intervals
    }

    private func decodeLastJSONPayload<T: Decodable>(from lines: [String]) -> T? {
        let decoder = JSONDecoder()
        for line in lines.reversed() {
            guard let data = line.data(using: .utf8) else { continue }
            if let decoded = try? decoder.decode(T.self, from: data) {
                return decoded
            }
        }
        return nil
    }
}

final class VoiceEmbeddingService: VoiceEmbeddingServicing {
    func embed(
        audioURL: URL,
        intervals: [DiarizationInterval],
        python: PythonCommand,
        hfToken: String,
        log: @escaping (String) -> Void,
        shouldCancel: @escaping () -> Bool
    ) async throws -> [SpeakerEmbedding] {
        guard let scriptURL = ScriptLocator.findScript(named: "embed") else {
            throw PipelineError.missingScript(name: "embed.py")
        }

        let intervalsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("intervals-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: intervalsURL) }

        let payload = DiarizationPayload(intervals: intervals)
        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        let data = try encoder.encode(payload)
        try data.write(to: intervalsURL, options: .atomic)

        var didLogPayloadSummary = false

        let output = try await ProcessRunner.shared.run(
            executable: python.executable,
            arguments: python.makeArguments([
                scriptURL.path,
                "--input", audioURL.path,
                "--intervals", intervalsURL.path
            ]),
            environment: [
                "HUGGINGFACE_TOKEN": hfToken,
                "HF_TOKEN": hfToken
            ],
            onStdout: { line in
                if !line.isEmpty {
                    if line.hasPrefix("{\"embeddings\":") {
                        if !didLogPayloadSummary {
                            didLogPayloadSummary = true
                            log("Voice embeddings payload received.")
                        }
                        return
                    }
                    log(line)
                }
            },
            onStderr: { line in
                if !line.isEmpty {
                    log("stderr: \(line)")
                }
            },
            shouldCancel: shouldCancel
        )

        if shouldCancel() {
            throw PipelineError.cancelled
        }
        guard output.exitCode == 0 else {
            let detail = output.stderrLines.last ?? output.stdoutLines.last ?? "Unknown embedding error."
            throw PipelineError.dependencyMissing(message: "Voice embedding failed: \(detail)")
        }

        guard let parsed: SpeakerEmbeddingPayload = decodeLastJSONPayload(from: output.stdoutLines) else {
            throw PipelineError.dependencyMissing(
                message: "Voice embedding output did not include valid JSON payload. Check logs for details."
            )
        }
        return parsed.embeddings
    }

    private func decodeLastJSONPayload<T: Decodable>(from lines: [String]) -> T? {
        let decoder = JSONDecoder()
        for line in lines.reversed() {
            guard let data = line.data(using: .utf8) else { continue }
            if let decoded = try? decoder.decode(T.self, from: data) {
                return decoded
            }
        }
        return nil
    }
}

final class ResultMerger: ResultMerging {
    func merge(
        transcription: [TranscriptionSegment],
        diarization: [DiarizationInterval]
    ) -> [DiarizedBlock] {
        var blocks: [DiarizedBlock] = []

        for segment in transcription {
            let midpoint = (segment.start + segment.end) / 2
            let speaker = diarization.first(where: { midpoint >= $0.start && midpoint <= $0.end })?.speakerID ?? "SPEAKER_00"
            if let last = blocks.last, last.speakerID == speaker {
                let merged = DiarizedBlock(
                    start: last.start,
                    speakerID: speaker,
                    text: "\(last.text) \(segment.text)".trimmingCharacters(in: .whitespacesAndNewlines)
                )
                blocks[blocks.count - 1] = merged
            } else {
                blocks.append(DiarizedBlock(
                    start: segment.start,
                    speakerID: speaker,
                    text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                ))
            }
        }

        return blocks
    }
}

final class ResultSaver: ResultSaving {
    func save(
        blocks: [DiarizedBlock],
        sourceURL: URL,
        mode: SaveMode,
        fixedFolder: URL?
    ) throws -> URL {
        let outputDirectory: URL
        switch mode {
        case .nearSource:
            outputDirectory = sourceURL.deletingLastPathComponent()
        case .fixedFolder:
            if let fixedFolder {
                outputDirectory = fixedFolder
            } else {
                outputDirectory = sourceURL.deletingLastPathComponent()
            }
        }

        let outputName = sourceURL.deletingPathExtension().lastPathComponent + "_diarized.txt"
        let outputURL = outputDirectory.appendingPathComponent(outputName)

        let content = blocks
            .map { block in
                "[\(formatTime(block.start))] \(block.speakerID): \(block.text)"
            }
            .joined(separator: "\n")

        try content.write(to: outputURL, atomically: true, encoding: .utf8)
        return outputURL
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let totalSeconds = max(Int(time), 0)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

final class DependencyValidator: DependencyValidating {
    func validate(
        requireDiarization: Bool,
        hfTokenRequired: Bool,
        python: PythonCommand,
        log: @escaping (String) -> Void
    ) async throws {
        let pythonCheck = try await ProcessRunner.shared.run(
            executable: python.executable,
            arguments: python.makeArguments(["--version"])
        )
        guard pythonCheck.exitCode == 0 else {
            throw PipelineError.dependencyMissing(message: "Python 3.10+ is required.")
        }
        if let versionLine = pythonCheck.stdoutLines.first ?? pythonCheck.stderrLines.first {
            log("Python runtime: \(versionLine)")
        }

        let whisperCheck = try await ProcessRunner.shared.run(
            executable: python.executable,
            arguments: python.makeArguments(["-c", "import mlx_whisper"])
        )
        guard whisperCheck.exitCode == 0 else {
            throw PipelineError.dependencyMissing(message: "mlx-whisper is missing in the selected runtime.")
        }

        if requireDiarization {
            let pyannoteCheck = try await ProcessRunner.shared.run(
                executable: python.executable,
                arguments: python.makeArguments(["-c", "import pyannote.audio"])
            )
            guard pyannoteCheck.exitCode == 0 else {
                throw PipelineError.dependencyMissing(message: "pyannote.audio is missing in the selected runtime.")
            }
        }

        if hfTokenRequired {
            let token = KeychainHelper.shared.loadToken() ?? ""
            if token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw PipelineError.missingHFToken
            }
        }
    }
}

final class ReadinessService: ReadinessChecking {
    private let dependencyValidator: DependencyValidating

    init(dependencyValidator: DependencyValidating = DependencyValidator()) {
        self.dependencyValidator = dependencyValidator
    }

    func evaluateReadiness(
        python: PythonCommand,
        log: @escaping (String) -> Void
    ) async throws -> ReadinessReport {
        try await dependencyValidator.validate(
            requireDiarization: false,
            hfTokenRequired: false,
            python: python,
            log: log
        )

        let token = (KeychainHelper.shared.loadToken() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            return ReadinessReport(
                transcriptionReady: true,
                diarizationReady: false,
                recommendedMode: .transcriptionOnly,
                userMessage: "Hugging Face token is missing. Transcription will continue without speaker diarization."
            )
        }

        let pyannoteCheck = try await ProcessRunner.shared.run(
            executable: python.executable,
            arguments: python.makeArguments(["-c", "import pyannote.audio"])
        )
        guard pyannoteCheck.exitCode == 0 else {
            return ReadinessReport(
                transcriptionReady: true,
                diarizationReady: false,
                recommendedMode: .transcriptionOnly,
                userMessage: "pyannote.audio is not installed in the selected runtime. Transcription will continue without speaker diarization."
            )
        }

        let modelAccessCheck = try await ProcessRunner.shared.run(
            executable: python.executable,
            arguments: python.makeArguments([
                "-c",
                """
                import os
                import sys
                token = os.getenv("HUGGINGFACE_TOKEN", "").strip()
                if not token:
                    sys.exit(2)
                try:
                    from huggingface_hub import HfApi
                    HfApi().model_info("pyannote/speaker-diarization-3.1", token=token)
                    sys.exit(0)
                except Exception as exc:
                    print(str(exc))
                    sys.exit(1)
                """
            ]),
            environment: [
                "HUGGINGFACE_TOKEN": token
            ]
        )

        if modelAccessCheck.exitCode != 0 {
            let detail = modelAccessCheck.stdoutLines.last ?? modelAccessCheck.stderrLines.last ?? "Missing model access or model agreements were not accepted."
            return ReadinessReport(
                transcriptionReady: true,
                diarizationReady: false,
                recommendedMode: .transcriptionOnly,
                userMessage: "Diarization model access is unavailable (\(detail)). Transcription will continue without speaker diarization."
            )
        }

        return ReadinessReport(
            transcriptionReady: true,
            diarizationReady: true,
            recommendedMode: .fullPipeline,
            userMessage: "Runtime is fully ready. Full pipeline will be used."
        )
    }
}

enum InputFileValidator {
    static let supportedExtensions: Set<String> = [
        "webm", "mov", "mp4", "m4a", "wav", "mp3", "ogg", "flac", "mkv", "aac"
    ]

    static func isSupported(url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }
}

enum FolderPicker {
    static func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.title = "Select save folder"
        return panel.runModal() == .OK ? panel.url : nil
    }
}
