import AppKit
import Combine

/// AppKit menu-bar controller that mirrors the controller's state with an
/// `NSStatusItem`. Left-click while recording stops the recording directly
/// (no menu pop-up); any other click shows the full menu.
@MainActor
final class RecordingStatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let controller: RecordingController
    private let menu = NSMenu()
    private var cancellables: Set<AnyCancellable> = []

    init(controller: RecordingController) {
        self.controller = controller
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        updateStatusButton()
        menu.delegate = self

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusButtonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Re-render the icon whenever recording state changes.
        controller.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusButton()
            }
            .store(in: &cancellables)
    }

    @objc private func statusButtonClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isSecondaryClick =
            event?.type == .rightMouseUp ||
            (event?.modifierFlags.contains(.control) ?? false)

        if controller.isRecording, !isSecondaryClick {
            controller.stopRecording()
            return
        }
        showMenu(from: sender)
    }

    private func showMenu(from button: NSStatusBarButton) {
        // Temporarily attach the menu so the button's built-in popup path is used;
        // `performClick` blocks until the menu is dismissed, after which we detach
        // so the next plain click will re-enter our action handler.
        statusItem.menu = menu
        button.performClick(nil)
        statusItem.menu = nil
    }

    private func updateStatusButton() {
        guard let button = statusItem.button else { return }
        if controller.isRecording {
            let cfg = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            let image = NSImage(systemSymbolName: "record.circle.fill",
                                accessibilityDescription: "Recording")?
                .withSymbolConfiguration(cfg)
            button.image = image
        } else {
            let image = NSImage(systemSymbolName: "record.circle",
                                accessibilityDescription: "openXTranscriber")
            button.image = image
        }
    }

    private func rebuildMenu() {
        RecordingMenuBuilder.populate(
            menu,
            state: controller.state,
            content: controller.availableContent,
            target: self,
            action: #selector(menuAction(_:))
        )
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let cmd = sender.representedObject as? RecordingMenuCommand else { return }
        switch cmd {
        case .start(let target):     controller.startRecording(target: target)
        case .stop:                  controller.stopRecording()
        case .cancel:                controller.cancelRecording()
        case .openSettings(let k):   controller.openSystemSettings(for: k)
        case .openRecordingsFolder:  controller.openOutputFolder()
        case .changeOutputFolder:    controller.chooseOutputFolder()
        case .resetOutputFolder:     controller.resetOutputFolder()
        case .refreshSources:
            Task { @MainActor [weak self] in
                await self?.controller.refreshAvailableContent()
            }
        case .toggleNoiseGate:       controller.toggleNoiseGate()
        case .showApp:               showMainWindow()
        case .showSourcePicker:      showSourcePicker()
        }
    }

    private func showSourcePicker() {
        guard let content = controller.availableContent else { return }
        SourcePickerPanel.present(
            initialContent: content,
            onSelect: { [weak self] target in
                self?.controller.startRecording(target: target)
            }
        )
    }

    private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        }
    }
}

// MARK: - NSMenuDelegate

extension RecordingStatusBarController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        controller.refreshPermissionState()
        rebuildMenu()

        // Kick off a fresh fetch in the background so subsequent opens are up-to-date.
        if case .idle = controller.state {
            Task { @MainActor [weak self] in
                await self?.controller.refreshAvailableContent()
            }
        }
    }
}
