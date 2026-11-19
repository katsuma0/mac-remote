import Foundation

/// Log lines go to stdout (Terminal / LaunchAgent log) and, in the app, to its Activity list.
enum Log {
    /// Called on the main queue for every line.
    static var handler: ((String) -> Void)?

    static func write(_ line: String) {
        print(line)
        if Thread.isMainThread {
            handler?(line)
        } else {
            DispatchQueue.main.async { handler?(line) }
        }
    }
}
