import Foundation

protocol RuntimeManaging {
    func prepareRuntimeIfNeeded(
        customPythonPath: String?,
        forceReinstall: Bool,
        log: @escaping (String) -> Void,
        shouldCancel: @escaping () -> Bool
    ) async throws -> PythonCommand
    func resolveAvailableRuntime(customPythonPath: String?) async -> PythonCommand?
    func runtimeDirectory() throws -> URL
}

final class RuntimeManager: RuntimeManaging {
    static let shared = RuntimeManager()

    private init() {}

    private let fm = FileManager.default
    private let probeTimeoutSeconds: TimeInterval = 8

    func runtimeDirectory() throws -> URL {
        let appSupport = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let runtimeDir = appSupport
            .appendingPathComponent("openXTranscriber", isDirectory: true)
            .appendingPathComponent("runtime", isDirectory: true)
        try fm.createDirectory(at: runtimeDir, withIntermediateDirectories: true)
        return runtimeDir
    }

    func resolveAvailableRuntime(customPythonPath: String?) async -> PythonCommand? {
        let managed = try? managedPythonCommand()
        if let managed, await isPythonCommandHealthy(managed) {
            return managed
        }

        for candidate in bootstrapCandidates(customPythonPath: customPythonPath) {
            if await isPythonCommandHealthy(candidate) {
                return candidate
            }
        }
        return nil
    }

    func prepareRuntimeIfNeeded(
        customPythonPath: String?,
        forceReinstall: Bool,
        log: @escaping (String) -> Void,
        shouldCancel: @escaping () -> Bool
    ) async throws -> PythonCommand {
        let dir = try runtimeDirectory()
        try stageScriptsIfNeeded(in: dir)
        let managed = try managedPythonCommand()
        if !forceReinstall, await isManagedRuntimeHealthy(python: managed) {
            log("Using managed runtime: \(managed.displayName)")
            return managed
        }

        guard let bootstrap = await resolveBootstrapPython(customPythonPath: customPythonPath) else {
            throw PipelineError.runtimeSetupFailed(
                message: "No Python runtime found. Install Python 3.10+ or configure a Python path in Settings."
            )
        }

        let venvDir = dir.appendingPathComponent("venv", isDirectory: true)

        if forceReinstall, fm.fileExists(atPath: venvDir.path) {
            try fm.removeItem(at: venvDir)
        }

        log("Preparing managed runtime...")
        try await run(
            command: bootstrap,
            arguments: ["-m", "venv", venvDir.path],
            log: log,
            shouldCancel: shouldCancel
        )

        let managedPython = try managedPythonCommand()
        log("Installing runtime dependencies...")
        try await run(
            command: managedPython,
            arguments: ["-m", "pip", "install", "--upgrade", "pip", "setuptools", "wheel"],
            log: log,
            shouldCancel: shouldCancel
        )
        try await run(
            command: managedPython,
            arguments: ["-m", "pip", "install", "mlx-whisper", "pyannote.audio"],
            log: log,
            shouldCancel: shouldCancel
        )
        try await run(
            command: managedPython,
            arguments: ["-c", "import mlx_whisper, pyannote.audio"],
            log: log,
            shouldCancel: shouldCancel
        )

        try writeHealthMarker(for: managedPython)
        log("Managed runtime is ready.")
        return managedPython
    }

    private func managedPythonCommand() throws -> PythonCommand {
        let dir = try runtimeDirectory()
        let pythonPath = dir
            .appendingPathComponent("venv/bin/python3", isDirectory: false)
            .path
        return PythonCommand(executable: pythonPath, prefixArguments: [], displayName: "Managed runtime")
    }

    private func bootstrapCandidates(customPythonPath: String?) -> [PythonCommand] {
        var candidates: [PythonCommand] = []

        if let customPythonPath, !customPythonPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append(PythonCommand(
                executable: customPythonPath,
                prefixArguments: [],
                displayName: "Custom runtime"
            ))
        }

        if let embedded = embeddedRuntimePath() {
            candidates.append(PythonCommand(
                executable: embedded,
                prefixArguments: [],
                displayName: "Embedded runtime"
            ))
        }

        let absoluteCandidates = [
            "/opt/homebrew/bin/python3",
            "/opt/homebrew/Caskroom/mambaforge/base/bin/python3",
            "\(NSHomeDirectory())/miniforge3/bin/python3",
            "\(NSHomeDirectory())/mambaforge/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3"
        ]
        for path in absoluteCandidates {
            candidates.append(PythonCommand(executable: path, prefixArguments: [], displayName: path))
        }

