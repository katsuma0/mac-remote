import Foundation

/// Things that are easier to do with built-in command line tools.
/// All functions must be called on the main queue.
enum SystemActions {
    private static var volumeBusy = false
    private static var pendingVolume: Int?

    /// Sets output volume 0–100 (and unmutes). Requests are coalesced so dragging a slider
    /// doesn't spawn hundreds of processes.
    static func setVolume(_ value: Int) {
        pendingVolume = max(0, min(100, value))
        runPendingVolume()
    }

    private static func runPendingVolume() {
        guard !volumeBusy, let v = pendingVolume else { return }
        pendingVolume = nil
        volumeBusy = true
        run("/usr/bin/osascript", ["-e", "set volume output volume \(v)",
                                   "-e", "set volume output muted false"]) { _ in
            volumeBusy = false
            runPendingVolume()
        }
    }

    /// Current output volume (nil when the output device has no volume, e.g. some HDMI/AirPlay outputs) and mute state.
    static func getVolume(_ completion: @escaping (_ volume: Int?, _ muted: Bool) -> Void) {
        run("/usr/bin/osascript", ["-e", "set s to get volume settings",
                                   "-e", "return ((output volume of s) as text) & \",\" & ((output muted of s) as text)"]) { result in
            let parts = result.output.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let volume = parts.first.flatMap { Int($0) }
            let muted = parts.count > 1 && parts[1] == "true"
            completion(volume, muted)
        }
    }

    static func sleepDisplay() {
        run("/usr/bin/pmset", ["displaysleepnow"])
    }

    struct Result {
        var output: String
        var error: String
        var status: Int32
    }

    /// Runs a process off the main thread and calls back on the main queue with trimmed stdout/stderr.
    static func run(_ path: String, _ args: [String], completion: ((Result) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            var result = Result(output: "", error: "", status: -1)
            do {
                try process.run()
                // The tools we run print very little, so reading stdout then stderr can't fill a pipe.
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                result.output = String(data: outData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                result.error = String(data: errData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                result.status = process.terminationStatus
            } catch {
                result.error = "Failed to run \(path): \(error)"
                Log.write(result.error)
            }
            DispatchQueue.main.async { completion?(result) }
        }
    }
}
