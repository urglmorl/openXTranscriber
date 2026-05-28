import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit

@MainActor
final class RecordingEngine: NSObject {
    enum State {
        case idle
        case recording(URL)
        case finishing
    }

    enum RecordingError: Error, LocalizedError {
        case alreadyRecording
        case notRecording
        case writerSetup(String)
        case streamSetup(String)
        case writerFinishFailed(status: AVAssetWriter.Status, underlying: Error?, firstAppendError: Error?)
        case noVideoFrames

        var errorDescription: String? {
            switch self {
            case .alreadyRecording:
                return "Recording is already in progress."
            case .notRecording:
                return "No active recording."
            case .writerSetup(let m):
                return "Writer setup failed: \(m)"
            case .streamSetup(let m):
                return "Stream setup failed: \(m)"
            case .noVideoFrames:
                return "No video frames were captured."
            case .writerFinishFailed(let status, let underlying, let firstAppendError):
                var parts = ["Writer failed to finalize.", "status=\(status.debugLabel)."]
                if let err = (underlying ?? firstAppendError) as NSError? {
                    parts.append("domain=\(err.domain) code=\(err.code)")
                    parts.append(err.localizedDescription)
                    if let reason = err.localizedFailureReason {
                        parts.append("reason=\(reason)")
                    }
                }
                if underlying == nil, let fae = firstAppendError as NSError? {
                    parts.append("(first append failure: \(fae.domain) \(fae.code) — \(fae.localizedDescription))")
                }
                return parts.joined(separator: " ")
            }
        }
    }

    private(set) var state: State = .idle
    var onError: ((Error) -> Void)?

    private var stream: SCStream?
    private var microphone: MicrophoneCapture?

    // Writer state — accessed from MainActor (setup / teardown) and writerQueue (append).
    // Discipline: after setup, only writerQueue touches these until teardown.
    nonisolated(unsafe) private var writer: AVAssetWriter?
    nonisolated(unsafe) private var videoInput: AVAssetWriterInput?
    nonisolated(unsafe) private var videoAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    nonisolated(unsafe) private var systemAudioInput: AVAssetWriterInput?
    nonisolated(unsafe) private var micInput: AVAssetWriterInput?
    nonisolated(unsafe) private var sessionStarted = false
    nonisolated(unsafe) private var currentOutputURL: URL?
    nonisolated(unsafe) private var firstAppendError: Error?

    nonisolated private let writerQueue = DispatchQueue(label: "transcriber.recorder.writer", qos: .userInteractive)
    nonisolated private let videoQueue  = DispatchQueue(label: "transcriber.recorder.video",  qos: .userInteractive)
    nonisolated private let audioQueue  = DispatchQueue(label: "transcriber.recorder.audio",  qos: .userInteractive)

    override init() {
        super.init()
    }

    // MARK: - Public API

    func start(target: CaptureTarget) async throws -> URL {
        guard case .idle = state else { throw RecordingError.alreadyRecording }

        let url  = try makeOutputURL()
        let size = target.pixelSize

        try setupWriter(at: url, size: size)

        let config = SCStreamConfiguration()
        config.width  = Int(size.width)
        config.height = Int(size.height)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = true
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.queueDepth = 5

        let newStream = SCStream(filter: target.contentFilter, configuration: config, delegate: self)
        do {
            try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
            try newStream.addStreamOutput(self, type: .audio,  sampleHandlerQueue: audioQueue)
        } catch {
            teardownWriter(removeFile: true)
            throw RecordingError.streamSetup(error.localizedDescription)
        }

        let mic = MicrophoneCapture()
        mic.noiseGateEnabled = RecordingSettings.noiseGateEnabled
        mic.delegate = self
        do {
            try mic.start()
        } catch {
            teardownWriter(removeFile: true)
            throw error
        }

        do {
            try await newStream.startCapture()
        } catch {
            mic.stop()
            teardownWriter(removeFile: true)
            throw RecordingError.streamSetup(error.localizedDescription)
        }

        self.stream = newStream
        self.microphone = mic
        self.state = .recording(url)
        return url
    }

    func stop() async throws -> URL {
        guard case .recording(let url) = state else { throw RecordingError.notRecording }
        state = .finishing

        await finalizeCapture()
        let result = await finishWriter(removeFile: false)
        state = .idle

        switch result {
        case .success:         return url
        case .failure(let e):  throw e
        }
    }

    func cancel() async {
        guard case .recording = state else { return }
        state = .finishing

        await finalizeCapture()
        _ = await finishWriter(removeFile: true)
        state = .idle
    }

    // MARK: - Setup / teardown