        candidates.append(PythonCommand(
            executable: "/usr/bin/env",
            prefixArguments: ["python3"],
            displayName: "python3 from PATH"
        ))

        return candidates
    }

    private func embeddedRuntimePath() -> String? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let candidate = resourceURL
            .appendingPathComponent("Runtime", isDirectory: true)
            .appendingPathComponent("bin/python3", isDirectory: false)
            .path
        if fm.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }

    private func resolveBootstrapPython(customPythonPath: String?) async -> PythonCommand? {
        for candidate in bootstrapCandidates(customPythonPath: customPythonPath) {
            if await isPythonCommandHealthy(candidate) {
                return candidate
            }
        }
        return nil
    }

    private func isManagedRuntimeHealthy(python: PythonCommand) async -> Bool {
        let hasMarker = (try? runtimeDirectory()
            .appendingPathComponent("runtime-health.json")
            .path)
            .map { fm.fileExists(atPath: $0) } ?? false
        if !hasMarker {
            return false
        }
        let pythonHealthy = await isPythonCommandHealthy(python)
        guard pythonHealthy else {
            return false
        }
        return await canImportDependencies(python)
    }

    private func isPythonCommandHealthy(_ command: PythonCommand) async -> Bool {
        guard command.executable == "/usr/bin/env" || fm.isExecutableFile(atPath: command.executable) else {
            return false
        }
        return await runProbe(command: command, arguments: ["--version"])
    }

    private func canImportDependencies(_ command: PythonCommand) async -> Bool {
        return await runProbe(
            command: command,
            arguments: ["-c", "import mlx_whisper, pyannote.audio"]
        )
    }

    private func writeHealthMarker(for command: PythonCommand) throws {
        let markerURL = try runtimeDirectory().appendingPathComponent("runtime-health.json")
        let payload = [
            "pythonExecutable": command.executable,
            "createdAt": ISO8601DateFormatter().string(from: Date())
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
        try data.write(to: markerURL, options: .atomic)
    }

    private func stageScriptsIfNeeded(in runtimeDir: URL) throws {
        let scriptsDirectory = runtimeDir.appendingPathComponent("scripts", isDirectory: true)
        try fm.createDirectory(at: scriptsDirectory, withIntermediateDirectories: true)

        for name in ["transcribe", "diarize", "embed"] {
            guard let source = scriptSource(named: name) else { continue }
            let destination = scriptsDirectory.appendingPathComponent("\(name).py")
            if fm.fileExists(atPath: destination.path) {
                let sourceData = try Data(contentsOf: source)
                let destinationData = try Data(contentsOf: destination)
                if sourceData == destinationData {
                    continue
                }
                try fm.removeItem(at: destination)
            }
            try fm.copyItem(at: source, to: destination)
        }
    }

    private func scriptSource(named name: String) -> URL? {
        if let bundled = Bundle.main.url(forResource: name, withExtension: "py", subdirectory: "Scripts") {
            return bundled
        }
        let projectCandidate = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Scripts/\(name).py")
        if fm.fileExists(atPath: projectCandidate.path) {
            return projectCandidate
        }
        return nil
    }

    private func run(
        command: PythonCommand,
        arguments: [String],
        log: @escaping (String) -> Void,
        shouldCancel: @escaping () -> Bool
    ) async throws {
        let output = try await ProcessRunner.shared.run(
            executable: command.executable,
            arguments: command.makeArguments(arguments),
            onStdout: { line in
                if !line.isEmpty {
                    log(line)
                }
            },
            onStderr: { line in
                if !line.isEmpty {
                    log("stderr: \(line)")
                }
            },
            shouldCancel: shouldCancel
        )
        if shouldCancel() {
            throw PipelineError.cancelled
        }
        guard output.exitCode == 0 else {
            throw PipelineError.runtimeSetupFailed(message: "Runtime bootstrap failed while running: \(arguments.joined(separator: " "))")
        }
    }

    private func runProbe(command: PythonCommand, arguments: [String]) async -> Bool {
        let start = Date()
        do {
            let output = try await ProcessRunner.shared.run(
                executable: command.executable,
                arguments: command.makeArguments(arguments),
                shouldCancel: {
                    Date().timeIntervalSince(start) > self.probeTimeoutSeconds
                }
            )
            return output.exitCode == 0
        } catch {
            return false
        }
    }
}
