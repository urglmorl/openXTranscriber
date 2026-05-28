import AppKit
import Combine
import ScreenCaptureKit
import SwiftUI

@MainActor
final class SourcePickerModel: ObservableObject {
    @Published var content: AvailableContent
    @Published var refreshing: Bool = false
    /// Bumped on each successful refresh so cells can re-fire their thumbnail
    /// task even when the underlying windowID/displayID is unchanged.
    @Published var refreshGeneration: Int = 0

    init(content: AvailableContent) {
        self.content = content
    }

    /// Displays first, then windows from every app group flattened into one list.
    var items: [SourceItem] {
        var result: [SourceItem] = content.displays.map { .display($0) }
        for group in content.windowsByApp {
            for window in group.windows {
                result.append(.window(window, appName: group.app.applicationName))
            }
        }
        return result
    }

    func refresh() async {
        refreshing = true
        defer { refreshing = false }
        if let fresh = try? await SharedContent.fetch() {
            content = fresh
            refreshGeneration &+= 1
        }
    }
}

enum SourceItem: Identifiable {
    case display(SCDisplay)
    case window(SCWindow, appName: String)

    var id: String {
        switch self {
        case .display(let d): return "d-\(d.displayID)"
        case .window(let w, _): return "w-\(w.windowID)"
        }
    }
}

struct SourcePickerView: View {
    @ObservedObject var model: SourcePickerModel
    let onSelect: (CaptureTarget) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                if model.items.isEmpty {
                    Text(String(localized: "No displays or windows available"))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 32)
                        .frame(maxWidth: .infinity)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 180), spacing: 12)],
                        alignment: .leading,
                        spacing: 12
                    ) {
                        ForEach(model.items) { item in
                            cell(for: item)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Divider()

            HStack(spacing: 8) {
                Button {
                    Task { await model.refresh() }
                } label: {
                    HStack(spacing: 6) {
                        if model.refreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text(String(localized: "Refresh"))
                    }
                }
                .disabled(model.refreshing)

                Spacer()

                Button(String(localized: "Cancel"), role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(minWidth: 620, minHeight: 420)
    }

    @ViewBuilder
    private func cell(for item: SourceItem) -> some View {
        switch item {
        case .display(let display):
            DisplayCell(
                display: display,
                refreshGen: model.refreshGeneration,
                onSelect: { onSelect(.display(display)) }
            )
        case .window(let window, let appName):
            WindowCell(
                window: window,
                appName: appName,
                refreshGen: model.refreshGeneration,
                onSelect: { onSelect(.window(window)) }
            )
        }
    }
}

private struct WindowCell: View {
    let window: SCWindow
    let appName: String
    let refreshGen: Int
    let onSelect: () -> Void

    @State private var image: NSImage?
    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    ThumbnailFrame(image: image, hovering: hovering, height: 110)
                    if let icon = appIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 22, height: 22)
                            .shadow(color: .black.opacity(0.4), radius: 1.5, x: 0, y: 1)
                            .padding(4)
                    }
                }
                Text(verbatim: label)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(Text(verbatim: label))
        .task(id: refreshGen) {
            image = nil
            if let cg = await SourceThumbnail.capture(window: window) {
                image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
        }
    }

    private var appIcon: NSImage? {
        guard let pid = window.owningApplication?.processID else { return nil }
        return NSRunningApplication(processIdentifier: pid_t(pid))?.icon
    }

    private var label: String {
        let title = window.title ?? String(localized: "Untitled")
        return "\(appName) — \(title)"
    }
}

private struct DisplayCell: View {
    let display: SCDisplay
    let refreshGen: Int
    let onSelect: () -> Void

    @State private var image: NSImage?
    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 4) {
                ThumbnailFrame(image: image, hovering: hovering, height: 110)
                Text(String(localized: "Display \(display.displayID) — \(display.width)×\(display.height)"))
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .task(id: refreshGen) {
            image = nil
            if let cg = await SourceThumbnail.capture(display: display) {
                image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
        }
    }
}

private struct ThumbnailFrame: View {
    let image: NSImage?
    let hovering: Bool
    let height: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.12))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFit()
                    .padding(4)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    hovering ? Color.accentColor : Color.secondary.opacity(0.25),
                    lineWidth: hovering ? 2 : 1
                )
        )
    }
}
