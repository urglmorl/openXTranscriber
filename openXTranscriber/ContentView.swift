//
//  ContentView.swift
//  openXTranscriber
//
//  Created by urglmorl on 17.04.2026.
//

import AppKit
import SwiftUI

enum SidebarItem: Hashable {
    case home
    case voices
    case history
}

struct ContentView: View {
    @ObservedObject var viewModel: TranscriberViewModel
    @ObservedObject var recordingController: RecordingController
    @State private var selection: SidebarItem = .home

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    Label("Home", systemImage: "house")
                        .tag(SidebarItem.home)
                }
                Section("Library") {
                    Label("Voices", systemImage: "person.2.wave.2")
                        .tag(SidebarItem.voices)
                    Label("History", systemImage: "clock.arrow.circlepath")
                        .tag(SidebarItem.history)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("openXTranscriber")
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            Group {
                switch selection {
                case .home:
                    HomeView(viewModel: viewModel)
                case .voices:
                    VoicesView()
                case .history:
                    HistoryView()
                }
            }
            .toolbar {
                // Anchored to the detail's leading edge — stays visible whether
                // the sidebar is expanded or collapsed (the sidebar's own
                // toolbar segment disappears when the sidebar is hidden, so we
                // can't pin it there).
                ToolbarItem(placement: .navigation) {
                    RecordingToolbarControl(controller: recordingController)
                }
            }
        }
        .frame(minWidth: 880, minHeight: 560)
        .confirmationDialog(
            Text("Recording finished"),
            isPresented: Binding(
                get: { recordingController.pendingTranscriptionURL != nil },
                set: { if !$0 { recordingController.pendingTranscriptionURL = nil } }
            ),
            titleVisibility: .visible,
            presenting: recordingController.pendingTranscriptionURL
        ) { url in
            Button("Transcribe with diarization") {
                viewModel.startProcessing(fileURL: url)
                recordingController.pendingTranscriptionURL = nil
            }
            .disabled(viewModel.isProcessing)
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
                recordingController.pendingTranscriptionURL = nil
            }
            Button("Dismiss", role: .cancel) {
                recordingController.pendingTranscriptionURL = nil
            }
        } message: { url in
            Text("\"\(url.lastPathComponent)\" saved. Run transcription with speaker diarization?")
        }
        .alert(
            Text("Recording error"),
            isPresented: Binding(
                get: { recordingController.errorMessage != nil },
                set: { if !$0 { recordingController.errorMessage = nil } }
            ),
            presenting: recordingController.errorMessage
        ) { _ in
            Button("OK", role: .cancel) {
                recordingController.dismissError()
            }
        } message: { message in
            Text(message)
        }
        .confirmationDialog(
            Text("Permission required"),
            isPresented: Binding(
                get: { recordingController.pendingPermissionPrompt != nil },
                set: { if !$0 { recordingController.pendingPermissionPrompt = nil } }
            ),
            titleVisibility: .visible,
            presenting: recordingController.pendingPermissionPrompt
        ) { kind in
            Button("Open System Settings…") {
                recordingController.openSystemSettings(for: kind)
                recordingController.pendingPermissionPrompt = nil
            }
            Button("Cancel", role: .cancel) {
                recordingController.pendingPermissionPrompt = nil
            }
        } message: { kind in
            switch kind {
            case .microphone:
                Text("openXTranscriber needs microphone access to record a voice-over track. Enable it under Privacy & Security › Microphone, then click Record again.")
            case .screenRecording:
                Text("openXTranscriber needs Screen Recording access. Enable it under Privacy & Security › Screen Recording, then quit and reopen the app.")
            }
        }
    }
}

#Preview {
    ContentView(
        viewModel: TranscriberViewModel(),
        recordingController: RecordingController()
    )
}
