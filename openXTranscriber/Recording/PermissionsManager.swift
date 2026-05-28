import AppKit
import AVFoundation
import CoreGraphics

struct PermissionsSnapshot {
    let screenRecording: Bool
    let microphone: MicrophonePermission
}

enum MicrophonePermission {
    case authorized
    case denied
    case notDetermined
    case restricted
}

enum PermissionKind {
    case screenRecording
    case microphone
}

@MainActor
final class PermissionsManager {
    static let shared = PermissionsManager()

    func snapshot() -> PermissionsSnapshot {
        PermissionsSnapshot(
            screenRecording: CGPreflightScreenCaptureAccess(),
            microphone: microphoneStatus()
        )
    }

    @discardableResult
    func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        @unknown default:
            return false
        }
    }

    func openSystemSettings(for kind: PermissionKind) {
        let urlString: String
        switch kind {
        case .screenRecording:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case .microphone:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        }
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    func showScreenRecordingRestartAlert() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording permission granted"
        alert.informativeText = "Quit and reopen openXTranscriber for the permission to take effect."
        alert.addButton(withTitle: "Quit openXTranscriber")
        alert.alertStyle = .informational
        alert.runModal()
        NSApp.terminate(nil)
    }

    private func microphoneStatus() -> MicrophonePermission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:    return .authorized
        case .denied:        return .denied
        case .notDetermined: return .notDetermined
        case .restricted:    return .restricted
        @unknown default:    return .denied
        }
    }
}
