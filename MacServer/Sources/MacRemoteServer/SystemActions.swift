import Foundation

/// Things done with built-in command line tools (outside the App Store build).
/// All functions must be called on the main queue.
enum SystemActions {
    /// Not available in the App Store build: the sandbox doesn't allow it.
    static var canSleepDisplay: Bool {
        #if APP_STORE
        return false
        #else
        return true
        #endif
    }

    static func sleepDisplay() {
        guard canSleepDisplay else { return }
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
