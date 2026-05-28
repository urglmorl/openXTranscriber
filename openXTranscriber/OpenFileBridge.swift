import AppKit
import Foundation
import ServiceManagement

extension Notification.Name {
    static let transcriberOpenFile = Notification.Name("transcriberOpenFile")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let recordingController = RecordingController()
    private var statusBar: RecordingStatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerAsLoginItemIfNeeded()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let first = urls.first else { return }
        NotificationCenter.default.post(name: .transcriberOpenFile, object: first)
    }

    /// Installs the menu-bar recording control. Called from the App scene
    /// once onboarding has completed — we don't want a status item flashing
    /// in the menu bar while the user is still configuring HuggingFace.
    func installRecordingStatusBarItemIfNeeded() {
        guard statusBar == nil else { return }
        statusBar = RecordingStatusBarController(controller: recordingController)
    }

    /// On the very first launch, opt the app into Login Items so it relaunches
    /// after reboot. We only attempt this once — `loginItemRegistrationAttempted`
    /// is the gate. If the user later removes the app from System Settings →
    /// General → Login Items, we respect that and don't re-register.
    private func registerAsLoginItemIfNeeded() {
        let key = "loginItemRegistrationAttempted"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: key) else { return }
        defaults.set(true, forKey: key)

        do {
            try SMAppService.mainApp.register()
        } catch {
            // Non-fatal: the user can enable the launch agent manually from
            // System Settings if registration fails (e.g. on unsigned builds).
            NSLog("openXTranscriber: login-item registration failed — \(error.localizedDescription)")
        }
    }
}
