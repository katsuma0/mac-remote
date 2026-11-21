import Combine
import CryptoKit
import Foundation
import Network

struct DiscoveredMac: Identifiable, Hashable {
    let name: String
    let endpoint: NWEndpoint
    /// The Mac's id from its Bonjour TXT record (used to match a scanned pairing code).
    let macId: String?
    var id: String { macId ?? name }
    var isPaired: Bool { PhonePairings.isPaired(macId) }
}

struct MirrorScreen: Identifiable, Hashable {
    let name: String
    let connected: Bool
    var id: String { name }
}

enum ConnectionState: Equatable {
    case disconnected
    case connecting(String)
    /// The Mac doesn't know this iPhone yet: show the pairing screen.
    case needsPairing(String)
    case pairing(String)
    case connected(String)
    case reconnecting(String)
    case failed(String)
}

/// Finds Macs running Couchpad (Bonjour), pairs with them, and keeps an encrypted connection to one.
/// All work happens on the main queue.
final class RemoteConnection: ObservableObject {
    @Published private(set) var discovered: [DiscoveredMac] = []
    @Published private(set) var state: ConnectionState = .disconnected
    @Published private(set) var browseProblem: String?
    @Published private(set) var pairingError: String?
    @Published private(set) var capabilities: Set<String> = []

    @Published private(set) var macVolume: Double = 50
    @Published private(set) var macMuted = false
    @Published private(set) var macBrightness: Double = 50

    @Published private(set) var mirrorScreens: [MirrorScreen] = []
    @Published private(set) var mirrorLoading = false
    @Published private(set) var mirrorError: String?
    private var mirrorTimeout: DispatchWorkItem?

    private struct Target {
        let name: String
        let endpoint: NWEndpoint
    }

    /// Where the handshake is (see SecureSession.swift).
    private enum Phase {
        case idle
        case awaitingMacHello(PhoneHandshake)
        case awaitingPairingInput(PhoneHandshake)
        case awaitingPairResult(PhoneHandshake)
        case awaitingAuthOK
        case established
    }

    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var target: Target?
    private var phase = Phase.idle
    private var channel: SecureChannel?
    /// The id of the Mac on the other end, learned in the handshake.
    private var sessionMacId: String?
    private var hadSession = false          // were we fully connected at least once to `target`?
    private var userWantsConnection = false
    private var autoConnectSuppressed = false
    private var receiveBuffer = Data()
    private var retryWork: DispatchWorkItem?

    /// A pairing to send as soon as the Mac asks for it (from a scanned code or a typed code
    /// that needs a fresh connection).
    private var pendingPairing: (method: PairingMethod, secret: Data)?
    /// A scanned pairing code waiting for its Mac to show up on the network.
    private var pendingLink: PairingLink?
    private var pendingLinkTimeout: DispatchWorkItem?

    // Fast mouse channel: movement goes over UDP so one lost Wi-Fi packet never stalls the pointer.
    private var udp: NWConnection?
    private var udpChannel: SecureChannel?
    private var udpSessionId: Data?
    private var udpConfirmed = false
    private var udpHelloAttempts = 0

    // TCP fallback: while a packet is in flight, deltas pile up and are sent together.
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

    var isPairing: Bool {
        switch state {
        case .needsPairing, .pairing: return true
        default: return false
        }
    }

    var macName: String {
        switch state {
        case .connected(let n), .reconnecting(let n), .connecting(let n), .needsPairing(let n), .pairing(let n):
            return n
        default:
            return ""
        }
    }

    func supports(_ capability: String) -> Bool {
        capabilities.contains(capability)
    }

    private var lastMacId: String? {
        get { defaults.string(forKey: "lastMacId") }
        set { defaults.set(newValue, forKey: "lastMacId") }
    }

    // MARK: Discovery

    /// Peer-to-peer Wi-Fi (AWDL) allows connecting without a shared network, but makes the radio
    /// hop channels which adds lag, so it's off unless turned on in the app.
    static var peerToPeer: Bool { UserDefaults.standard.bool(forKey: "peerToPeer") }

