import AVFoundation
import SwiftUI

struct SpeakerNamingSheet: View {
    @ObservedObject var viewModel: TranscriberViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var voices: [VoiceProfile] = []
    @State private var newNames: [UUID: String] = [:]
    @State private var pickedVoiceID: [UUID: UUID] = [:]
    @State private var isLoadingVoices = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if viewModel.pendingSpeakerSuggestions.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(viewModel.pendingSpeakerSuggestions) { match in
                            speakerRow(for: match)
                        }
                    }
                }
                .frame(maxHeight: 460)
            }

            Divider()

            HStack {
                Button("Skip remaining") {
                    viewModel.dismissAllSuggestions()
                    dismiss()
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 580)
        .task { await reloadVoices() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Name speakers")
                .font(.title3)
                .fontWeight(.semibold)
            Text("Confirm matches or add new voices to your library. The transcript will be updated automatically.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .font(.largeTitle)
                .foregroundStyle(.green)
            Text("No speakers left to name.")
                .font(.headline)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }

    private func speakerRow(for match: SpeakerMatch) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(match.speakerID)
                        .font(.headline)
                    Text(detailLine(for: match))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let url = viewModel.processedAudioURL {
                    SamplePlayerButton(
                        audioURL: url,
                        start: match.sampleStart,
                        end: match.sampleEnd
                    )
                }
            }

            if let suggestionName = match.bestMatchName, match.decision == .suggestion {
                Text("Suggested match: \(suggestionName) (cosine \(String(format: "%.2f", match.bestSimilarity)))")
                    .font(.footnote)
                    .foregroundStyle(.blue)
            }

            HStack(spacing: 8) {
                Text("Existing voice:")
                    .font(.callout)
                Picker("", selection: bindingForExistingVoice(match: match)) {
                    Text("— select —").tag(UUID?.none)
                    ForEach(voices) { voice in
                        Text(voice.name).tag(Optional(voice.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 220)

                Button("Use") {
                    if let id = pickedVoiceID[match.id], let voice = voices.first(where: { $0.id == id }) {
                        viewModel.confirmSpeaker(match, asExisting: voice)
                    }
                }
                .disabled(pickedVoiceID[match.id] == nil)
            }

            HStack(spacing: 8) {
                TextField("New name (e.g. Alex)", text: bindingForNewName(match: match))
                    .textFieldStyle(.roundedBorder)
                Button("Add to library") {
                    let name = newNames[match.id] ?? ""
                    viewModel.confirmSpeaker(match, asNew: name)
                    Task { await reloadVoices() }
                }
                .disabled((newNames[match.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            HStack {
                Spacer()
                Button("Skip", role: .destructive) {
                    viewModel.skipSpeaker(match)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func detailLine(for match: SpeakerMatch) -> String {
        let duration = String(format: "%.1f s", match.totalSeconds)
        switch match.decision {
        case .suggestion:
            return String(localized: "Probable match — \(duration) of speech")
        case .unknown:
            return String(localized: "Unknown speaker — \(duration) of speech")
        case .autoLabeled:
            return String(localized: "Auto-labeled — \(duration) of speech")
        }
    }

    private func bindingForNewName(match: SpeakerMatch) -> Binding<String> {
        Binding(
            get: { newNames[match.id] ?? "" },
            set: { newNames[match.id] = $0 }
        )
    }

    private func bindingForExistingVoice(match: SpeakerMatch) -> Binding<UUID?> {
        Binding(
            get: { pickedVoiceID[match.id] ?? match.bestMatchVoiceID },
            set: { pickedVoiceID[match.id] = $0 }
        )
    }

    private func reloadVoices() async {
        isLoadingVoices = true
        let loaded = await viewModel.currentVoices()
        await MainActor.run {
            voices = loaded
            isLoadingVoices = false
        }
    }
}

/// Кнопка прослушивания фрагмента WAV в диапазоне [start, end].
struct SamplePlayerButton: View {
    let audioURL: URL
    let start: TimeInterval
    let end: TimeInterval

    @State private var isPlaying = false
    @State private var player: AVPlayer?
    @State private var stopTimer: Timer?

    var body: some View {
        Button {
            toggle()
        } label: {
            Label(isPlaying ? "Stop" : "Play sample", systemImage: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                .font(.callout)
        }
        .buttonStyle(.bordered)
        .onDisappear {
            stop()
        }
    }

    private func toggle() {
        if isPlaying {
            stop()
        } else {
            play()
        }
    }

    private func play() {
        let item = AVPlayerItem(url: audioURL)
        let player = AVPlayer(playerItem: item)
        let startTime = CMTime(seconds: start, preferredTimescale: 600)
        let endTime = CMTime(seconds: end, preferredTimescale: 600)
        item.forwardPlaybackEndTime = endTime
        player.seek(to: startTime, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            player.play()
        }
        self.player = player
        self.isPlaying = true

        let duration = max(0.2, end - start) + 0.2
        stopTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { _ in
            Task { @MainActor in
                self.stop()
            }
        }
    }

    private func stop() {
        player?.pause()
        player = nil
        stopTimer?.invalidate()
        stopTimer = nil
        isPlaying = false
    }
}
