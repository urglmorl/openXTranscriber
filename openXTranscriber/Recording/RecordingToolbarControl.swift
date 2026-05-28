import ScreenCaptureKit
import SwiftUI

/// SwiftUI recording control intended for use in the window toolbar (so it's
/// visible across Home, Voices, and History).
///
/// - When recording: a red Stop button with elapsed time.
/// - When idle: a Menu that opens an explicit target picker. There is no
///   "primary action" — clicking the button always shows the picker so the
///   user knows exactly what they're recording before it starts.
/// - When permission is missing: a single button that opens System Settings.
struct RecordingToolbarControl: View {
    @ObservedObject var controller: RecordingController

    var body: some View {
        switch controller.state {
        case .recording:
            stopButton
        case .needsScreenRecording:
            permissionButton
        case .idle:
            recordMenu
        }
    }

    private var stopButton: some View {
        Button {
            controller.stopRecording()
        } label: {
            Label {
                Text("Stop · \(controller.elapsedString)")
                    .monospacedDigit()
            } icon: {
                Image(systemName: "stop.circle.fill")
            }
        }
        .help(Text("Stop recording"))
        .tint(.red)
    }

    private var permissionButton: some View {
        Button {
            controller.openSystemSettings(for: .screenRecording)
        } label: {
            Label("Allow Screen Recording", systemImage: "exclamationmark.triangle")
        }
        .help(Text("Screen Recording permission required"))
    }

    private var recordMenu: some View {
        Menu {
            menuContents
        } label: {
            Label("Record", systemImage: "record.circle")
        }
        .help(Text("Choose what to record"))
        .onAppear {
            // Refresh available displays/windows whenever the menu re-renders
            // (e.g. user opens it after switching apps), so the "frontmost
            // window" entry stays accurate.
            Task { await controller.refreshAvailableContent() }
        }
    }

    @ViewBuilder
    private var menuContents: some View {
        if let content = controller.availableContent {
            if let main = content.mainDisplay {
                Button {
                    controller.startRecording(target: .display(main))
                } label: {
                    Text("This screen — Display \(main.displayID) (\(main.width)×\(main.height))")
                }
            }
            if content.displays.count > 1 {
                Menu("Other displays") {
                    ForEach(content.displays.filter { $0.displayID != content.mainDisplay?.displayID },
                            id: \.displayID) { display in
                        Button(CaptureTarget.display(display).displayName) {
                            controller.startRecording(target: .display(display))
                        }
                    }
                }
            }

            if !content.windowsByApp.isEmpty {
                Divider()
                if let front = content.frontmostWindow {
                    let appName = front.owningApplication?.applicationName ?? String(localized: "Window")
                    Button {
                        controller.startRecording(target: .window(front))
                    } label: {
                        Text("Frontmost window — \(appName)")
                    }
                }
            }

            if !content.displays.isEmpty || !content.windowsByApp.isEmpty {
                Button("Choose Source…") {
                    SourcePickerPanel.present(
                        initialContent: content,
                        onSelect: { target in
                            controller.startRecording(target: target)
                        }
                    )
                }
            }

            Divider()
            Button("Refresh sources") {
                Task { await controller.refreshAvailableContent() }
            }
            Button("Open recordings folder") {
                controller.openOutputFolder()
            }
        } else {
            Text("Loading…")
            Button("Refresh sources") {
                Task { await controller.refreshAvailableContent() }
            }
        }
    }
}
