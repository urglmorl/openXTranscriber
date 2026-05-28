import Accelerate
import AVFoundation
import CoreMedia

protocol MicrophoneCaptureDelegate: AnyObject {
    func microphoneCapture(_ capture: MicrophoneCapture, didOutput buffer: CMSampleBuffer)
}

/// Microphone capture via `AVCaptureSession` (non-ducking — unlike
/// `AVAudioEngine` with Voice Processing I/O, this does not tell macOS
/// we're in a "voice chat" session, so other apps' audio keeps its
/// normal volume while we record).
///
/// When `noiseGateEnabled` is true, each delivered sample buffer is
/// measured (RMS, in Float32-PCM space). If it falls below the gate
/// threshold, the underlying `CMBlockBuffer`'s bytes are zeroed in
/// place before the buffer is handed to the delegate — so quiet periods
/// become actual silence in the recorded mic track, while speech passes
/// through untouched.
nonisolated final class MicrophoneCapture: NSObject, @unchecked Sendable {
    weak var delegate: (any MicrophoneCaptureDelegate)?

    private let session = AVCaptureSession()
    private let output  = AVCaptureAudioDataOutput()
    private let queue   = DispatchQueue(label: "transcriber.mic", qos: .userInteractive)

    /// When true, the RMS-based gate is applied. Read on every sample.
    var noiseGateEnabled = true

    /// RMS threshold (normalized for Float32 PCM, roughly −44 dBFS).
    /// Anything below is treated as silence. Fixed value chosen to sit
    /// below normal speech but above room/HVAC noise.
    private let gateThreshold: Float = 0.006

    enum MicrophoneError: Error, LocalizedError {
        case noMicrophone
        case cannotAddInput
        case cannotAddOutput

        var errorDescription: String? {
            switch self {
            case .noMicrophone:    return "No microphone device was found."
            case .cannotAddInput:  return "Cannot attach the microphone input to the capture session."
            case .cannotAddOutput: return "Cannot attach the audio output to the capture session."
            }
        }
    }

    override init() { super.init() }

    func start() throws {
        guard !session.isRunning else { return }

        session.beginConfiguration()

        for i in session.inputs  { session.removeInput(i) }
        for o in session.outputs { session.removeOutput(o) }

        guard let device = AVCaptureDevice.default(for: .audio) else {
            session.commitConfiguration()
            throw MicrophoneError.noMicrophone
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw MicrophoneError.cannotAddInput
        }
        session.addInput(input)

        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw MicrophoneError.cannotAddOutput
        }
        session.addOutput(output)

        session.commitConfiguration()
        session.startRunning()
    }

    func stop() {
        guard session.isRunning else { return }
        session.stopRunning()
    }
}

// MARK: - AVCapture delegate

extension MicrophoneCapture: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if noiseGateEnabled, isBelowGate(sampleBuffer) {
            silenceInPlace(sampleBuffer)
        }
        delegate?.microphoneCapture(self, didOutput: sampleBuffer)
    }

    private func isBelowGate(_ buffer: CMSampleBuffer) -> Bool {
        guard
            let formatDesc = CMSampleBufferGetFormatDescription(buffer),
            let asbdPtr    = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        else { return false }
        let asbd = asbdPtr.pointee

        // Only handle Float32 PCM. AVCaptureAudioDataOutput delivers that
        // by default on macOS; if the format is ever different, skip the
        // gate rather than risk misinterpreting bytes.
        let isPCM   = asbd.mFormatID == kAudioFormatLinearPCM
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let is32bit = asbd.mBitsPerChannel == 32
        guard isPCM, isFloat, is32bit else { return false }

        guard let block = CMSampleBufferGetDataBuffer(buffer) else { return false }
        var length = 0
        var rawPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            block,
            atOffset: 0,
            lengthAtOffsetOut: &length,
            totalLengthOut: nil,
            dataPointerOut: &rawPointer
        ) == kCMBlockBufferNoErr, let rawPointer, length > 0 else { return false }

        let count = length / MemoryLayout<Float>.size
        let samples = rawPointer.withMemoryRebound(to: Float.self, capacity: count) { $0 }

        var meanSquare: Float = 0
        vDSP_measqv(samples, 1, &meanSquare, vDSP_Length(count))
        let rms = sqrtf(meanSquare)
        return rms < gateThreshold
    }

    private func silenceInPlace(_ buffer: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { return }
        var length = 0
        var rawPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            block,
            atOffset: 0,
            lengthAtOffsetOut: &length,
            totalLengthOut: nil,
            dataPointerOut: &rawPointer
        ) == kCMBlockBufferNoErr, let rawPointer, length > 0 else { return }
        memset(rawPointer, 0, length)
    }
}
