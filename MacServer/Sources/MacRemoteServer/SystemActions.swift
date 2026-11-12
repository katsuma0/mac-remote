import Foundation

/// Things that are easier to do with built-in command line tools.
/// All functions must be called on the main queue.
enum SystemActions {
    private static var volumeBusy = false
    private static var pendingVolume: Int?

    /// Sets output volume 0–100. Requests are coalesced so dragging a slider doesn't spawn hundreds of processes.
    static func setVolume(_ value: Int) {
        pendingVolume = max(0, min(100, value))
        runPendingVolume()
    }

    private static func runPendingVolume() {
        guard !volumeBusy, let v = pendingVolume else { return }
        pendingVolume = nil
        volumeBusy = true
        run("/usr/bin/osascript", ["-e", "set volume output volume \(v)"]) { _ in
            volumeBusy = false
            runPendingVolume()
        }
    }

    static func getVolume(_ completion: @escaping (Int?) -> Void) {
        run("/usr/bin/osascript", ["-e", "output volume of (get volume settings)"]) { output in
            completion(Int(output))
        }
    }

    static func sleepDisplay() {
        run("/usr/bin/pmset", ["displaysleepnow"])
    }

    /// Runs a process off the main thread and calls back on the main queue with trimmed stdout.
    static func run(_ path: String, _ args: [String], completion: ((String) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            var output = ""
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                output = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            } catch {
                print("Failed to run \(path): \(error)")
            }
            DispatchQueue.main.async { completion?(output) }
        }
    }
}
