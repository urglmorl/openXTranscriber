import SwiftUI

struct HistoryView: View {
    @State private var entries: [HistoryEntry] = []
    @State private var isLoading = false
    @State private var statusMessage = ""

    private let history = HistoryService.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if entries.isEmpty {
                    if isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 300)
                    } else {
                        emptyState
                    }
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(entries) { entry in
                            entryRow(entry)
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
        .navigationTitle("History")
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("Reload") { Task { await reload() } }
                    Divider()
                    Button("Clear history", role: .destructive) {
                        Task {
                            try? await history.clear()
                            await reload()
                        }
                    }
                    .disabled(entries.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task { await reload() }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No history yet")
                .font(.title3)
                .fontWeight(.semibold)
            Text("Your processed transcripts will appear here, sorted by date.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }

    private func entryRow(_ entry: HistoryEntry) -> some View {
        let outputExists = FileManager.default.fileExists(atPath: entry.outputURL.path)
        return HStack(spacing: 12) {
            Image(systemName: outputExists ? "doc.text.fill" : "doc.text")
                .font(.title2)
                .foregroundStyle(outputExists ? Color.accentColor : Color.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.sourceName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(formatted(entry.createdAt))
                    Text("•")
                    Text("\(entry.blockCount) blocks")
                    Text("•")
                    Text(entry.modeTitle)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if outputExists {
                Button {
                    NSWorkspace.shared.open(entry.outputURL)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.borderless)
                .help("Open file")

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([entry.outputURL])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")
            } else {
                Text("File missing")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button(role: .destructive) {
                Task {
                    try? await history.delete(id: entry.id)
                    await reload()
                }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }

    private func reload() async {
        isLoading = true
        let loaded = (try? await history.entries()) ?? []
        await MainActor.run {
            entries = loaded.sorted { $0.createdAt > $1.createdAt }
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
