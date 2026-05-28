import SwiftUI

struct OnboardingView: View {
    let onCompleted: () -> Void

    @State private var tokenInput = ""
    @State private var tokenStatus: TokenStatus = .idle
    @State private var modelStates: [ModelEntry] = []
    @State private var lastTokenError: String?

    @Environment(\.openURL) private var openURL

    private static let signInURL = URL(string: "https://huggingface.co/login")!
    private static let createTokenURL = URL(string: "https://huggingface.co/settings/tokens/new?tokenType=read")!

    private static let modelDescriptors: [ModelDescriptor] = [
        .init(id: "pyannote/speaker-diarization-3.1", title: "speaker-diarization-3.1"),
        .init(id: "pyannote/speaker-diarization-community-1", title: "speaker-diarization-community-1"),
        .init(id: "pyannote/segmentation-3.0", title: "segmentation-3.0")
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                stepOne
                stepTwo
                stepThree
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 16)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .frame(minWidth: 640, minHeight: 600)
        .onAppear {
            if modelStates.isEmpty {
                modelStates = Self.modelDescriptors.map {
                    ModelEntry(id: $0.id, title: $0.title, status: .unchecked, pageURL: $0.pageURL)
                }
            }
            let saved = KeychainHelper.shared.loadToken() ?? ""
            if !saved.isEmpty {
                tokenInput = saved
                Task { await verifyToken(silent: true) }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Welcome to openXTranscriber")
                .font(.title)
                .fontWeight(.semibold)
            Text("A one-time setup to enable speaker diarization.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Step 1

    private var stepOne: some View {
        StepCard(
            number: 1,
            title: String(localized: "Sign in to Hugging Face"),
            state: tokenStatus.isValid ? .done : .active,
            doneLabel: String(localized: "Signed in")
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Free account. Diarization models are downloaded from there.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                Button {
                    openURL(Self.signInURL)
                } label: {
                    Label("Open Hugging Face", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Step 2

    private var stepTwo: some View {
        let state: StepState = {
            switch tokenStatus {
            case .valid: return .done
            case .checking: return .active
            case .invalid, .error: return .needsAttention
            case .idle: return tokenStatus.isValid ? .done : .active
            }
        }()

        return StepCard(
            number: 2,
            title: String(localized: "Add access token"),
            state: state,
            doneLabel: String(localized: "Token verified")
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Generate a Read-only token. We store it in macOS Keychain — never on disk in plain text.")
                    .foregroundStyle(.secondary)
                    .font(.callout)

                Button {
                    openURL(Self.createTokenURL)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle.fill")
                        Text("Create new token")
                    }
                    .font(.callout)
                }
                .buttonStyle(.link)

                HStack(spacing: 8) {
                    SecureField(String(localized: "hf_… token"), text: $tokenInput, onCommit: {
                        Task { await verifyToken(silent: false) }
                    })
                    .textFieldStyle(.roundedBorder)
                    .disabled(tokenStatus.isChecking)

                    Button {
                        Task { await verifyToken(silent: false) }
                    } label: {
                        if tokenStatus.isChecking {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Verify")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || tokenStatus.isChecking)
                }

                tokenStatusLine
            }
        }
    }

    @ViewBuilder
    private var tokenStatusLine: some View {
        switch tokenStatus {
        case .idle:
            EmptyView()
        case .checking:
            Label(String(localized: "Verifying…"), systemImage: "ellipsis.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .valid:
            EmptyView()
        case .invalid(let detail):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Token rejected. Make sure you copied the full string.")
                    if let detail, !detail.isEmpty {
                        Text(detail).foregroundStyle(.secondary)
                    }
                }
            }
            .font(.footnote)
        case .error(let message):
            HStack(spacing: 6) {
                Image(systemName: "wifi.slash").foregroundStyle(.orange)
                Text("Could not reach Hugging Face: \(message)")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Step 3

    private var stepThree: some View {
        let allGranted = !modelStates.isEmpty && modelStates.allSatisfy { $0.status.isGranted }
        let anyDenied = modelStates.contains { if case .denied = $0.status { return true } else { return false } }
        let state: StepState = {
            if !tokenStatus.isValid { return .pending }
            if allGranted { return .done }
            if anyDenied { return .needsAttention }
            return .active
        }()
        let grantedCount = modelStates.filter { $0.status.isGranted }.count

        return StepCard(
            number: 3,
            title: String(localized: "Accept model agreements"),
            state: state,
            doneLabel: String(localized: "All accepted")
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if !tokenStatus.isValid {
                    Text("Add your access token first — we use it to check which agreements are already accepted.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    Text("Three pyannote models. Each needs a one-time agreement on Hugging Face. Click \"Open\" → press the green \"Agree and access repository\" button → come back here.")
                        .foregroundStyle(.secondary)
                        .font(.callout)

                    VStack(spacing: 0) {
                        ForEach(Array(modelStates.enumerated()), id: \.element.id) { index, entry in
                            modelRow(entry)
                            if index < modelStates.count - 1 {
                                Divider().padding(.leading, 28)
                            }
                        }
                    }
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    HStack {
                        Text("\(grantedCount) of \(modelStates.count) accepted")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            Task { await checkAllModels() }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.clockwise")
                                Text("Recheck")
                            }
                            .font(.callout)
                        }
                        .buttonStyle(.link)
                        .disabled(modelStates.contains { if case .checking = $0.status { return true } else { return false } })
                    }
                }
            }
        }
    }

    private func modelRow(_ entry: ModelEntry) -> some View {
        HStack(spacing: 10) {
            modelStatusIcon(entry.status)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.callout)
                modelRowSubline(entry.status)
            }

            Spacer()

            switch entry.status {
            case .denied, .error:
                Button("Open") { openURL(entry.pageURL) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            case .granted:
                EmptyView()
            case .checking, .unchecked:
                EmptyView()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func modelStatusIcon(_ status: ModelStatus) -> some View {
        switch status {
        case .unchecked:
            Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        case .checking:
            ProgressView().controlSize(.small)
        case .granted:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .denied:
            Image(systemName: "lock.fill").foregroundStyle(.orange)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private func modelRowSubline(_ status: ModelStatus) -> some View {
        switch status {
        case .unchecked:
            EmptyView()
        case .checking:
            Text("Checking…").font(.caption).foregroundStyle(.secondary)
        case .granted:
            Text("Access granted").font(.caption).foregroundStyle(.secondary)
        case .denied:
            Text("Agreement not accepted yet").font(.caption).foregroundStyle(.secondary)
        case .error(let message):
            Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Button("Continue without diarization") {
                    onCompleted()
                }
                Spacer()
                Button("Finish") {
                    onCompleted()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canFinish)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }

    private var canFinish: Bool {
        tokenStatus.isValid && !modelStates.isEmpty && modelStates.allSatisfy { $0.status.isGranted }
    }

    // MARK: - Actions

    private func verifyToken(silent: Bool) async {
        let trimmed = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            tokenStatus = .invalid(nil)
            return
        }
        await MainActor.run { tokenStatus = .checking }

        let result = await HuggingFaceClient.validateToken(trimmed)

        await MainActor.run {
            switch result {
            case .valid:
                do { try KeychainHelper.shared.saveToken(trimmed) } catch {}
                tokenStatus = .valid
                resetModelChecks()
                Task { await checkAllModels() }
            case .invalid:
                tokenStatus = .invalid(nil)
            case .network(let detail):
                tokenStatus = .error(detail)
            }
        }
    }

    private func resetModelChecks() {
        for index in modelStates.indices {
            modelStates[index].status = .unchecked
        }
    }

    private func checkAllModels() async {
        let token = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }

        await MainActor.run {
            for index in modelStates.indices {
                modelStates[index].status = .checking
            }
        }

        await withTaskGroup(of: (Int, ModelStatus).self) { group in
            for (index, entry) in modelStates.enumerated() {
                let modelID = entry.id
                group.addTask {
                    let result = await HuggingFaceClient.checkModelAccess(modelID: modelID, token: token)
                    let mapped: ModelStatus
                    switch result {
                    case .granted: mapped = .granted
                    case .denied, .notFound: mapped = .denied
                    case .unauthorized: mapped = .denied
                    case .network(let detail): mapped = .error(detail)
                    }
                    return (index, mapped)
                }
            }
            for await (index, status) in group {
                await MainActor.run {
                    if modelStates.indices.contains(index) {
                        modelStates[index].status = status
                    }
                }
            }
        }
    }
}

// MARK: - Step Card

private enum StepState {
    case pending
    case active
    case done
    case needsAttention
}

private struct StepCard<Content: View>: View {
    let number: Int
    let title: String
    let state: StepState
    let doneLabel: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                badge
                Text(title)
                    .font(.headline)
                Spacer()
                stateBadge
            }
            content()
                .opacity(state == .pending ? 0.5 : 1)
                .disabled(state == .pending)
                .padding(.leading, 40)
        }
        .padding(16)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(borderColor, lineWidth: state == .done || state == .needsAttention ? 1.5 : 0.5)
        )
        .shadow(color: .black.opacity(0.06), radius: 6, y: 1)
    }

    private var badge: some View {
        ZStack {
            Circle()
                .fill(badgeFill)
                .frame(width: 28, height: 28)
            badgeContent
                .foregroundStyle(.white)
                .font(.system(size: 14, weight: .semibold))
        }
    }

    @ViewBuilder
    private var badgeContent: some View {
        switch state {
        case .done:
            Image(systemName: "checkmark")
        case .needsAttention:
            Image(systemName: "exclamationmark")
        default:
            Text("\(number)")
        }
    }

    private var badgeFill: Color {
        switch state {
        case .pending: return Color.secondary.opacity(0.4)
        case .active: return Color.accentColor
        case .done: return .green
        case .needsAttention: return .orange
        }
    }

    private var borderColor: Color {
        switch state {
        case .done: return .green.opacity(0.4)
        case .needsAttention: return .orange.opacity(0.5)
        default: return .secondary.opacity(0.15)
        }
    }

    @ViewBuilder
    private var stateBadge: some View {
        switch state {
        case .done:
            Label(doneLabel, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.green)
        case .needsAttention:
            Label(String(localized: "Needs attention"), systemImage: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        case .active, .pending:
            EmptyView()
        }
    }
}

// MARK: - Models

private extension OnboardingView {
    enum TokenStatus: Equatable {
        case idle
        case checking
        case valid
        case invalid(String?)
        case error(String)

        var isValid: Bool { if case .valid = self { return true } else { return false } }
        var isChecking: Bool { if case .checking = self { return true } else { return false } }
    }

    enum ModelStatus: Equatable {
        case unchecked
        case checking
        case granted
        case denied
        case error(String)

        var isGranted: Bool { if case .granted = self { return true } else { return false } }
    }

    struct ModelDescriptor {
        let id: String
        let title: String
        var pageURL: URL { URL(string: "https://huggingface.co/\(id)")! }
    }

    struct ModelEntry: Identifiable, Equatable {
        let id: String
        let title: String
        var status: ModelStatus
        var pageURL: URL
    }
}

#Preview {
    OnboardingView {}
}
