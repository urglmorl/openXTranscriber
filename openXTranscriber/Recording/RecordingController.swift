import AppKit
import Combine
import Foundation
import ScreenCaptureKit

@MainActor
final class RecordingController: ObservableObject {
    enum State: Equatable {
        case idle
        case needsScreenRecording
        case recording(startedAt: Date, url: URL)

        var isRecording: Bool {
            if case .recording = self { return true }
            return false
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var availableContent: AvailableContent?
    @Published private(set) var elapsedSeconds: Int = 0

    /// When non-nil, the UI should present a "Transcribe this recording?"
    /// confirmation. Cleared when the user makes a choice or dismisses it.
    @Published var pendingTranscriptionURL: URL?

    /// When non-nil, the UI should show a "Permission required" dialog with
    /// a button that opens System Settings — set when starting a recording
    /// fails because mic / screen-recording access is denied.
    @Published var pendingPermissionPrompt: PermissionKind?

    @Published var errorMessage: String?

    private let engine = RecordingEngine()
    private let permissions = PermissionsManager.shared

    /// Guards against double-tap during async start/stop transitions.
    private var isTransitioning = false
    private var elapsedTimer: Timer?

    init() {
        engine.onError = { [weak self] error in
            self?.handleEngineError(error)
        }
        refreshPermissionState()
        Task { @MainActor [weak self] in
            await self?.refreshAvailableContent()
        }
    }

    var isRecording: Bool { state.isRecording }

    var elapsedString: String {
        String(format: "%02d:%02d", elapsedSeconds / 60, elapsedSeconds % 60)
    }

    // MARK: - Permissions / content

    func refreshPermissionState() {
        if case .recording = state { return }
        let snap = permissions.snapshot()
        state = snap.screenRecording ? .idle : .needsScreenRecording
    }

    func refreshAvailableContent() async {
        guard let fetched = try? await SharedContent.fetch() else { return }
        availableContent = fetched
    }

    func openSystemSettings(for kind: PermissionKind) {
        permissions.openSystemSettings(for: kind)
    }

    // MARK: - Output folder & noise gate (settings actions)

    func openOutputFolder() {
        let folder = RecordingSettings.outputFolderURL
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose a folder for screen recordings."
        panel.directoryURL = RecordingSettings.outputFolderURL
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            RecordingSettings.setOutputFolder(url)
            objectWillChange.send()
        }
    }

    func resetOutputFolder() {
        RecordingSettings.resetOutputFolder()
        objectWillChange.send()
    }

    func toggleNoiseGate() {
        RecordingSettings.setNoiseGateEnabled(!RecordingSettings.noiseGateEnabled)
        objectWillChange.send()
    }

    func dismissError() {
        errorMessage = nil
    }

    // MARK: - Recording lifecycle

    func startRecording(target: CaptureTarget) {
        guard !isTransitioning else { return }
        guard case .idle = state else { return }
        isTransitioning = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isTransitioning = false }
            let micOK = await self.permissions.requestMicrophone()
            guard micOK else {
                self.pendingPermissionPrompt = .microphone
                return
            }
            do {
                let url = try await self.engine.start(target: target)
                self.state = .recording(startedAt: Date(), url: url)
                self.startElapsedTicker()
            } catch {
                self.refreshPermissionState()
                if case .needsScreenRecording = self.state {
                    self.pendingPermissionPrompt = .screenRecording
                } else {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    /// Quick action — starts a recording of the main display if permissions
    /// are in place and content has been fetched. Useful for the toolbar
    /// "tap to start" button when we don't want to show a target picker.
    func startMainDisplayRecording() {
        if case .needsScreenRecording = state {
            errorMessage = String(localized: "Screen Recording permission is required. Grant it in System Settings, then try again.")
            permissions.openSystemSettings(for: .screenRecording)
            return
        }
        guard let main = availableContent?.mainDisplay else {
            // Content not yet fetched — fetch and retry once.
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.refreshAvailableContent()
                if let main = self.availableContent?.mainDisplay {
                    self.startRecording(target: .display(main))
                } else {
                    self.errorMessage = String(localized: "No display available to record.")
                }
            }
            return
        }
        startRecording(target: .display(main))
    }

    func stopRecording() {
        guard !isTransitioning else { return }
        guard case .recording = state else { return }
        isTransitioning = true
        stopElapsedTicker()
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isTransitioning = false }
            do {
                let url = try await self.engine.stop()
                self.state = .idle
                self.presentTranscriptionPrompt(for: url)
            } catch {
                self.state = .idle
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func cancelRecording() {
        guard !isTransitioning else { return }
        guard case .recording = state else { return }
        isTransitioning = true
        stopElapsedTicker()
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isTransitioning = false }
            await self.engine.cancel()
            self.state = .idle
        }
    }

    // MARK: - Engine error (capture source ended unexpectedly)

    private func handleEngineError(_ error: Error) {
        guard case .recording = state else { return }
        isTransitioning = true
        stopElapsedTicker()
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isTransitioning = false }
            do {
                let url = try await self.engine.stop()
                self.state = .idle
                self.errorMessage = String(localized: "The capture source ended. The partial recording was saved.")
                self.presentTranscriptionPrompt(for: url)
            } catch {
                self.state = .idle
                self.errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Helpers

    private func presentTranscriptionPrompt(for url: URL) {
        NSApp.activate(ignoringOtherApps: true)
        pendingTranscriptionURL = url
    }

    private func startElapsedTicker() {
        stopElapsedTicker()
        elapsedSeconds = 0
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if case .recording(let startedAt, _) = self.state {
                    self.elapsedSeconds = max(0, Int(Date().timeIntervalSince(startedAt)))
                } else {
                    self.stopElapsedTicker()
                }
            }
        }
        // Use .common run-loop mode so the timer keeps firing while menus are tracking events.
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    private func stopElapsedTicker() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }
}
