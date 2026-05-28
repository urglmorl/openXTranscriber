import Foundation

struct ProcessOutput {
    let exitCode: Int32
    let stdoutLines: [String]
    let stderrLines: [String]
}

final class ProcessRunner {
    static let shared = ProcessRunner()

    private init() {}

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String] = [:],
        workingDirectory: URL? = nil,
        onStdout: ((String) -> Void)? = nil,
        onStderr: ((String) -> Void)? = nil,
        shouldCancel: @escaping () -> Bool = { false }
    ) async throws -> ProcessOutput {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            if let workingDirectory {
                process.currentDirectoryURL = workingDirectory
            }

            var mergedEnvironment = ProcessInfo.processInfo.environment
            for (key, value) in environment {
                mergedEnvironment[key] = value
            }
            let defaultPathPrefix = "/opt/homebrew/bin:/usr/local/bin"
            let existingPath = mergedEnvironment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            if !existingPath.contains("/opt/homebrew/bin") || !existingPath.contains("/usr/local/bin") {
                mergedEnvironment["PATH"] = "\(defaultPathPrefix):\(existingPath)"
            }
            process.environment = mergedEnvironment

            var stdoutLines: [String] = []
            var stderrLines: [String] = []
            var stdoutBuffer = Data()
            var stderrBuffer = Data()
            let newlineData = Data([0x0A]) // "\n"

            func decodeUTF8Line(_ data: Data) -> String {
                if let text = String(data: data, encoding: .utf8) {
                    return text
                }
                // Defensive fallback: never drop bytes if a line contains malformed UTF-8.
                return String(decoding: data, as: UTF8.self)
            }

            func consumeDataChunk(_ chunk: Data, lines: inout [String], buffer: inout Data, onLine: ((String) -> Void)?) {
                buffer.append(chunk)
                while let newlineRange = buffer.range(of: newlineData) {
                    let lineData = buffer.subdata(in: 0..<newlineRange.lowerBound)
                    let line = decodeUTF8Line(lineData)
                    lines.append(line)
                    onLine?(line)
                    buffer.removeSubrange(0..<newlineRange.upperBound)
                }
            }

            let stdoutHandle = stdoutPipe.fileHandleForReading
            let stderrHandle = stderrPipe.fileHandleForReading

            stdoutHandle.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                consumeDataChunk(data, lines: &stdoutLines, buffer: &stdoutBuffer, onLine: onStdout)
            }

            stderrHandle.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                consumeDataChunk(data, lines: &stderrLines, buffer: &stderrBuffer, onLine: onStderr)
            }

            process.terminationHandler = { completed in
                stdoutHandle.readabilityHandler = nil
                stderrHandle.readabilityHandler = nil

                let trailingStdout = stdoutHandle.readDataToEndOfFile()
                if !trailingStdout.isEmpty {
                    consumeDataChunk(trailingStdout, lines: &stdoutLines, buffer: &stdoutBuffer, onLine: onStdout)
                }
                let trailingStderr = stderrHandle.readDataToEndOfFile()
                if !trailingStderr.isEmpty {
                    consumeDataChunk(trailingStderr, lines: &stderrLines, buffer: &stderrBuffer, onLine: onStderr)
                }

                if !stdoutBuffer.isEmpty {
                    let line = decodeUTF8Line(stdoutBuffer)
                    stdoutLines.append(line)
                    onStdout?(line)
                    stdoutBuffer.removeAll(keepingCapacity: false)
                }
                if !stderrBuffer.isEmpty {
                    let line = decodeUTF8Line(stderrBuffer)
                    stderrLines.append(line)
                    onStderr?(line)
                    stderrBuffer.removeAll(keepingCapacity: false)
                }
                continuation.resume(returning: ProcessOutput(
                    exitCode: completed.terminationStatus,
                    stdoutLines: stdoutLines.filter { !$0.isEmpty },
                    stderrLines: stderrLines.filter { !$0.isEmpty }
                ))
            }

            do {
                try process.run()
            } catch {
                stdoutHandle.readabilityHandler = nil
                stderrHandle.readabilityHandler = nil
                continuation.resume(throwing: error)
                return
            }

            Task.detached {
                while process.isRunning {
                    if shouldCancel() {
                        process.terminate()
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
        }
    }
}
