//
//  OpenXTranscriberApp.swift
//  openXTranscriber
//
//  Created by urglmorl on 17.04.2026.
//

import SwiftUI

@main
struct OpenXTranscriberApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var viewModel = TranscriberViewModel()
    @AppStorage("onboardingCompleted") private var onboardingCompleted = false
    @State private var pendingOpenFileURL: URL?

    init() {
        migrateLegacySettings()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if onboardingCompleted {
                    ContentView(
                        viewModel: viewModel,
                        recordingController: appDelegate.recordingController
                    )
                    .task {
                        appDelegate.installRecordingStatusBarItemIfNeeded()
                        handlePendingFileIfNeeded()
                    }
                } else {
                    OnboardingView {
                        onboardingCompleted = true
                        appDelegate.installRecordingStatusBarItemIfNeeded()
                        handlePendingFileIfNeeded()
                    }
                }
            }
            .onOpenURL { url in
                handleIncomingFile(url)
            }
            .onReceive(NotificationCenter.default.publisher(for: .transcriberOpenFile)) { note in
                guard let url = note.object as? URL else { return }
                handleIncomingFile(url)
            }
        }
        Settings {
            SettingsView()
        }
    }

    private func migrateLegacySettings() {
        let defaults = UserDefaults.standard
        let key = "whisperModel"
        if defaults.string(forKey: key) == "large-v3-turbo" {
            defaults.set("whisper-large-v3-turbo", forKey: key)
        }
    }

    private func handleIncomingFile(_ url: URL) {
        if onboardingCompleted {
            viewModel.startProcessing(fileURL: url)
        } else {
            pendingOpenFileURL = url
        }
    }

    private func handlePendingFileIfNeeded() {
        guard onboardingCompleted, let url = pendingOpenFileURL else { return }
        pendingOpenFileURL = nil
        viewModel.startProcessing(fileURL: url)
    }
}
