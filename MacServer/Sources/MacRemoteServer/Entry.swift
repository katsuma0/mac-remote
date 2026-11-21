import AppKit
import ApplicationServices

/// Opened as "Couchpad.app" → the window + menu bar app.
/// Run from Terminal (`swift run`, the LaunchAgent, or with any option below) → the plain server.
@main
enum Entry {
    static let commandLineOptions: Set<String> = [
        "--cli", "--help", "-h", "--pair", "--list-pairings", "--unpair-all",
        "--dump-menubar", "--p2p",
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
        Couchpad (command-line server) – lets the Couchpad iPhone app control this Mac.

        Options:
          --pair            Open pairing for 3 minutes and print the code to enter on the iPhone
          --list-pairings   Show the iPhones paired with this Mac
          --unpair-all      Forget every paired iPhone
          --p2p             Also allow direct Wi-Fi (AirDrop-style) connections when the
                            iPhone isn't on the same network. Can add some mouse lag.
          --dump-menubar [text]
                            Diagnostic: print how macOS exposes the menu bar (for Screen
                            Mirroring). With text, also press the first item matching it.
        """)
        exit(0)
    }

    let pairings = PairingStore.shared
    if args.contains("--list-pairings") {
        if pairings.phones.isEmpty { print("No paired iPhones.") }
        for phone in pairings.phones {
            print("• \(phone.name)  (paired \(phone.pairedAt.formatted(date: .abbreviated, time: .shortened)))")
        }
        exit(0)
    }
    if args.contains("--unpair-all") {
        pairings.removeAll()
        print("Forgot all paired iPhones.")
        exit(0)
    }

    if !Permissions.isGranted {
        Permissions.request()
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

    let server = RemoteServer(peerToPeer: args.contains("--p2p"))
    server.start()
    server.startUDP()

    print("""

    🖥  Couchpad for “\(server.computerName)”
    \(pairings.phones.isEmpty ? "No iPhones paired yet." : "Paired iPhones: \(pairings.phones.map(\.name).joined(separator: ", "))")\(server.peerToPeer ? "\nDirect (peer-to-peer) connections are ON." : "")
    Press Ctrl+C to stop.

    """)

    if args.contains("--pair") || pairings.phones.isEmpty {
        let window = server.openPairing()
        print("""
        🔗 Pairing is open for 3 minutes. On your iPhone, open Couchpad, pick this Mac and enter:

               \(window.code.prefix(3)) \(window.code.suffix(3))

        """)
    }

    withExtendedLifetime(server) {
        dispatchMain()
    }
}
