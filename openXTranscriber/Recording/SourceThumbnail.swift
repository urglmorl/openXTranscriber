import AppKit
import CoreGraphics
import ScreenCaptureKit

/// One-shot screenshot helpers for the source picker. Returns a CGImage suitable
/// for display inside a thumbnail cell. SCScreenshotManager (macOS 14+) gives
/// nicer output and avoids deprecation warnings; CG fallbacks keep macOS 13 working.
enum SourceThumbnail {
    static func capture(window: SCWindow) async -> CGImage? {
        if #available(macOS 14.0, *) {
            return await captureModern(window: window)
        }
        return CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            window.windowID,
            [.boundsIgnoreFraming, .nominalResolution]
        )
    }

    static func capture(display: SCDisplay) async -> CGImage? {
        if #available(macOS 14.0, *) {
            return await captureModern(display: display)
        }
        return CGDisplayCreateImage(display.displayID)
    }

    @available(macOS 14.0, *)
    private static func captureModern(window: SCWindow) async -> CGImage? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let cfg = SCStreamConfiguration()
        let aspect = max(window.frame.width / max(window.frame.height, 1), 0.1)
        let maxDim = 480
        if aspect >= 1 {
            cfg.width = maxDim
            cfg.height = max(2, Int(Double(maxDim) / aspect))
        } else {
            cfg.height = maxDim
            cfg.width = max(2, Int(Double(maxDim) * aspect))
        }
        return try? await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: cfg
        )
    }

    @available(macOS 14.0, *)
    private static func captureModern(display: SCDisplay) async -> CGImage? {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        let aspect = Double(display.width) / max(Double(display.height), 1)
        let maxDim = 600
        cfg.width = maxDim
        cfg.height = max(2, Int(Double(maxDim) / aspect))
        return try? await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: cfg
        )
    }
}
