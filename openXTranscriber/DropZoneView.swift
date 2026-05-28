import SwiftUI
import UniformTypeIdentifiers

struct DropZoneView: View {
    @Binding var isTargeted: Bool
    let onPickFile: () -> Void
    let onFilesDropped: ([URL]) -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 46))
                .foregroundStyle(.secondary)
            Text("Drop audio or video file here")
                .font(.title3)
            Text("Supported: webm, mov, mp4, m4a, wav, mp3, ogg, flac, mkv, aac")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Choose File", action: onPickFile)
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .background {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                    style: StrokeStyle(lineWidth: 2, dash: [8, 8])
                )
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
                )
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
            loadURLs(from: providers)
            return true
        }
    }

    private func loadURLs(from providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let fileURL = NSURL(absoluteURLWithDataRepresentation: data, relativeTo: nil) as URL? else {
                    return
                }
                DispatchQueue.main.async {
                    onFilesDropped([fileURL])
                }
            }
        }
    }
}