    private func setupWriter(at url: URL, size: CGSize) throws {
        let w: AVAssetWriter
        do {
            w = try AVAssetWriter(outputURL: url, fileType: .mov)
        } catch {
            throw RecordingError.writerSetup(error.localizedDescription)
        }

        let width  = Int(size.width)
        let height = Int(size.height)

        let compressionProperties: [String: Any] = [
            AVVideoAverageBitRateKey: max(2_000_000, min(20_000_000, width * height * 4)),
            AVVideoMaxKeyFrameIntervalKey: 120,
        ]
        let colorProperties: [String: Any] = [
            AVVideoColorPrimariesKey:   AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey:      AVVideoYCbCrMatrix_ITU_R_709_2,
        ]
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey:  AVVideoCodecType.hevc,
            AVVideoWidthKey:  width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compressionProperties,
            AVVideoColorPropertiesKey:       colorProperties,
        ])
        video.expectsMediaDataInRealTime = true
        guard w.canAdd(video) else { throw RecordingError.writerSetup("cannot add video input") }
        w.add(video)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: video,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey  as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )

        let audioSettings: [String: Any] = [
            AVFormatIDKey:         kAudioFormatMPEG4AAC,
            AVSampleRateKey:       48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey:   128_000,
        ]
        let sysAudio = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        sysAudio.expectsMediaDataInRealTime = true
        guard w.canAdd(sysAudio) else { throw RecordingError.writerSetup("cannot add system audio input") }
        w.add(sysAudio)

        let mic = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        mic.expectsMediaDataInRealTime = true
        guard w.canAdd(mic) else { throw RecordingError.writerSetup("cannot add microphone input") }
        w.add(mic)

        guard w.startWriting() else {
            throw RecordingError.writerSetup(w.error?.localizedDescription ?? "startWriting failed")
        }

        self.writer = w
        self.videoInput = video
        self.videoAdaptor = adaptor
        self.systemAudioInput = sysAudio
        self.micInput = mic
        self.sessionStarted = false
        self.currentOutputURL = url
        self.firstAppendError = nil
    }

    private func teardownWriter(removeFile: Bool) {
        let url = currentOutputURL
        writer = nil
        videoInput = nil
        videoAdaptor = nil
        systemAudioInput = nil
        micInput = nil
        sessionStarted = false
        currentOutputURL = nil
        firstAppendError = nil
        if removeFile, let url {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func finalizeCapture() async {
        if let s = stream {
            try? await s.stopCapture()
        }
        stream = nil
        microphone?.stop()
        microphone = nil
    }

    private func finishWriter(removeFile: Bool) async -> Result<Void, Error> {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result<Void, Error>, Never>) in
            writerQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: .success(()))
                    return
                }
                self.videoInput?.markAsFinished()
                self.systemAudioInput?.markAsFinished()
                self.micInput?.markAsFinished()

                guard let w = self.writer else {
                    continuation.resume(returning: .success(()))
                    return
                }
                let url = self.currentOutputURL

                w.finishWriting {
                    let status = w.status
                    let err    = w.error
                    let firstAppendErr = self.firstAppendError
                    let sessionStarted = self.sessionStarted
                    if removeFile, let url {
                        try? FileManager.default.removeItem(at: url)
                    }
                    self.writerQueue.async {
                        self.writer = nil
                        self.videoInput = nil
                        self.videoAdaptor = nil
                        self.systemAudioInput = nil
                        self.micInput = nil
                        self.sessionStarted = false
                        self.currentOutputURL = nil
                        self.firstAppendError = nil
                    }
                    if status == .failed || status == .unknown {
                        continuation.resume(returning: .failure(RecordingError.writerFinishFailed(status: status, underlying: err, firstAppendError: firstAppendErr)))
                    } else if !sessionStarted {
                        continuation.resume(returning: .failure(RecordingError.noVideoFrames))
                    } else {
                        continuation.resume(returning: .success(()))
                    }
                }
            }
        }
    }

    private func makeOutputURL() throws -> URL {
        let dir = RecordingSettings.outputFolderURL
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        let filename = "Recording-\(formatter.string(from: Date())).mov"
        return dir.appendingPathComponent(filename)
    }
}

// MARK: - SCStreamOutput

extension RecordingEngine: SCStreamOutput {
    nonisolated func stream(_ stream: SCStream,
                            didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                            of type: SCStreamOutputType) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        switch type {
        case .screen:
            writerQueue.async { [weak self] in self?.handleVideo(sampleBuffer) }
        case .audio:
            writerQueue.async { [weak self] in self?.handleSystemAudio(sampleBuffer) }
        default:
            break  // .microphone (macOS 15+) — we use AVFoundation for mic instead
        }
    }

    nonisolated private func handleVideo(_ buffer: CMSampleBuffer) {
        guard let w = writer, let input = videoInput, let adaptor = videoAdaptor else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        if !sessionStarted {
            w.startSession(atSourceTime: pts)
            sessionStarted = true
        }
        guard input.isReadyForMoreMediaData else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else { return }
        if !adaptor.append(pixelBuffer, withPresentationTime: pts) {
            recordAppendFailure(writer: w)
        }
    }

    nonisolated private func handleSystemAudio(_ buffer: CMSampleBuffer) {
        guard sessionStarted, let w = writer, let input = systemAudioInput, input.isReadyForMoreMediaData else { return }
        if !input.append(buffer) {
            recordAppendFailure(writer: w)
        }
    }

    nonisolated fileprivate func handleMic(_ buffer: CMSampleBuffer) {
        guard sessionStarted, let w = writer, let input = micInput, input.isReadyForMoreMediaData else { return }
        if !input.append(buffer) {
            recordAppendFailure(writer: w)
        }
    }

    nonisolated private func recordAppendFailure(writer: AVAssetWriter) {
        if firstAppendError == nil {
            firstAppendError = writer.error
        }
    }
}

// MARK: - SCStreamDelegate

extension RecordingEngine: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.onError?(error)
        }
    }
}

// MARK: - MicrophoneCaptureDelegate

extension RecordingEngine: MicrophoneCaptureDelegate {
    nonisolated func microphoneCapture(_ capture: MicrophoneCapture, didOutput buffer: CMSampleBuffer) {
        writerQueue.async { [weak self] in
            self?.handleMic(buffer)
        }
    }
}

// MARK: - AVAssetWriter.Status debug label

extension AVAssetWriter.Status {
    nonisolated var debugLabel: String {
        switch self {
        case .unknown:    return "unknown"
        case .writing:    return "writing"
        case .completed:  return "completed"
        case .failed:     return "failed"
        case .cancelled:  return "cancelled"
        @unknown default: return "unknown(\(rawValue))"
        }
    }
}
