import SwiftUI

struct VoicesView: View {
    @State private var voices: [VoiceProfile] = []
    @State private var isLoading = false
    @State private var renamingID: UUID?
    @State private var renameBuffer = ""
    @State private var statusMessage = ""

    private let library = VoiceLibrary.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if voices.isEmpty {
                    if isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 300)
                    } else {
                        emptyState
                    }
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(voices) { voice in
                            voiceRow(voice)
                                .padding(12)
                                .background(.regularMaterial)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }

                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }
            .padding(20)
        }
        .navigationTitle("Voices")
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("Reload") {
                        Task { await reload() }
                    }
                    Divider()
                    Button("Erase library", role: .destructive) {
                        Task {
                            try? await library.eraseAll()
                            await reload()
                        }
                    }
                    .disabled(voices.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task { await reload() }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.2.wave.2")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No voices yet")
                .font(.title3)
                .fontWeight(.semibold)
            Text("Names will be added here after you confirm speakers from your first transcripts.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }

    private func voiceRow(_ voice: VoiceProfile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.fill")
                .font(.title)
                .foregroundStyle(.tint)

            if renamingID == voice.id {
                TextField("Name", text: $renameBuffer, onCommit: {
                    Task { await commitRename(voice) }
                })
                .textFieldStyle(.roundedBorder)
                Button("Save") { Task { await commitRename(voice) } }
                Button("Cancel") { renamingID = nil }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(voice.name)
                        .font(.headline)
                    Text("\(voice.embeddings.count) sample(s) • updated \(formatted(voice.updatedAt))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Rename") {
                    renamingID = voice.id
                    renameBuffer = voice.name
                }
                .buttonStyle(.borderless)
                Button(role: .destructive) {
                    Task { await delete(voice) }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func commitRename(_ voice: VoiceProfile) async {
        let trimmed = renameBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try await library.rename(profileID: voice.id, to: trimmed)
            renamingID = nil
            await reload()
        } catch {
            statusMessage = String(localized: "Rename failed: \(error.localizedDescription)")
        }
    }

    private func delete(_ voice: VoiceProfile) async {
        do {
            try await library.delete(profileID: voice.id)
            await reload()
        } catch {
            statusMessage = String(localized: "Delete failed: \(error.localizedDescription)")
        }
    }

    private func reload() async {
        isLoading = true
        let loaded = (try? await library.voices()) ?? []
        await MainActor.run {
            voices = loaded
            isLoading = false
        }
    }

    private func formatted(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
