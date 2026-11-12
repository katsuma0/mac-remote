import Combine
import Foundation
import Network

struct DiscoveredMac: Identifiable, Hashable {
    let name: String
    let endpoint: NWEndpoint
    var id: String { name }
}

enum ConnectionState: Equatable {
    case disconnected
    case connecting(String)
    case connected(String)
    case reconnecting(String)
    case failed(String)
}

/// Finds Macs running MacRemoteServer (Bonjour) and keeps a TCP connection to one of them.
/// All work happens on the main queue.
final class RemoteConnection: ObservableObject {
    @Published private(set) var discovered: [DiscoveredMac] = []
    @Published private(set) var state: ConnectionState = .disconnected
    @Published private(set) var browseProblem: String?
    @Published private(set) var macVolume: Double = 50

    private struct Target {
        let name: String
        let endpoint: NWEndpoint
        let pin: String
    }

    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var target: Target?
    private var authenticated = false
    private var hadSession = false          // were we fully connected at least once to `target`?
    private var userWantsConnection = false
    private var autoConnectSuppressed = false
    private var receiveBuffer = Data()
    private var retryWork: DispatchWorkItem?

    // Mouse movement is coalesced: while a packet is in flight, deltas pile up and are sent together.
    private var inFlight = 0
    private var pendingMove = (dx: 0.0, dy: 0.0)
    private var pendingScroll = (dx: 0.0, dy: 0.0)

    private let defaults = UserDefaults.standard

    init() {
        startBrowsing()
    }

    var isSessionActive: Bool {
        switch state {
        case .connected, .reconnecting: return true
        default: return false
        }
    }

    var macName: String {
        switch state {
        case .connected(let n), .reconnecting(let n), .connecting(let n): return n
        default: return ""
        }
    }

    // MARK: Saved PINs

    private var lastMacName: String? {
        get { defaults.string(forKey: "lastMacName") }
        set { defaults.set(newValue, forKey: "lastMacName") }
    }

    func savedPin(for name: String) -> String? {
        (defaults.dictionary(forKey: "pins") as? [String: String])?[name]
    }

    private func setSavedPin(_ pin: String?, for name: String) {
        var pins = (defaults.dictionary(forKey: "pins") as? [String: String]) ?? [:]
        pins[name] = pin
        defaults.set(pins, forKey: "pins")
    }

    func forgetAllPins() {
        defaults.removeObject(forKey: "pins")
        lastMacName = nil
    }

    // MARK: Discovery

