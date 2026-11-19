import Foundation

/// The PIN phones must enter, kept in ~/Library/Application Support/MacRemote/pin.txt
/// (shared by the app, the command line and the LaunchAgent).
enum PinStore {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MacRemote", isDirectory: true)
    static let file = directory.appendingPathComponent("pin.txt")

    static func save(_ pin: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? pin.write(to: file, atomically: true, encoding: .utf8)
        chmod(file.path, 0o600)
    }

    /// The saved PIN, or a new random one (saved) if there isn't one yet.
    static func load() -> String {
        if let saved = try? String(contentsOf: file, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !saved.isEmpty {
            return saved
        }
        return reset()
    }

    /// Makes and saves a new random 6-digit PIN.
    @discardableResult
    static func reset() -> String {
        let pin = String(format: "%06d", Int.random(in: 0...999_999))
        save(pin)
        return pin
    }
}
