import AppKit
import ApplicationServices

/// Opened as "Mac Remote.app" → the window + menu bar app.
/// Run from Terminal (`swift run`, the LaunchAgent, or with any option below) → the plain server.
@main
enum Entry {
    static let commandLineOptions: Set<String> = [
        "--cli", "--help", "-h", "--show-pin", "--reset-pin", "--set-pin",
        "--dump-menubar", "--p2p", "--export-icon",
    ]

    @MainActor
    static func main() {
        // Make output show up immediately (also when running as a LaunchAgent with a log file).
        setvbuf(stdout, nil, _IOLBF, 0)

        let arguments = CommandLine.arguments
        let launchedAsApp = Bundle.main.bundlePath.hasSuffix(".app")
            && !arguments.dropFirst().contains(where: { commandLineOptions.contains($0) })

        if launchedAsApp {
            MacRemoteApp.main()
        } else {
            runCommandLine(arguments)
        }
    }
}

// MARK: - Command line

func runCommandLine(_ args: [String]) -> Never {
    if args.contains("--help") || args.contains("-h") {
        print("""
        MacRemoteServer – lets the Mac Remote iPhone app control this Mac.

        Options:
          --show-pin        Print the PIN and exit
          --reset-pin       Generate a new random PIN (phones will need the new one)
          --set-pin <pin>   Use your own PIN
          --dump-menubar [text]
                            Diagnostic: print how macOS exposes the menu bar (for Screen
                            Mirroring). With text, also press the first item matching it.
          --p2p             Also allow direct Wi-Fi (AirDrop-style) connections when the
                            iPhone isn't on the same network. Can add some mouse lag.
          --export-icon <file.png>
                            Write the app icon (used when building Mac Remote.app)
        """)
        exit(0)
    }
    if let i = args.firstIndex(of: "--export-icon"), i + 1 < args.count {
        exit(AppIcon.writePNG(to: URL(fileURLWithPath: args[i + 1])) ? 0 : 1)
    }
    if args.contains("--reset-pin") {
        PinStore.reset()
    }
    if let i = args.firstIndex(of: "--set-pin"), i + 1 < args.count {
        PinStore.save(args[i + 1])
    }
    let pin = PinStore.load()
    if args.contains("--show-pin") {
        print(pin)
        exit(0)
    }

    // Accessibility permission
    let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    if !AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary) {
        print("""
        ⚠️  Accessibility permission is needed to move the mouse and type.
           Open System Settings → Privacy & Security → Accessibility and turn on the app
           that is running this (Terminal, iTerm, or MacRemoteServer). Then restart this program.
           (It will keep running, but clicks and typing are ignored until permission is granted.)

        """)
    }

    if let i = args.firstIndex(of: "--dump-menubar") {
        let needle = (i + 1 < args.count && !args[i + 1].hasPrefix("--")) ? args[i + 1] : nil
        MenuBarInspector.run(pressMatching: needle)
        exit(0)
    }

    let server = RemoteServer(pin: pin, peerToPeer: args.contains("--p2p"))
    server.start()
    server.startUDP()

    print("""

    🖥  Mac Remote server for “\(server.computerName)”
    🔑 PIN: \(pin)

    Open Mac Remote on your iPhone, pick this Mac, and enter the PIN.\(server.peerToPeer ? "\nDirect (peer-to-peer) connections are ON." : "")
    Press Ctrl+C to stop.

    """)

    withExtendedLifetime(server) {
        dispatchMain()
    }
}
