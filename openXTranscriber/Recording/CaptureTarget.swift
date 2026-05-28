import AppKit
import ScreenCaptureKit

enum CaptureTarget {
    case display(SCDisplay)
    case window(SCWindow)

    var displayName: String {
        switch self {
        case .display(let d):
            return "Display \(d.displayID) — \(d.width)×\(d.height)"
        case .window(let w):
            let app = w.owningApplication?.applicationName ?? "Unknown"
            let title = w.title ?? "Untitled"
            return "\(app) — \(title)"
        }
    }

    var pixelSize: CGSize {
        // H.264 requires both dimensions to be even (4:2:0 chroma subsampling).
        // HiDPI scaled modes and fractional window frames can produce odd values,
        // causing AVAssetWriter to fail with AVFoundationErrorDomain -11800 / -16122.
        switch self {
        case .display(let d):
            return CGSize(width: evenize(d.width), height: evenize(d.height))
        case .window(let w):
            let scale = NSScreen.main?.backingScaleFactor ?? 2.0
            return CGSize(
                width:  evenize(Int(w.frame.width  * scale)),
                height: evenize(Int(w.frame.height * scale))
            )
        }
    }

    private func evenize(_ value: Int) -> Int {
        max(2, (value / 2) * 2)
    }

    var contentFilter: SCContentFilter {
        switch self {
        case .display(let d):
            return SCContentFilter(display: d, excludingWindows: [])
        case .window(let w):
            return SCContentFilter(desktopIndependentWindow: w)
        }
    }
}
