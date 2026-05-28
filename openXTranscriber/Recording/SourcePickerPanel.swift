import AppKit
import SwiftUI

/// Floating panel that hosts the source picker grid. Singleton-style: a new
/// `present` dismisses any prior instance so the picker never doubles up.
@MainActor
final class SourcePickerPanel {
    private static var current: SourcePickerPanel?

    private let panel: PickerPanel
    private let model: SourcePickerModel
    private var keyMonitor: Any?

    static func present(
        initialContent: AvailableContent,
        onSelect: @escaping (CaptureTarget) -> Void
    ) {
        current?.dismiss()
        let p = SourcePickerPanel(initialContent: initialContent, onSelect: onSelect)
        current = p
        p.show()
    }

    private init(
        initialContent: AvailableContent,
        onSelect: @escaping (CaptureTarget) -> Void
    ) {
        let model = SourcePickerModel(content: initialContent)
        self.model = model

        let panel = PickerPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = String(localized: "Choose what to record")
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.center()
        self.panel = panel

        let view = SourcePickerView(
            model: model,
            onSelect: { [weak self] target in
                self?.dismiss()
                onSelect(target)
            },
            onCancel: { [weak self] in
                self?.dismiss()
            }
        )
        let host = NSHostingView(rootView: view)
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
    }

    private func show() {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53, self.panel.isKeyWindow {
                self.dismiss()
                return nil
            }
            return event
        }
    }

    func dismiss() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        panel.orderOut(nil)
        if Self.current === self { Self.current = nil }
    }
}

/// Subclass that opts into key/main behaviour even though `LSUIElement = YES`
/// makes the host app non-activating by default.
private final class PickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
