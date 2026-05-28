import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

struct AvailableContent {
    struct AppGroup {
        let app: SCRunningApplication
        let windows: [SCWindow]
    }

    let displays: [SCDisplay]
    let windowsByApp: [AppGroup]
}

extension AvailableContent {
    /// The display currently hosting the menu bar (CGMainDisplayID). Falls
    /// back to the first listed display if no match is found.
    var mainDisplay: SCDisplay? {
        let mainID = CGMainDisplayID()
        return displays.first(where: { $0.displayID == mainID }) ?? displays.first
    }

    /// Best-effort frontmost window: the largest layer-0 window belonging to
    /// the app that's currently frontmost (per NSWorkspace). `nil` if the
    /// frontmost app has no recordable window.
    var frontmostWindow: SCWindow? {
        guard let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              let group = windowsByApp.first(where: { $0.app.bundleIdentifier == frontBundle })
        else { return nil }
        return group.windows
            .sorted { ($0.frame.width * $0.frame.height) > ($1.frame.width * $1.frame.height) }
            .first
    }
}

enum SharedContent {
    static func fetch() async throws -> AvailableContent {
        let raw = try await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: true
        )
        let ownBundle = Bundle.main.bundleIdentifier

        let visible = raw.windows.filter { w in
            // windowLayer == 0 is the "normal window" level. Everything above
            // (menu bar, Dock, Control Center extras, status items, pop-ups,
            // Notification Center) has a higher layer and is not a reasonable
            // recording target. Floating palettes at layer 3 are dropped too;
            // the tradeoff is worth the cleaner list.
            guard w.windowLayer == 0 else { return false }
            guard w.frame.size.width >= 40, w.frame.size.height >= 40 else { return false }
            guard let title = w.title, !title.isEmpty else { return false }
            if let bid = w.owningApplication?.bundleIdentifier, bid == ownBundle {
                return false
            }
            return true
        }

        var byApp: [String: AvailableContent.AppGroup] = [:]
        for w in visible {
            guard let app = w.owningApplication, !app.applicationName.isEmpty else { continue }
            let existing = byApp[app.bundleIdentifier]
            let windows  = (existing?.windows ?? []) + [w]
            byApp[app.bundleIdentifier] = .init(app: app, windows: windows)
        }

        let groups = byApp.values
            .map { AvailableContent.AppGroup(app: $0.app,
                                             windows: $0.windows.sorted { $0.windowID < $1.windowID }) }
            .sorted { $0.app.applicationName.localizedCaseInsensitiveCompare($1.app.applicationName) == .orderedAscending }

        let displays = raw.displays.sorted { $0.displayID < $1.displayID }

        return AvailableContent(displays: displays, windowsByApp: groups)
    }
}
