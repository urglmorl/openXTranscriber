import SwiftUI

struct VoiceLibrarySection: View {
    @AppStorage("voiceFingerprintingEnabled") private var enabled = true
    @AppStorage("voiceAutoLabelThreshold") private var autoThreshold: Double = 0.80
    @AppStorage("voiceSuggestThreshold") private var suggestThreshold: Double = 0.65

    var body: some View {
        Section("Voice Library") {
            Toggle("Enable voice fingerprinting", isOn: $enabled)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Auto-label threshold")
                    Spacer()
                    Text(String(format: "%.2f", autoThreshold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $autoThreshold, in: 0.5...0.95, step: 0.01)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Suggest-only threshold")
                    Spacer()
                    Text(String(format: "%.2f", suggestThreshold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $suggestThreshold, in: 0.3...0.85, step: 0.01)
            }

            Text("Above auto-label threshold the speaker is renamed silently. Between thresholds it is shown for confirmation. Below it stays as SPEAKER_XX.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            if autoThreshold < suggestThreshold { autoThreshold = max(suggestThreshold, 0.80) }
        }
    }
}
