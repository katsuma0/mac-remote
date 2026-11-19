import AppKit
import ApplicationServices
import Combine
import ServiceManagement

/// State behind the Mac app's window and menu bar icon. Everything runs on the main queue.
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var isRunning = false
    @Published private(set) var isListening = false
    @Published private(set) var connectedPhones = 0
    @Published private(set) var pin = PinStore.load()
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()
    @Published private(set) var activity: [String] = []

    @Published var peerToPeer = UserDefaults.standard.bool(forKey: "peerToPeer") {
        didSet {
            UserDefaults.standard.set(peerToPeer, forKey: "peerToPeer")
            if isRunning { restart() }
        }
    }

    @Published var startAutomatically = UserDefaults.standard.bool(forKey: "startAutomatically") {
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
        // Re-check Accessibility every couple of seconds so the window updates as soon as it's granted.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            let granted = AXIsProcessTrusted()
            if granted != self.accessibilityGranted { self.accessibilityGranted = granted }
        }
    }

    /// Called once the app has finished launching.
    func appDidLaunch() {
        if startAutomatically { start() }
    }

    // MARK: Start / stop

    var statusText: String {
        if !isRunning { return "Stopped – your iPhone can't see this Mac" }
        if connectedPhones > 0 {
            return connectedPhones == 1 ? "iPhone connected" : "\(connectedPhones) iPhones connected"
        }
        return isListening ? "Ready – open Mac Remote on your iPhone" : "Starting…"
    }

    func toggle() {
        isRunning ? stop() : start()
    }

    func start() {
        guard server == nil else { return }
        if !AXIsProcessTrusted() { requestAccessibility() }

        let newServer = RemoteServer(pin: pin, peerToPeer: peerToPeer)
        newServer.onStatusChange = { [weak self, weak newServer] in
            guard let self, let newServer, newServer === self.server else { return }
            self.isListening = newServer.isListening
            self.connectedPhones = newServer.connectedPhones
        }
        server = newServer
        newServer.start()
        newServer.startUDP()
        isRunning = true

        // Keep macOS from napping the app while it's in the background, which would make the mouse lag.
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Receiving mouse and keyboard input from iPhone")

        Log.write("▶️ Started – iPhones on your Wi-Fi can now find “\(computerName)”.")
    }

    func stop() {
        guard let server else { return }
        self.server = nil
        server.stop()
        isRunning = false
        isListening = false
        connectedPhones = 0
        if let activityToken {
            ProcessInfo.processInfo.endActivity(activityToken)
            self.activityToken = nil
        }
        Log.write("⏹ Stopped – this Mac is hidden from iPhones.")
    }

    private func restart() {
        stop()
        start()
    }

    // MARK: PIN

    func newPin() {
        pin = PinStore.reset()
        Log.write("🔑 New PIN: \(pin). Phones will ask for it next time they connect.")
        if isRunning { restart() }
    }

    func copyPin() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pin, forType: .string)
    }

    // MARK: Permissions & login item

    func requestAccessibility() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
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