    static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 8
        let params = NWParameters(tls: nil, tcp: tcp)
        params.includePeerToPeer = true   // direct Wi-Fi link (AWDL) when not on the same network
        return params
    }

    func startBrowsing() {
        browser?.cancel()
        let params = NWParameters()
        params.includePeerToPeer = true
        let newBrowser = NWBrowser(for: .bonjour(type: RemoteConstants.serviceType, domain: nil), using: params)
        newBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            self.discovered = results.compactMap { result in
                if case let .service(name, _, _, _) = result.endpoint {
                    return DiscoveredMac(name: name, endpoint: result.endpoint)
                }
                return nil
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            self.tryAutoConnect()
        }
        newBrowser.stateUpdateHandler = { [weak self, weak newBrowser] state in
            guard let self, let newBrowser, newBrowser === self.browser else { return }
            switch state {
            case .ready:
                self.browseProblem = nil
            case .waiting(let error), .failed(let error):
                self.browseProblem = "Can't search the local network (\(error.localizedDescription)). "
                    + "Check Settings → Privacy & Security → Local Network → Mac Remote is on."
                if case .failed = state {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.startBrowsing() }
                }
            default:
                break
            }
        }
        browser = newBrowser
        newBrowser.start(queue: .main)
    }

    private func tryAutoConnect() {
        guard !autoConnectSuppressed, target == nil, state == .disconnected,
              let name = lastMacName, let pin = savedPin(for: name),
              let mac = discovered.first(where: { $0.name == name }) else { return }
        connect(to: mac, pin: pin)
    }

    // MARK: Connecting

    func connect(to mac: DiscoveredMac, pin: String) {
        start(Target(name: mac.name, endpoint: mac.endpoint, pin: pin))
    }

    func connect(host: String, pin: String) {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        var hostPart = trimmed
        var port = RemoteConstants.defaultPort
        if let colon = trimmed.lastIndex(of: ":"), let p = UInt16(trimmed[trimmed.index(after: colon)...]) {
            hostPart = String(trimmed[..<colon])
            port = p
        }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        start(Target(name: trimmed, endpoint: .hostPort(host: NWEndpoint.Host(hostPart), port: nwPort), pin: pin))
    }

    private func start(_ newTarget: Target) {
        tearDownConnection()
        target = newTarget
        hadSession = false
        userWantsConnection = true
        autoConnectSuppressed = false
        state = .connecting(newTarget.name)
        openConnection()
    }

    func disconnect() {
        userWantsConnection = false
        autoConnectSuppressed = true
        hadSession = false
        target = nil
        tearDownConnection()
        state = .disconnected
    }

    /// Call when the app comes back to the foreground; iOS drops sockets while the app is in the background.
    func resume() {
        startBrowsing()
        guard userWantsConnection, target != nil else { return }
        if let connection, connection.state == .ready, authenticated {
            write(RemoteCommand(t: "ping"))
        } else {
            if hadSession, let t = target { state = .reconnecting(t.name) }
            openConnection()
        }
    }

    private func tearDownConnection() {
        retryWork?.cancel()
        retryWork = nil
        if let connection {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
        connection = nil
        authenticated = false
        inFlight = 0
        pendingMove = (0, 0)
        pendingScroll = (0, 0)
        receiveBuffer.removeAll()
    }

    private func openConnection() {
        guard let t = target else { return }
        tearDownConnection()
        let conn = NWConnection(to: t.endpoint, using: Self.parameters())
        connection = conn
        conn.stateUpdateHandler = { [weak self, weak conn] newState in
            guard let self, let conn, conn === self.connection else { return }
            switch newState {
            case .ready:
                self.writeRaw(RemoteCommand(t: "auth", pin: t.pin), on: conn)
                self.receive(on: conn)
            case .waiting(let error), .failed(let error):
                self.connectionDropped(reason: error.localizedDescription)
            default:
                break
            }
        }
        conn.start(queue: .main)
    }

    private func connectionDropped(reason: String) {
        tearDownConnection()
        guard userWantsConnection, let t = target else { return }
        if hadSession {
            // We were connected before (Mac slept, Wi-Fi blipped, app was backgrounded…) – keep retrying.
            state = .reconnecting(t.name)
            let work = DispatchWorkItem { [weak self] in self?.openConnection() }
            retryWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
        } else {
            userWantsConnection = false
            target = nil
            state = .failed("Couldn't connect to \(t.name). Is MacRemoteServer running? (\(reason))")
        }
    }

    // MARK: Receiving

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak conn] data, _, isComplete, error in
            guard let self, let conn, conn === self.connection else { return }
            if let data, !data.isEmpty {
                self.receiveBuffer.append(data)
                while let newline = self.receiveBuffer.firstIndex(of: 0x0A) {
                    let line = self.receiveBuffer.subdata(in: self.receiveBuffer.startIndex..<newline)
                    self.receiveBuffer.removeSubrange(self.receiveBuffer.startIndex...newline)
                    if let msg = try? JSONDecoder().decode(RemoteCommand.self, from: line) {
                        self.handle(msg)
                    }
                    if conn !== self.connection { return }   // handle() may have torn down the connection
                }
            }
            if isComplete || error != nil {
                self.connectionDropped(reason: error?.localizedDescription ?? "Connection closed")
            } else {
                self.receive(on: conn)
            }
        }
    }

    private func handle(_ msg: RemoteCommand) {
        guard let t = target else { return }
        switch msg.t {
        case "auth_ok":
            authenticated = true
            hadSession = true
            state = .connected(t.name)
            lastMacName = t.name
            setSavedPin(t.pin, for: t.name)
        case "auth_fail":
            setSavedPin(nil, for: t.name)
            userWantsConnection = false
            target = nil
            tearDownConnection()
            state = .failed(msg.s ?? "Wrong PIN")
        case "volume":
            if let v = msg.v { macVolume = v }
        default:
            break
        }
    }

    // MARK: Sending

    func move(dx: Double, dy: Double) {
        guard authenticated else { return }
        pendingMove.dx += dx
        pendingMove.dy += dy
        flushIfIdle()
    }

    func scroll(dx: Double, dy: Double) {
        guard authenticated else { return }
        pendingScroll.dx += dx
        pendingScroll.dy += dy
        flushIfIdle()
    }

    func click(right: Bool = false) { send(RemoteCommand(t: "click", b: right ? "right" : "left")) }
    func mouseDown(right: Bool = false) { send(RemoteCommand(t: "down", b: right ? "right" : "left")) }
    func mouseUp(right: Bool = false) { send(RemoteCommand(t: "up", b: right ? "right" : "left")) }
    func type(_ text: String) { send(RemoteCommand(t: "text", s: text)) }
    func key(_ name: String, _ modifiers: [String] = []) { send(RemoteCommand(t: "key", s: name, m: modifiers)) }
    func media(_ name: String) { send(RemoteCommand(t: "media", s: name)) }
    func system(_ action: String) { send(RemoteCommand(t: "system", s: action)) }
    func setVolume(_ value: Double) {
        macVolume = value
        send(RemoteCommand(t: "volume", v: value))
    }

    /// Sends a discrete command, preceded by any pending mouse movement so ordering is preserved.
    func send(_ cmd: RemoteCommand) {
        guard authenticated else { return }
        var data = takePendingMotion()
        data.append(encode(cmd))
        writeData(data)
    }

    private func flushIfIdle() {
        guard inFlight == 0 else { return }
        let data = takePendingMotion()
        if !data.isEmpty { writeData(data) }
    }

    private func takePendingMotion() -> Data {
        var data = Data()
        if pendingMove.dx != 0 || pendingMove.dy != 0 {
            data.append(encode(RemoteCommand(t: "move", dx: pendingMove.dx, dy: pendingMove.dy)))
            pendingMove = (0, 0)
        }
        if pendingScroll.dx != 0 || pendingScroll.dy != 0 {
            data.append(encode(RemoteCommand(t: "scroll", dx: pendingScroll.dx, dy: pendingScroll.dy)))
            pendingScroll = (0, 0)
        }
        return data
    }

    private func encode(_ cmd: RemoteCommand) -> Data {
        var data = (try? JSONEncoder().encode(cmd)) ?? Data()
        data.append(0x0A)
        return data
    }

    private func write(_ cmd: RemoteCommand) {
        writeData(encode(cmd))
    }

    private func writeRaw(_ cmd: RemoteCommand, on conn: NWConnection) {
        conn.send(content: encode(cmd), completion: .contentProcessed { _ in })
    }

    private func writeData(_ data: Data) {
        guard let conn = connection else { return }
        inFlight += 1
        conn.send(content: data, completion: .contentProcessed { [weak self, weak conn] error in
            guard let self, let conn, conn === self.connection else { return }
            self.inFlight -= 1
            if error == nil { self.flushIfIdle() }
        })
    }
}
