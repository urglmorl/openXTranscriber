import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @ObservedObject var viewModel: TranscriberViewModel
    @State private var isDropTargeted = false
    @State private var isShowingNamingSheet = false
    @State private var isShowingLogs = false
    @State private var isShowingContext = false

    var body: some View {
        VStack(spacing: 0) {
            if let errorMessage = viewModel.errorMessage {
                errorBanner(errorMessage)
            }

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Home")
        .toolbar {
            ToolbarItem {
                Button {
                    viewModel.selectFileWithPanel()
                } label: {
                    Label("Open File", systemImage: "plus")
                }
                .disabled(viewModel.isProcessing || viewModel.isPreparingRuntime)
            }
        }
        .sheet(isPresented: $isShowingNamingSheet) {
            SpeakerNamingSheet(viewModel: viewModel)
        }
        .onAppear { viewModel.refreshRuntimeSummary() }
        .onChange(of: viewModel.pendingSpeakerSuggestions.count) { newCount in
            if newCount == 0 {
                isShowingNamingSheet = false
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let outputURL = viewModel.outputURL, !viewModel.isProcessing {
            resultStateView(outputURL: outputURL)
        } else if viewModel.isProcessing {
            processingStateView
        } else {
            idleStateView
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.callout)
            Spacer()
            Button {
                viewModel.dismissError()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var idleStateView: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                DropZoneView(
                    isTargeted: $isDropTargeted,
                    onPickFile: viewModel.selectFileWithPanel,
                    onFilesDropped: { urls in
                        guard let first = urls.first else { return }
                        viewModel.setInputFile(first)
                    }
                )
                .padding(20)

                if let selected = viewModel.selectedFileURL {
                    selectedFileBar(selected)
                        .padding(20)
                        .padding(.bottom, 4)
                }
            }
            .frame(minHeight: 240, maxHeight: .infinity)

            contextField
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
        }
    }

    private var contextField: some View {
        DisclosureGroup(isExpanded: $isShowingContext) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $viewModel.transcriptionPrompt)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 110, maxHeight: 110)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(NSColor.textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                if viewModel.transcriptionPrompt.isEmpty {
                    Text("Meeting topic, names, jargon...")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 6) {
                Label("Context (optional)", systemImage: "text.alignleft")
                    .font(.callout)
                Text("— helps Whisper with names and jargon")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !viewModel.transcriptionPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
        }
        .padding(12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func selectedFileBar(_ url: URL) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.fill")
                .foregroundStyle(.secondary)
            Text(url.lastPathComponent)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Start Processing") {
                viewModel.processSelectedFile()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canStart || viewModel.isPreparingRuntime)
        }
        .padding(12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
    }

    private var processingStateView: some View {
        VStack(spacing: 24) {
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                Text(viewModel.stage.displayTitle)
                    .font(.title2)
                    .fontWeight(.semibold)
                if let url = viewModel.selectedFileURL {
                    Text(url.lastPathComponent)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            DisclosureGroup(isExpanded: $isShowingLogs) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(viewModel.logs.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(10)
                }
                .frame(maxHeight: 220)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } label: {
                Label("Show details", systemImage: "terminal")
                    .font(.callout)
            }
            .frame(maxWidth: 480)

            Button("Cancel") {
                viewModel.cancelProcessing()
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resultStateView(outputURL: URL) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)

            Text("Processing completed")
                .font(.title)
                .fontWeight(.semibold)

            VStack(spacing: 4) {
                Text("Saved blocks: \(viewModel.blockCount)")
                Text("Mode: \(viewModel.processingMode.title)")
                if !viewModel.speakerNameMapping.isEmpty {
                    Text("Auto-labeled \(viewModel.speakerNameMapping.count) speaker(s) from voice library.")
                        .foregroundStyle(.green)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            Button(outputURL.lastPathComponent) {
                viewModel.openResultInFinder()
            }
            .buttonStyle(.link)
            .font(.callout)

            if viewModel.hasUnnamedSpeakers {
                unnamedSpeakersBanner
                    .padding(.top, 8)
            }

            HStack(spacing: 12) {
                Button("Open File") {
                    viewModel.openResultFile()
                }
                .buttonStyle(.borderedProminent)
                Button("Process Another") {
                    viewModel.resetForAnotherRun()
                }
            }
            .padding(.top, 8)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var unnamedSpeakersBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(viewModel.pendingSpeakerSuggestions.count) speaker(s) need a name")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text("Confirm matches or add new voices to your library.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Name speakers") {
                isShowingNamingSheet = true
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: 520)
    }
}
