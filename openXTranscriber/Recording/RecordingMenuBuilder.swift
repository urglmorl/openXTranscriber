import AppKit
import ScreenCaptureKit

enum RecordingMenuCommand {
    case start(CaptureTarget)
    case stop
    case cancel
    case openSettings(PermissionKind)
    case openRecordingsFolder
    case changeOutputFolder
    case resetOutputFolder
    case refreshSources
    case toggleNoiseGate
    case showApp
    case showSourcePicker
}

@MainActor
enum RecordingMenuBuilder {
    /// Populates an existing menu in place. Must be used instead of replacing
    /// `statusItem.menu`, because AppKit reads `statusItem.menu` once before
    /// `menuNeedsUpdate` fires — reassigning it there shows stale content.
    static func populate(
        _ menu: NSMenu,
        state: RecordingController.State,
        content: AvailableContent?,
        target: AnyObject,
        action: Selector
    ) {
        menu.removeAllItems()
        menu.autoenablesItems = false

        switch state {
        case .needsScreenRecording:
            menu.addItem(header(String(localized: "Screen Recording required")))
            menu.addItem(.separator())
            menu.addItem(command(String(localized: "Open System Settings…"),
                                 .openSettings(.screenRecording),
                                 target: target, action: action))
            menu.addItem(.separator())
            menu.addItem(command(String(localized: "Show openXTranscriber"),
                                 .showApp, target: target, action: action))
            menu.addItem(quitItem())

        case .idle:
            if let content {
                var addedQuick = false
                if let main = content.mainDisplay {
                    menu.addItem(command(
                        String(localized: "Record Main Display (\(main.width)×\(main.height))"),
                        .start(.display(main)),
                        target: target, action: action
                    ))
                    addedQuick = true
                }
                if let front = content.frontmostWindow {
                    let appName = front.owningApplication?.applicationName ?? String(localized: "Window")
                    menu.addItem(command(
                        String(localized: "Record Frontmost Window — \(appName)"),
                        .start(.window(front)),
                        target: target, action: action
                    ))
                    addedQuick = true
                }
                if addedQuick {
                    menu.addItem(.separator())
                }

                if !content.displays.isEmpty || !content.windowsByApp.isEmpty {
                    menu.addItem(command(String(localized: "Choose Source…"),
                                         .showSourcePicker, target: target, action: action))
                } else {
                    menu.addItem(header(String(localized: "No displays or windows available")))
                }

                menu.addItem(command(String(localized: "Refresh Sources"),
                                     .refreshSources, target: target, action: action))
            } else {
                menu.addItem(header(String(localized: "Loading…")))
            }
            menu.addItem(.separator())
            menu.addItem(command(String(localized: "Open Recordings Folder"),
                                 .openRecordingsFolder, target: target, action: action))
            menu.addItem(settingsItem(target: target, action: action))
            menu.addItem(.separator())
            menu.addItem(command(String(localized: "Show openXTranscriber"),
                                 .showApp, target: target, action: action))
            menu.addItem(quitItem())

        case .recording(let startedAt, _):
            let elapsed = elapsedString(since: startedAt)
            menu.addItem(header(String(localized: "● Recording \(elapsed)")))
            menu.addItem(.separator())
            menu.addItem(command(String(localized: "Stop Recording"),
                                 .stop, target: target, action: action))
            menu.addItem(command(String(localized: "Cancel (discard)"),
                                 .cancel, target: target, action: action))
            menu.addItem(.separator())
            menu.addItem(command(String(localized: "Open Recordings Folder"),
                                 .openRecordingsFolder, target: target, action: action))
            menu.addItem(.separator())
            menu.addItem(command(String(localized: "Show openXTranscriber"),
                                 .showApp, target: target, action: action))
            menu.addItem(quitItem())
        }
    }

    private static func command(_ title: String,
                                _ cmd: RecordingMenuCommand,
                                target: AnyObject,
                                action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        item.representedObject = cmd
        return item
    }

    private static func header(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private static func quitItem() -> NSMenuItem {
        NSMenuItem(title: String(localized: "Quit openXTranscriber"),
                   action: #selector(NSApplication.terminate(_:)),
                   keyEquivalent: "q")
    }

    private static func settingsItem(target: AnyObject, action: Selector) -> NSMenuItem {
        let root = NSMenuItem(title: String(localized: "Recording Settings"), action: nil, keyEquivalent: "")
        let sub = NSMenu(title: String(localized: "Recording Settings"))

        let current = NSMenuItem(title: String(localized: "Output: \(RecordingSettings.outputFolderDisplayName)"),
                                 action: nil, keyEquivalent: "")
        current.isEnabled = false
        sub.addItem(current)

        sub.addItem(.separator())
        sub.addItem(command(String(localized: "Change Output Folder…"),
                            .changeOutputFolder, target: target, action: action))
        if RecordingSettings.isOutputFolderCustom {
            sub.addItem(command(String(localized: "Reset to ~/Movies/openXTranscriber"),
                                .resetOutputFolder, target: target, action: action))
        }

        sub.addItem(.separator())
        let nr = command(String(localized: "Noise Gate (silence background when quiet)"),
                         .toggleNoiseGate, target: target, action: action)
        nr.state = RecordingSettings.noiseGateEnabled ? .on : .off
        sub.addItem(nr)

        root.submenu = sub
        return root
    }

    private static func elapsedString(since startedAt: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(startedAt)))
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%02d:%02d", m, s)
    }
}
