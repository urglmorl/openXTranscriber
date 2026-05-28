import Foundation

/// Persistence layer for the screen-recording feature. Mirrors the small
/// `SettingsStore` from openXRecorder but writes under transcriber-namespaced
/// UserDefaults keys so it doesn't collide with anything else.
enum RecordingSettings {
    private static let folderKey = "recordingOutputFolderPath"
    private static let noiseGateKey = "recordingNoiseGateEnabled"
    private static let defaults = UserDefaults.standard

    static var outputFolderURL: URL {
        if let path = defaults.string(forKey: folderKey), !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return defaultOutputFolder
    }

    static var defaultOutputFolder: URL {
        let movies = (try? FileManager.default.url(
            for: .moviesDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        )) ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Movies")
        return movies.appendingPathComponent("openXTranscriber", isDirectory: true)
    }

    static var isOutputFolderCustom: Bool {
        outputFolderURL.standardizedFileURL.path != defaultOutputFolder.standardizedFileURL.path
    }

    static var outputFolderDisplayName: String {
        (outputFolderURL.path as NSString).abbreviatingWithTildeInPath
    }

    static func setOutputFolder(_ url: URL) {
        defaults.set(url.path, forKey: folderKey)
    }

    static func resetOutputFolder() {
        defaults.removeObject(forKey: folderKey)
    }

    /// Default: on. When the key has never been written, treat as enabled.
    static var noiseGateEnabled: Bool {
        if defaults.object(forKey: noiseGateKey) == nil { return true }
        return defaults.bool(forKey: noiseGateKey)
    }

    static func setNoiseGateEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: noiseGateKey)
    }
}
