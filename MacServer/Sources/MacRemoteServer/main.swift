import Foundation
import ApplicationServices

// Make output show up immediately (also when running as a LaunchAgent with a log file).
setvbuf(stdout, nil, _IOLBF, 0)

// MARK: PIN storage

let supportDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/MacRemote", isDirectory: true)
let pinFile = supportDir.appendingPathComponent("pin.txt")

func savePin(_ pin: String) {
    try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
    try? pin.write(to: pinFile, atomically: true, encoding: .utf8)
    chmod(pinFile.path, 0o600)
}

func loadOrCreatePin() -> String {
    if let saved = try? String(contentsOf: pinFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines), !saved.isEmpty {
        return saved
    }
    let pin = String(format: "%06d", Int.random(in: 0...999_999))
    savePin(pin)
    return pin
}

// MARK: Command line options

let args = CommandLine.arguments

if args.contains("--help") || args.contains("-h") {
    print("""
    MacRemoteServer – lets the Mac Remote iPhone app control this Mac.

    Options:
      --show-pin        Print the PIN and exit
      --reset-pin       Generate a new random PIN (phones will need the new one)
      --set-pin <pin>   Use your own PIN
      --p2p             Also allow direct Wi-Fi (AirDrop-style) connections when the
                        iPhone isn't on the same network. Can add some mouse lag.
    """)
    exit(0)
}
if args.contains("--reset-pin") {
    try? FileManager.default.removeItem(at: pinFile)
}
if let i = args.firstIndex(of: "--set-pin"), i + 1 < args.count {
    savePin(args[i + 1])
}
let pin = loadOrCreatePin()
if args.contains("--show-pin") {
    print(pin)
    exit(0)
}

// MARK: Accessibility permission

let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
if !AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary) {
    print("""
    ⚠️  Accessibility permission is needed to move the mouse and type.
       Open System Settings → Privacy & Security → Accessibility and turn on the app
       that is running this (Terminal, iTerm, or MacRemoteServer). Then restart this program.
       (It will keep running, but clicks and typing are ignored until permission is granted.)

    """)
}

// MARK: Start

let server = RemoteServer(pin: pin, peerToPeer: args.contains("--p2p"))
server.start()
server.startUDP()

print("""

🖥  Mac Remote server for “\(server.computerName)”
🔑 PIN: \(pin)

Open Mac Remote on your iPhone, pick this Mac, and enter the PIN.\(server.peerToPeer ? "\nDirect (peer-to-peer) connections are ON." : "")
Press Ctrl+C to stop.

""")

dispatchMain()
