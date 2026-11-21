import AppKit
import Combine
import CoreImage.CIFilterBuiltins
import ServiceManagement
#if canImport(RemoteCore)
import RemoteCore
#endif

/// State behind the Mac app's window and menu bar icon. Everything runs on the main queue.
final class AppModel: ObservableObject {
    static let shared = AppModel()

    struct PairingInfo: Equatable {
        let code: String
        let link: URL
        let expires: Date
    }

    @Published private(set) var isRunning = false
    @Published private(set) var isListening = false
    @Published private(set) var connectedPhoneNames: [String] = []
    @Published private(set) var connectedPhoneIds: Set<String> = []
    @Published private(set) var pairedPhones: [PairedPhone] = []
    @Published private(set) var accessibilityGranted = Permissions.isGranted
    @Published private(set) var activity: [String] = []

    /// Pairing sheet state.
    @Published var showingPairing = false
    @Published private(set) var pairing: PairingInfo?
    @Published private(set) var justPaired: String?
    /// An unpaired iPhone tried to connect while pairing was closed.
    @Published var pairingRequestedBy: String?

    @Published var peerToPeer = UserDefaults.standard.bool(forKey: "peerToPeer") {
        didSet {
            UserDefaults.standard.set(peerToPeer, forKey: "peerToPeer")
            if isRunning { restart() }
        }
    }

    @Published var startAutomatically = UserDefaults.standard.object(forKey: "startAutomatically") as? Bool ?? true {
        didSet { UserDefaults.standard.set(startAutomatically, forKey: "startAutomatically") }
    }

    @Published var openAtLogin = SMAppService.mainApp.status == .enabled {
        didSet {
            guard !updatingLoginItem else { return }
            setOpenAtLogin(openAtLogin)
        }
    }

    let computerName = RemoteServer.localComputerName

    private var server: RemoteServer?
    private var permissionTimer: Timer?
    private var activityToken: NSObjectProtocol?
    private var updatingLoginItem = false

    private init() {
        Log.handler = { [weak self] line in self?.append(line) }
        pairedPhones = PairingStore.shared.phones
        PairingStore.shared.onChange = { [weak self] in
            self?.pairedPhones = PairingStore.shared.phones
        }
        // Re-check permission every couple of seconds so the window updates as soon as it's granted.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            let granted = Permissions.isGranted
            if granted != self.accessibilityGranted { self.accessibilityGranted = granted }
        }
    }

    /// Called once the app has finished launching.
    func appDidLaunch() {
        if startAutomatically { start() }
    }

    // MARK: Status

    var statusText: String {
        if !isRunning { return "Off – your iPhone can't see this Mac" }
        if let name = connectedPhoneNames.first {
            return connectedPhoneNames.count == 1 ? "Connected to \(name)" : "\(connectedPhoneNames.count) iPhones connected"
        }
        if pairedPhones.isEmpty { return "Ready – pair your iPhone to start" }
        return isListening ? "Ready – open Couchpad on your iPhone" : "Starting…"
    }

    func isConnected(_ phone: PairedPhone) -> Bool {
        connectedPhoneIds.contains(phone.id)
    }

    // MARK: Start / stop

    func toggle() {
        isRunning ? stop() : start()
    }

    func start() {
        guard server == nil else { return }
        if !Permissions.isGranted { Permissions.request() }

        let newServer = RemoteServer(peerToPeer: peerToPeer)
        newServer.onStatusChange = { [weak self, weak newServer] in
            guard let self, let newServer, newServer === self.server else { return }
            self.refresh(from: newServer)
        }
        newServer.onPaired = { [weak self] name in
            self?.justPaired = name
            self?.pairingRequestedBy = nil
        }
        newServer.onPairingRequested = { [weak self, weak newServer] name in
            guard let self, newServer?.pairingWindow == nil else { return }
            self.pairingRequestedBy = name
            NSApp.requestUserAttention(.informationalRequest)
        }
        server = newServer
        newServer.start()
        newServer.startUDP()
        isRunning = true

        // Keep macOS from napping the app while it's in the background, which would make the mouse lag.
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Receiving mouse and keyboard input from iPhone")

        Log.write("▶️ On – iPhones on your Wi-Fi can now find “\(computerName)”.")
    }

    func stop() {
        guard let server else { return }
        self.server = nil
        server.stop()
        isRunning = false
        isListening = false
        connectedPhoneNames = []
        connectedPhoneIds = []
        pairing = nil
        if let activityToken {
            ProcessInfo.processInfo.endActivity(activityToken)
            self.activityToken = nil
        }
        Log.write("⏹ Off – this Mac is hidden from iPhones.")
    }

    private func restart() {
        stop()
        start()
    }

    private func refresh(from server: RemoteServer) {
        isListening = server.isListening
        connectedPhoneNames = server.connectedPhones
        connectedPhoneIds = server.connectedPhoneIds
        if let window = server.pairingWindow {
            let link = window.link(macId: server.pairings.macId, macName: computerName).url
            let info = PairingInfo(code: window.code, link: link, expires: window.expires)
            if pairing != info { pairing = info }
        } else if pairing != nil {
            pairing = nil
        }
    }

    // MARK: Pairing

    /// Opens pairing and shows the sheet with the QR code and 6-digit code.
    func beginPairing() {
        if server == nil { start() }
        justPaired = nil
        pairingRequestedBy = nil
        server?.openPairing()
        showingPairing = true
    }

    func endPairing() {
        server?.closePairing()
        showingPairing = false
        justPaired = nil
    }

    func unpair(_ phone: PairedPhone) {
        if let server {
            server.unpair(phone.id)
        } else {
            PairingStore.shared.remove(phone.id)
        }
        Log.write("🗑 Unpaired “\(phone.name)”.")
    }

    /// A QR code image for the pairing link.
    static func qrCode(for url: URL) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        let representation = NSCIImageRep(ciImage: output)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }

    // MARK: Permissions & login item

    func requestAccessibility() {
        Permissions.request()
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func setOpenAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.write("⚠️ Couldn't change Open at Login: \(error.localizedDescription)")
            updatingLoginItem = true
            openAtLogin = SMAppService.mainApp.status == .enabled
            updatingLoginItem = false
        }
    }

    // MARK: Activity log

    private func append(_ line: String) {
        let stamp = Self.timeFormatter.string(from: Date())
        activity.append("\(stamp)  \(line)")
        if activity.count > 200 { activity.removeFirst(activity.count - 200) }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