    static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 8
        let params = NWParameters(tls: nil, tcp: tcp)
        params.includePeerToPeer = peerToPeer
        return params
    }

    func startBrowsing() {
        browser?.cancel()
        let params = NWParameters()
        params.includePeerToPeer = Self.peerToPeer
        let newBrowser = NWBrowser(for: .bonjourWithTXTRecord(type: RemoteConstants.serviceType, domain: nil),
                                   using: params)
        newBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            self.discovered = results.compactMap { result in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                var macId: String?
                if case let .bonjour(record) = result.metadata {
                    macId = record["id"]
                }
                return DiscoveredMac(name: name, endpoint: result.endpoint, macId: macId)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            self.connectToPendingLinkIfFound()
            self.tryAutoConnect()
        }
        newBrowser.stateUpdateHandler = { [weak self, weak newBrowser] state in
            guard let self, let newBrowser, newBrowser === self.browser else { return }
            switch state {
            case .ready:
                self.browseProblem = nil
            case .waiting(let error), .failed(let error):
                self.browseProblem = "Can't search the local network (\(error.localizedDescription)). "
                    + "Check Settings → Privacy & Security → Local Network → Couchpad is on."
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
        guard !autoConnectSuppressed, target == nil, state == .disconnected, pendingLink == nil,
              let macId = lastMacId, PhonePairings.isPaired(macId),
              let mac = discovered.first(where: { $0.macId == macId }) else { return }
        connect(to: mac)
    }

    // MARK: Connecting

    func connect(to mac: DiscoveredMac) {
        start(Target(name: mac.name, endpoint: mac.endpoint))
    }

    func connect(host: String) {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        var hostPart = trimmed
        var port = RemoteConstants.defaultPort
        if let colon = trimmed.lastIndex(of: ":"), let p = UInt16(trimmed[trimmed.index(after: colon)...]) {
            hostPart = String(trimmed[..<colon])
            port = p
        }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        start(Target(name: trimmed, endpoint: .hostPort(host: NWEndpoint.Host(hostPart), port: nwPort)))
    }

    private func start(_ newTarget: Target, keepPendingPairing: Bool = false) {
        tearDownConnection()
        target = newTarget
        hadSession = false
        userWantsConnection = true
        autoConnectSuppressed = false
        if !keepPendingPairing { pendingPairing = nil }
        pairingError = nil
        state = .connecting(newTarget.name)
        openConnection()
    }

    func disconnect() {
        userWantsConnection = false
        autoConnectSuppressed = true
        hadSession = false
        target = nil
        pendingPairing = nil
        pendingLink = nil
        pairingError = nil
        tearDownConnection()
        state = .disconnected
    }

    /// Call when the app comes back to the foreground; iOS drops sockets while the app is in the background.
    func resume() {
        startBrowsing()
        guard userWantsConnection, target != nil, !isPairing else { return }
        if let connection, connection.state == .ready, case .established = phase {
            send(RemoteCommand(t: "ping"))
        } else {
            if hadSession, let t = target { state = .reconnecting(t.name) }
            openConnection()
        }
    }

    func forget(_ mac: PhonePairings.PairedMac) {
        PhonePairings.remove(mac.id)
        if lastMacId == mac.id { lastMacId = nil }
        objectWillChange.send()
    }

    // MARK: Pairing

    /// From a scanned QR code (camera or in-app scanner): find that Mac and pair.
    func pair(with link: PairingLink) {
        pairingError = nil
        // Already talking to that Mac and waiting for a code? Use this connection.
        if case let .awaitingPairingInput(handshake) = phase, handshake.macId == link.macId {
            sendPair(handshake, method: .qr, secret: link.secret)
            return
        }
        if let mac = discovered.first(where: { $0.macId == link.macId }) {
            pendingPairing = (.qr, link.secret)
            start(Target(name: mac.name, endpoint: mac.endpoint), keepPendingPairing: true)
            return
        }
        // Not on the network (yet): wait a few seconds for Bonjour to find it.
        tearDownConnection()
        pendingLink = link
        state = .connecting(link.macName)
        pendingLinkTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.pendingLink == link else { return }
            self.pendingLink = nil
            self.state = .failed("Couldn't find “\(link.macName)”. Make sure Couchpad is turned on on the Mac and both devices are on the same Wi-Fi.")
        }
        pendingLinkTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: timeout)
    }

    private func connectToPendingLinkIfFound() {
        guard let link = pendingLink, let mac = discovered.first(where: { $0.macId == link.macId }) else { return }
        pendingLink = nil
        pendingLinkTimeout?.cancel()
        pendingPairing = (.qr, link.secret)
        start(Target(name: mac.name, endpoint: mac.endpoint), keepPendingPairing: true)
    }

    /// The 6-digit code shown on the Mac.
    func pair(code: String) {
        let digits = code.filter(\.isNumber)
        guard digits.count == 6 else {
            pairingError = "Enter the 6-digit code shown on your Mac."
            return
        }
        pairingError = nil
        let secret = PairingSecret.fromCode(digits)
        if case let .awaitingPairingInput(handshake) = phase, connection?.state == .ready {
            sendPair(handshake, method: .code, secret: secret)
        } else if let target {
            // The Mac closed the connection (e.g. after a wrong code): reconnect and pair.
            pendingPairing = (.code, secret)
            start(target, keepPendingPairing: true)
            state = .pairing(target.name)
        }
    }

    func cancelPairing() {
        disconnect()
    }

    private func sendPair(_ handshake: PhoneHandshake, method: PairingMethod, secret: Data) {
        do {
            let request = try handshake.pairRequest(method: method, secret: secret)
            phase = .awaitingPairResult(handshake)
            state = .pairing(handshake.macName ?? target?.name ?? "Mac")
            sendPlain(request)
        } catch {
            pairingError = "Couldn't start pairing. Try again."
        }
    }

    // MARK: Connection lifecycle

    private func tearDownConnection() {
        retryWork?.cancel()
        retryWork = nil
        if let connection {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
        connection = nil
        udp?.stateUpdateHandler = nil
        udp?.cancel()
        udp = nil
        udpChannel = nil
        udpSessionId = nil
        udpConfirmed = false
        channel = nil
        phase = .idle
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
                self.sessionMacId = nil
                let handshake = PhoneHandshake(phoneId: PhonePairings.phoneId, phoneName: PhonePairings.phoneName)
                self.phase = .awaitingMacHello(handshake)
                self.sendPlain(handshake.hello())
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
        let wasPairing = isPairing
        tearDownConnection()
        guard userWantsConnection, let t = target else { return }
        if wasPairing {
            // Stay on the pairing screen; the next attempt reconnects.
            if case .pairing = state {
                state = .needsPairing(t.name)
                if pairingError == nil { pairingError = "Lost the connection to the Mac. Try again." }
            }
            return
        }
        if hadSession {
            // We were connected before (Mac slept, Wi-Fi blipped, app was backgrounded…) – keep retrying.
            state = .reconnecting(t.name)
            let work = DispatchWorkItem { [weak self] in self?.openConnection() }
            retryWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
        } else {
            userWantsConnection = false
            target = nil
            state = .failed("Couldn't connect to \(t.name). Is Couchpad turned on on the Mac? (\(reason))")
        }
    }

    /// Stops trying and shows a message.
    private func fail(_ message: String) {
        userWantsConnection = false
        target = nil
        pendingPairing = nil
        tearDownConnection()
        state = .failed(message)
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
                    if !line.isEmpty { self.handleLine(line) }
                    if conn !== self.connection { return }   // the line may have torn down the connection
                }
                if self.receiveBuffer.count > RemoteConstants.maxLineLength {
                    self.connectionDropped(reason: "Too much data")
                    return
                }
            }
            if isComplete || error != nil {
                self.connectionDropped(reason: error?.localizedDescription ?? "Connection closed")
            } else {
                self.receive(on: conn)
            }
        }
    }

    private func handleLine(_ line: Data) {
        switch phase {
        case .established, .awaitingAuthOK:
            guard let channel, let sealed = Data(base64Encoded: line),
                  let plaintext = try? channel.open(sealed),
                  let message = try? JSONDecoder().decode(RemoteCommand.self, from: plaintext) else {
                connectionDropped(reason: "A message couldn't be decrypted")
                return
            }
            handle(message)
        default:
            guard let message = try? JSONDecoder().decode(HandshakeMessage.self, from: line) else {
                fail("This Mac is running an older version of Couchpad. Update it and try again.")
                return
            }
            handleHandshake(message)
        }
    }

    private func handleHandshake(_ message: HandshakeMessage) {
        switch (message.t, phase) {
        case ("hello_mac", .awaitingMacHello(let handshake)):
            do {
                let outcome = try handshake.receive(macHello: message, longTermKey: { PhonePairings.key(for: $0) })
                sessionMacId = handshake.macId
                switch outcome {
                case let .authenticated(reply, keys):
                    sendPlain(reply)
                    establishChannels(keys)
                case .needsPairing:
                    let name = handshake.macName ?? target?.name ?? "Mac"
                    if let pending = pendingPairing {
                        pendingPairing = nil
                        sendPair(handshake, method: pending.method, secret: pending.secret)
                    } else {
                        if PhonePairings.isPaired(handshake.macId) {
                            pairingError = "“\(name)” doesn't recognize this iPhone anymore. Pair again."
                        }
                        phase = .awaitingPairingInput(handshake)
                        state = .needsPairing(name)
                    }
                }
            } catch HandshakeError.notAuthentic {
                fail("Couldn't verify this Mac's identity, so Couchpad didn't connect. If you reinstalled Couchpad on the Mac, forget it in Settings and pair again.")
            } catch {
                fail("Couldn't connect securely. Update Couchpad on both devices and try again.")
            }

        case ("paired", .awaitingPairResult(let handshake)):
            do {
                let (longTermKey, keys) = try handshake.receive(paired: message)
                if let macId = handshake.macId {
                    PhonePairings.save(macId: macId, macName: handshake.macName ?? target?.name ?? "Mac", key: longTermKey)
                    lastMacId = macId
                }
                pairingError = nil
                establishChannels(keys)
            } catch {
                fail("Pairing failed: the Mac's reply couldn't be verified. Try again.")
            }

        case ("pair_failed", _):
            // The Mac closes the connection; the next attempt reconnects.
            pairingError = message.e ?? "That code didn't match. Try again."
            if let t = target { state = .needsPairing(t.name) }
            phase = .idle

        case ("error", _):
            let text = message.e ?? "The Mac refused the connection."
            if isPairing {
                pairingError = text
                if let t = target { state = .needsPairing(t.name) }
                phase = .idle
            } else {
                fail(text)
            }

        default:
            fail("Unexpected reply from the Mac. Update Couchpad on both devices.")
        }
    }

    private func establishChannels(_ keys: SessionKeys) {
        channel = SecureChannel(sendKey: keys.tcpSend, receiveKey: keys.tcpReceive, ordering: .strict)
        udpChannel = SecureChannel(sendKey: keys.udpSend, receiveKey: keys.udpReceive, ordering: .increasing)
        phase = .awaitingAuthOK
    }

    private func handle(_ message: RemoteCommand) {
        guard let t = target else { return }
        switch message.t {
        case "auth_ok":
            phase = .established
            hadSession = true
            state = .connected(message.s ?? t.name)
            capabilities = Set(message.m ?? [])
            if let sessionMacId { lastMacId = sessionMacId }
            if let hex = message.k, let port = message.p, let sessionId = Data(hex: hex), sessionId.count == 8 {
                openUDP(sessionId: sessionId, port: port)
            }
        case "volume":
            if let v = message.v { macVolume = v }
            if let s = message.s { macMuted = (s == "muted") }
        case "brightness":
            if let v = message.v { macBrightness = v }
        case "mirroring":
            mirrorTimeout?.cancel()
            mirrorLoading = false
            mirrorError = message.e
            if message.e == nil {
                mirrorScreens = (message.m ?? []).map { MirrorScreen(name: $0, connected: $0 == message.s) }
            }
        default:
            break
        }
    }

    // MARK: Sending

    func move(dx: Double, dy: Double) {
        guard isEstablished else { return }
        if udpConfirmed {
            sendDatagram(RemoteCommand(t: "move", dx: dx, dy: dy))
            return
        }
        pendingMove.dx += dx
        pendingMove.dy += dy
        flushIfIdle()
    }

    func scroll(dx: Double, dy: Double) {
        guard isEstablished else { return }
        if udpConfirmed {
            sendDatagram(RemoteCommand(t: "scroll", dx: dx, dy: dy))
            return
        }
        pendingScroll.dx += dx
        pendingScroll.dy += dy
        flushIfIdle()
    }

    func click(right: Bool = false) { send(RemoteCommand(t: "click", b: right ? "right" : "left")) }
    func doubleClick() { send(RemoteCommand(t: "dblclick")) }
    func mouseDown(right: Bool = false) { send(RemoteCommand(t: "down", b: right ? "right" : "left")) }
    func mouseUp(right: Bool = false) { send(RemoteCommand(t: "up", b: right ? "right" : "left")) }
    func type(_ text: String) { send(RemoteCommand(t: "text", s: text)) }
    func key(_ name: String, _ modifiers: [String] = []) { send(RemoteCommand(t: "key", s: name, m: modifiers)) }
    func media(_ name: String) { send(RemoteCommand(t: "media", s: name)) }
    func system(_ action: String) { send(RemoteCommand(t: "system", s: action)) }

    func setVolume(_ value: Double) {
        macVolume = value
        macMuted = false
        send(RemoteCommand(t: "volume", v: value))
    }

    func toggleMute() {
        macMuted.toggle()   // optimistic; the Mac reports the real state right after
        media("mute")
    }

    func setBrightness(_ value: Double) {
        macBrightness = value
        send(RemoteCommand(t: "brightness", v: value))
    }

    // MARK: Screen mirroring (AirPlay, through the Mac's menu bar)

    func mirrorRefresh() { mirror("list") }
    func mirrorConnect(_ name: String) { mirror("connect", name: name) }
    func mirrorStop() { mirror("stop") }
    func mirrorOpenOnMac() { send(RemoteCommand(t: "mirror", s: "open")) }

    private func mirror(_ action: String, name: String? = nil) {
        guard isEstablished else { return }
        mirrorLoading = true
        mirrorError = nil
        send(RemoteCommand(t: "mirror", s: action, m: name.map { [$0] }))
        mirrorTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.mirrorLoading else { return }
            self.mirrorLoading = false
            self.mirrorError = "Your Mac didn't answer. Make sure Couchpad on the Mac is up to date."
        }
        mirrorTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)
    }

    private var isEstablished: Bool {
        if case .established = phase { return true }
        return false
    }

    /// Sends an encrypted command, preceded by any pending mouse movement so ordering is preserved.
    func send(_ command: RemoteCommand) {
        guard isEstablished else { return }
        var data = takePendingMotion()
        if let line = sealedLine(command) { data.append(line) }
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
            if let line = sealedLine(RemoteCommand(t: "move", dx: pendingMove.dx, dy: pendingMove.dy)) { data.append(line) }
            pendingMove = (0, 0)
        }
        if pendingScroll.dx != 0 || pendingScroll.dy != 0 {
            if let line = sealedLine(RemoteCommand(t: "scroll", dx: pendingScroll.dx, dy: pendingScroll.dy)) { data.append(line) }
            pendingScroll = (0, 0)
        }
        return data
    }

    private func sealedLine(_ command: RemoteCommand) -> Data? {
        guard let channel, let json = try? JSONEncoder().encode(command),
              let sealed = try? channel.seal(json) else { return nil }
        var line = Data(sealed.base64EncodedString().utf8)
        line.append(0x0A)
        return line
    }

    private func sendPlain(_ message: HandshakeMessage) {
        guard let connection, var data = try? JSONEncoder().encode(message) else { return }
        data.append(0x0A)
        connection.send(content: data, completion: .contentProcessed { _ in })
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

    // MARK: UDP fast channel

    private func openUDP(sessionId: Data, port: Int) {
        // Send UDP to the exact address the TCP connection resolved to (Bonjour names resolve to an IP).
        guard let path = connection?.currentPath,
              case let .hostPort(host, _)? = path.remoteEndpoint,
              let udpPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return }
        let params = NWParameters.udp
        params.includePeerToPeer = Self.peerToPeer
        let conn = NWConnection(host: host, port: udpPort, using: params)
        udp = conn
        udpSessionId = sessionId
        udpConfirmed = false
        udpHelloAttempts = 0
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn, conn === self.udp else { return }
            switch state {
            case .ready:
                self.receiveUDP(on: conn)
                self.sendHello()
            case .failed, .cancelled:
                self.udpConfirmed = false   // fall back to TCP
            default:
                break
            }
        }
        conn.start(queue: .main)
    }

    /// Confirm datagrams actually reach the Mac (and come back) before switching movement to UDP.
    private func sendHello() {
        guard udp != nil, !udpConfirmed, udpHelloAttempts < 10 else { return }
        udpHelloAttempts += 1
        sendDatagram(RemoteCommand(t: "hello"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.sendHello() }
    }

    private func receiveUDP(on conn: NWConnection) {
        conn.receiveMessage { [weak self, weak conn] data, _, _, error in
            guard let self, let conn, conn === self.udp else { return }
            if let data, let plaintext = try? self.udpChannel?.open(data),
               let message = try? JSONDecoder().decode(RemoteCommand.self, from: plaintext),
               message.t == "hello_ok", !self.udpConfirmed {
                // Anything still queued for TCP goes first so nothing is reordered.
                self.flushIfIdle()
                self.udpConfirmed = true
            }
            if error == nil { self.receiveUDP(on: conn) }
        }
    }

    private func sendDatagram(_ command: RemoteCommand) {
        guard let udp, let udpChannel, let udpSessionId,
              let json = try? JSONEncoder().encode(command),
              let sealed = try? udpChannel.seal(json) else { return }
        udp.send(content: udpSessionId + sealed, completion: .idempotent)
    }
}

private extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
