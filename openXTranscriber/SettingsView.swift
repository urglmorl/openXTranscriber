import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @AppStorage("transcriptionLanguage") private var language = "ru"
    @AppStorage("whisperModel") private var whisperModel = "whisper-large-v3-turbo"
    @AppStorage("saveMode") private var saveModeRaw = SaveMode.nearSource.rawValue
    @AppStorage("fixedSaveFolderPath") private var fixedSaveFolderPath = ""
    @AppStorage("customPythonPath") private var customPythonPath = ""
    @AppStorage("onboardingCompleted") private var onboardingCompleted = false
    @AppStorage("appLanguage") private var appLanguage = "system"
    @AppStorage("twoPassTranscriptionEnabled") private var twoPassTranscriptionEnabled = true

    @State private var hfToken = ""
    @State private var saveFeedback = ""
    @State private var runtimeInfo = String(localized: "Runtime status unknown.")
    @State private var isCheckingRuntime = false
    @State private var showRestartNotice = false
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    private let languages = ["ru", "en", "de", "fr", "es", "it"]
    private let appLanguageOptions: [(label: String, value: String)] = [
        ("System", "system"),
        ("English", "en"),
        ("Русский", "ru")
    ]
    private let modelOptions: [(label: String, value: String)] = [
        ("tiny", "tiny"),
        ("base", "base"),
        ("small", "small"),
        ("medium", "medium"),
        ("large-v3-turbo", "whisper-large-v3-turbo")
    ]

    var body: some View {
        Form {
            Section {
                LabeledContent("Token") {
                    SecureField("hf_...", text: $hfToken)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 220)
                }
                HStack {
                    Spacer()
                    if !saveFeedback.isEmpty {
                        Text(saveFeedback)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Button("Save Token") {
                        saveToken()
                    }
                }
            } header: {
                Text("HuggingFace Token")
            }

            Section {
                Picker("Interface language", selection: $appLanguage) {
                    ForEach(appLanguageOptions, id: \.value) { item in
                        Text(item.label).tag(item.value)
                    }
                }
                .onChange(of: appLanguage) { newValue in
                    applyAppLanguage(newValue)
                    showRestartNotice = true
                }
                if showRestartNotice {
                    Text("Restart the app to apply the interface language change.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Interface")
            }

            Section {
                Picker("Transcription language", selection: $language) {
                    ForEach(languages, id: \.self) { item in
                        Text(item).tag(item)
                    }
                }
                Picker("Whisper model", selection: $whisperModel) {
                    ForEach(modelOptions, id: \.value) { item in
                        Text(item.label).tag(item.value)
                    }
                }
                Toggle("Two-pass transcription", isOn: $twoPassTranscriptionEnabled)
                Text("First pass runs cold, then the app extracts mentioned names and recurring terms and re-runs Whisper with that context. Roughly doubles processing time.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Transcription")
            }

            VoiceLibrarySection()

            Section {
                Picker("Save mode", selection: $saveModeRaw) {
                    ForEach(SaveMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                if SaveMode(rawValue: saveModeRaw) == .fixedFolder {
                    LabeledContent("Folder") {
                        HStack {
                            Text(fixedSaveFolderPath.isEmpty ? String(localized: "No folder selected") : fixedSaveFolderPath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Choose Folder") {
                                if let folder = FolderPicker.chooseFolder() {
                                    fixedSaveFolderPath = folder.path
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("Output")
            }

            Section {
                LabeledContent("Status") {
                    Text(runtimeInfo)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                LabeledContent("Python path") {
                    HStack {
                        TextField("/opt/homebrew/bin/python3", text: $customPythonPath)
                            .textFieldStyle(.roundedBorder)
                        Button("Pick") {
                            if let path = pickPythonPath() {
                                customPythonPath = path
                            }
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("Check Runtime") {
                        checkRuntime()
                    }
                    .disabled(isCheckingRuntime)
                    Button("Install Managed Runtime") {
                        installManagedRuntime()
                    }
                    .disabled(isCheckingRuntime)
                }
                Text("Managed runtime will be prepared in Application Support and used for all Python calls.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Runtime")
            }

            Section {
                Toggle("Open at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { newValue in
                        applyOpenAtLogin(newValue)
                    }
                Text("Manage manually in System Settings → General → Login Items.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Startup")
            }

            Section {
                Text(onboardingCompleted ? "Onboarding is completed." : "Onboarding will be shown at startup.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Show onboarding again") {
                        onboardingCompleted = false
                    }
                }
            } header: {
                Text("Onboarding")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 540, idealWidth: 580, minHeight: 600, idealHeight: 720)
        .onAppear {
            normalizeWhisperModel()
            hfToken = KeychainHelper.shared.loadToken() ?? ""
            checkRuntime()
            // Re-read in case the user toggled it via System Settings since the
            // last time this view appeared.
            openAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func applyOpenAtLogin(_ enabled: Bool) {
        Task { @MainActor in
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try await SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("openXTranscriber: open-at-login update failed — \(error.localizedDescription)")
            }
        }
    }

    private func applyAppLanguage(_ value: String) {
        let defaults = UserDefaults.standard
        if value == "system" {
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set([value], forKey: "AppleLanguages")
        }
    }

    private func saveToken() {
        do {
            try KeychainHelper.shared.saveToken(hfToken.trimmingCharacters(in: .whitespacesAndNewlines))
            saveFeedback = String(localized: "Saved")
        } catch {
            saveFeedback = String(localized: "Save failed: \(error.localizedDescription)")
        }
    }

    private func checkRuntime() {
        isCheckingRuntime = true
        Task {
            let command = await RuntimeManager.shared.resolveAvailableRuntime(customPythonPath: normalizedCustomPythonPath())
            await MainActor.run {
                if let command {
                    runtimeInfo = String(localized: "Available: \(command.displayName)")
                } else {
                    runtimeInfo = String(localized: "No available runtime. Install managed runtime or provide python path.")
                }
                isCheckingRuntime = false
            }
        }
    }

    private func installManagedRuntime() {
        isCheckingRuntime = true
        Task {
            do {
                let command = try await RuntimeManager.shared.prepareRuntimeIfNeeded(
                    customPythonPath: normalizedCustomPythonPath(),
                    forceReinstall: false,
                    log: { _ in },
                    shouldCancel: { false }
                )
                await MainActor.run {
                    runtimeInfo = String(localized: "Managed runtime ready: \(command.displayName)")
                    isCheckingRuntime = false
                }
            } catch {
                await MainActor.run {
                    runtimeInfo = String(localized: "Runtime install failed: \(error.localizedDescription)")
                    isCheckingRuntime = false
                }
            }
        }
    }

    private func pickPythonPath() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Select")
        panel.title = String(localized: "Select Python executable")
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    private func normalizedCustomPythonPath() -> String? {
        let value = customPythonPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func normalizeWhisperModel() {
        switch whisperModel {
        case "large-v3-turbo":
            whisperModel = "whisper-large-v3-turbo"
        default:
            if !modelOptions.contains(where: { $0.value == whisperModel }) {
                whisperModel = "whisper-large-v3-turbo"
            }
        }
    }
}

#Preview {
    SettingsView()
}
