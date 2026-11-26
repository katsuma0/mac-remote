import CryptoKit
import Foundation
import Network
import SystemConfiguration
#if canImport(RemoteCore)
import RemoteCore
#endif

/// Listens for the iPhone app on the local network and advertises itself with Bonjour.
///
/// Only paired iPhones can do anything: every connection starts with the handshake in
/// SecureSession.swift (pairing while "Pair iPhone" is open, otherwise proof of the pairing key),
/// and everything after it is encrypted. Everything runs on the main queue.
final class RemoteServer {
    let input = InputController()
    let pairings: PairingStore

    static var localComputerName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "Mac"
    }
    let computerName: String = RemoteServer.localComputerName

    /// Peer-to-peer Wi-Fi (AWDL, what AirDrop uses) lets the phone connect with no shared network,
    /// but it makes the Wi-Fi radio hop channels and adds latency spikes, so it is opt-in.
    let peerToPeer: Bool

    /// Called on the main queue when listening starts/stops, a phone connects/disconnects, or pairing changes.
    var onStatusChange: (() -> Void)?
    /// Called on the main queue with the iPhone's name when pairing succeeds.
    var onPaired: ((String) -> Void)?
    /// Called on the main queue when an unpaired iPhone tries to connect (its name).
    var onPairingRequested: ((String) -> Void)?

    private(set) var isListening = false
    private(set) var pairingWindow: PairingWindow?

    // MARK: Security options (set by the app)

    /// Ignore pointer, keyboard, apps and clipboard commands while the Mac's screen is locked, so a
    /// phone can't type at the login window. Media keys and volume still work.
    var ignoreWhileLocked = true
    /// Allow pairing with the 6-digit code. With it off, only the QR code (256-bit secret) pairs.
    var allowCodePairing = true
    /// If set, every connection of a paired iPhone must be approved on the Mac. Called with the
    /// iPhone's name; call the completion with true to allow it.
    var approvalHandler: ((String, @escaping (Bool) -> Void) -> Void)?

    private var stopped = false
    private var listener: NWListener?
    private var udpListener: NWListener?
    private var udpFlows: [ObjectIdentifier: NWConnection] = [:]
    private var sessions: [ObjectIdentifier: ClientSession] = [:]

    // Brute-force protection: after too many failed handshakes, refuse new ones for a minute.
    private var recentFailures: [Date] = []
    private var lockedUntil = Date.distantPast

    init(peerToPeer: Bool, pairings: PairingStore = .shared) {
        self.peerToPeer = peerToPeer
        self.pairings = pairings
        _ = ScreenLockMonitor.shared   // start watching for screen lock right away
    }

    var connectedPhones: [String] {
        sessions.values.filter(\.isEstablished).map(\.phoneName)
    }

    var connectedPhoneIds: Set<String> {
        Set(sessions.values.filter(\.isEstablished).compactMap(\.phoneId))
    }

    var capabilities: [String] {
        var list = [Capability.screenMirroring, Capability.apps, Capability.clipboard]
        if Brightness.isSupported { list.append(Capability.brightnessSlider) }
        if SystemActions.canSleepDisplay { list.append(Capability.sleepDisplay) }
        return list
    }

    // MARK: Network parameters

    func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        let params = NWParameters(tls: nil, tcp: tcp)
        params.includePeerToPeer = peerToPeer
        params.allowLocalEndpointReuse = true
        return params
    }

    func udpParameters() -> NWParameters {
        let params = NWParameters.udp
        params.includePeerToPeer = peerToPeer
        params.allowLocalEndpointReuse = true
        return params
    }

    var udpPort: UInt16? { udpListener?.port?.rawValue }

    /// Bonjour TXT record with this Mac's id, so a scanned pairing QR code finds the right Mac.
    private var txtRecord: Data {
        var data = Data()
        for entry in ["v=\(couchpadProtocolVersion)", "id=\(pairings.macId)"] {
            let bytes = Array(entry.utf8)
            data.append(UInt8(bytes.count))
            data.append(contentsOf: bytes)
        }
        return data
    }

    // MARK: Start / stop

    func start(port: UInt16? = RemoteConstants.defaultPort) {
        guard !stopped else { return }
        let newListener: NWListener
        do {
            if let port, let nwPort = NWEndpoint.Port(rawValue: port) {
                newListener = try NWListener(using: parameters(), on: nwPort)
            } else {
                newListener = try NWListener(using: parameters())
            }
        } catch {
            Log.write("❌ Could not create listener: \(error)")
            retry(port: nil)
            return
        }

        newListener.service = NWListener.Service(name: computerName, type: RemoteConstants.serviceType,
                                                 domain: nil, txtRecord: txtRecord)

        newListener.stateUpdateHandler = { [weak self, weak newListener] state in
            guard let self, let newListener, newListener === self.listener else { return }
            switch state {
            case .ready:
                Log.write("✅ Listening on port \(newListener.port?.rawValue ?? 0)")
                self.isListening = true
                self.onStatusChange?()
            case .waiting(let error):
                Log.write("⏳ Waiting for network: \(error)")
            case .failed(let error):
                Log.write("❌ Listener failed: \(error)")
                self.isListening = false
                self.onStatusChange?()
                newListener.cancel()
                if case .posix(let code) = error, code == .EADDRINUSE {
                    Log.write("   Port \(port ?? 0) is busy, using a random port instead.")
                    self.retry(port: nil)
                } else {
                    self.retry(port: port)
                }
            default:
                break
            }
        }
        newListener.serviceRegistrationUpdateHandler = { change in
            if case .add(let endpoint) = change {
                Log.write("📡 Advertising on Bonjour as \(endpoint)")
            }
        }
        newListener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener = newListener
        newListener.start(queue: .main)
    }

    private func retry(port: UInt16?) {
        listener = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.start(port: port)
        }
    }

    /// Stops listening and disconnects every phone. A stopped server can't be restarted; make a new one.
    func stop() {
        stopped = true
        listener?.cancel()
        listener = nil
        udpListener?.cancel()
        udpListener = nil
        for session in Array(sessions.values) {
            session.close(reason: "server stopped")
        }
        udpFlows.values.forEach { $0.cancel() }
        udpFlows.removeAll()
        input.releaseAll()
        pairingWindow = nil
        isListening = false
        onStatusChange?()
    }

    // MARK: Pairing

    /// Opens pairing for a few minutes. Returns the window (QR secret + code) to show on screen.
    @discardableResult
    func openPairing() -> PairingWindow {
        let window = PairingWindow()
        pairingWindow = window
        Log.write("🔗 Pairing is open for \(Int(PairingWindow.duration / 60)) minutes.")
        onStatusChange?()
        DispatchQueue.main.asyncAfter(deadline: .now() + PairingWindow.duration + 0.5) { [weak self, weak window] in
            guard let self, let window, window === self.pairingWindow else { return }
            self.pairingWindow = nil
            Log.write("🔗 Pairing closed (timed out).")
            self.onStatusChange?()
        }
        return window
    }

    func closePairing() {
        guard pairingWindow != nil else { return }
        pairingWindow = nil
        onStatusChange?()
    }

    /// Unpairs an iPhone and disconnects it right away.
    func unpair(_ phoneId: String) {
        pairings.remove(phoneId)
        for session in Array(sessions.values) where session.phoneId == phoneId {
            session.close(reason: "unpaired on this Mac")
        }
    }

    fileprivate func pairingFailedAttempt() {
        guard let window = pairingWindow else { return }
        window.recordFailure()
        recordFailure()
        if !window.isOpen {
            pairingWindow = nil
            Log.write("🔒 Too many wrong pairing codes – pairing closed. Click “Pair iPhone” to try again.")
            onStatusChange?()
        }
    }

    fileprivate func pairingSucceeded(phoneName: String) {
        pairingWindow = nil
        Log.write("✅ Paired with “\(phoneName)”.")
        onPaired?(phoneName)
        onStatusChange?()
    }

    // MARK: Brute-force protection

    fileprivate var acceptsHandshakes: Bool { Date() >= lockedUntil }

    fileprivate func recordFailure() {
        let now = Date()
        recentFailures = recentFailures.filter { now.timeIntervalSince($0) < 60 } + [now]
        if recentFailures.count >= 10 {
            lockedUntil = now.addingTimeInterval(60)
            recentFailures.removeAll()
            Log.write("🔒 Too many failed connection attempts – refusing new connections for a minute.")
        }
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        let session = ClientSession(connection: connection, server: self)
        sessions[ObjectIdentifier(session)] = session
        session.start()
    }

    fileprivate func remove(_ session: ClientSession) {
        sessions[ObjectIdentifier(session)] = nil
        if !sessions.values.contains(where: \.isEstablished) {
            input.releaseAll()
            udpFlows.values.forEach { $0.cancel() }
            udpFlows.removeAll()
        }
        onStatusChange?()
    }

    fileprivate func sessionEstablished(_ session: ClientSession) {
        onStatusChange?()
    }

    // MARK: UDP (mouse movement)

    /// Mouse movement uses UDP: a lost packet is simply skipped instead of stalling everything
    /// behind it until TCP retransmits it. Datagrams are encrypted like everything else.
    func startUDP(port: UInt16? = RemoteConstants.defaultPort) {
        guard !stopped else { return }
        let newListener: NWListener
        do {
            if let port, let nwPort = NWEndpoint.Port(rawValue: port) {
                newListener = try NWListener(using: udpParameters(), on: nwPort)
            } else {
                newListener = try NWListener(using: udpParameters())
            }
        } catch {
            Log.write("⚠️  UDP unavailable (\(error)); mouse movement will use TCP.")
            return
        }
        newListener.stateUpdateHandler = { [weak self, weak newListener] state in
            guard let self, let newListener, newListener === self.udpListener else { return }
            switch state {
            case .ready:
                Log.write("✅ Fast mouse channel (UDP) on port \(newListener.port?.rawValue ?? 0)")
            case .failed(let error):
                newListener.cancel()
                self.udpListener = nil
                if case .posix(let code) = error, code == .EADDRINUSE, port != nil {
                    self.startUDP(port: nil)
                } else {
                    Log.write("⚠️  UDP listener failed (\(error)); retrying.")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                        guard let self, !self.stopped else { return }
                        self.startUDP(port: port)
                    }
                }
            default:
                break
            }
        }
        newListener.newConnectionHandler = { [weak self] flow in
            guard let self, self.sessions.values.contains(where: \.isEstablished) else {
                flow.cancel()   // nobody is connected: ignore stray datagrams
                return
            }
            self.udpFlows[ObjectIdentifier(flow)] = flow
            flow.stateUpdateHandler = { [weak self, weak flow] state in
                guard let flow else { return }
                switch state {
                case .failed, .cancelled:
                    self?.udpFlows[ObjectIdentifier(flow)] = nil
                default:
                    break
                }
            }
            flow.start(queue: .main)
            self.receiveUDP(on: flow)
        }
        udpListener = newListener
        newListener.start(queue: .main)
    }

    private func receiveUDP(on flow: NWConnection) {
        flow.receiveMessage { [weak self, weak flow] data, _, _, error in
            guard let self, let flow else { return }
            if let data, !data.isEmpty { self.handleDatagram(data, from: flow) }
            if error == nil {
                self.receiveUDP(on: flow)
            } else {
                flow.cancel()
            }
        }
    }

    /// Datagram = 8-byte session id + sealed command.
    private func handleDatagram(_ data: Data, from flow: NWConnection) {
        guard data.count > 8 else { return }
        let sessionId = Data(data.prefix(8))
        guard let session = sessions.values.first(where: { $0.isEstablished && $0.udpSessionId == sessionId }),
              let channel = session.udpChannel,
              let plaintext = try? channel.open(Data(data.dropFirst(8))),
              let cmd = try? JSONDecoder().decode(RemoteCommand.self, from: plaintext) else { return }

        switch cmd.t {
        case "hello":
            // Lets the phone confirm UDP gets through (firewalls) before relying on it.
            if let reply = try? channel.seal(JSONEncoder().encode(RemoteCommand(t: "hello_ok"))) {
                flow.send(content: reply, completion: .idempotent)
            }
        case "move", "scroll":
            perform(cmd, from: session)
        default:
            break
        }
    }

    // MARK: Commands

    /// Commands that keep working while the Mac is locked (they can't type or click anything).
    private static let allowedWhileLocked: Set<String> = ["media", "volume", "brightness", "ping", "system"]

    fileprivate func perform(_ cmd: RemoteCommand, from session: ClientSession) {
        if ignoreWhileLocked, ScreenLockMonitor.shared.isLocked, !Self.allowedWhileLocked.contains(cmd.t) {
            if cmd.t != "move" && cmd.t != "scroll" {
                session.send(RemoteCommand(t: "locked", e: "Your Mac is locked. Unlock it on the Mac to use the trackpad and keyboard."))
            }
            return
        }
        switch cmd.t {
        case "move":
            input.move(dx: cmd.dx ?? 0, dy: cmd.dy ?? 0)
        case "scroll":
            input.scroll(dx: cmd.dx ?? 0, dy: cmd.dy ?? 0)
        case "click":
            input.click(right: cmd.b == "right")
        case "dblclick":
            input.doubleClick()
        case "down":
            input.mouseDown(right: cmd.b == "right")
        case "up":
            input.mouseUp(right: cmd.b == "right")
        case "text":
            input.type(cmd.s ?? "")
        case "key":
            input.key(cmd.s ?? "", modifiers: cmd.m ?? [])
        case "media":
            let name = cmd.s ?? ""
            input.media(name)
            if ["brightup", "brightdown"].contains(name) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.sendBrightness(to: session)
                }
            }
            if ["volup", "voldown", "mute"].contains(name) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.sendVolume(to: session)
                }
            }
        case "volume":
            SystemVolume.setVolume(Int((cmd.v ?? 0).rounded()))
        case "brightness":
            Brightness.set((cmd.v ?? 0) / 100)
        case "mirror":
            let action = Mirroring.Action(rawValue: cmd.s ?? "list") ?? .list
            Mirroring.perform(action, name: cmd.m?.first) { result in
                guard action != .open else { return }
                switch result {
                case .success(let screens):
                    session.send(RemoteCommand(t: "mirroring",
                                               s: screens.first(where: { $0.connected })?.name,
                                               m: screens.map(\.name)))
                case .failure(let error):
                    Log.write("🖥  Screen Mirroring: \(error.message)")
                    session.send(RemoteCommand(t: "mirroring", e: error.message))
                }
            }
        case "system":
            if cmd.s == "sleepdisplay" { SystemActions.sleepDisplay() }
        case "apps":
            session.send(RemoteCommand(t: "apps", apps: MacApps.list()))
        case "app_open":
            if let id = cmd.s { MacApps.open(id) }
            refreshApps(for: session)
        case "app_quit":
            if let id = cmd.s { MacApps.quit(id) }
            refreshApps(for: session)
        case "clip_set":
            MacClipboard.set(cmd.s ?? "")
            Log.write("📋 Clipboard received from “\(session.phoneName)”.")
        case "clip_get":
            session.send(RemoteCommand(t: "clipboard", s: MacClipboard.text))
        case "ping":
            session.send(RemoteCommand(t: "pong"))
        default:
            Log.write("Unknown command: \(cmd.t)")
        }
    }

    private func refreshApps(for session: ClientSession) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak session] in
            session?.send(RemoteCommand(t: "apps", apps: MacApps.list()))
        }
    }

    fileprivate func sendVolume(to session: ClientSession) {
        var message = RemoteCommand(t: "volume", s: SystemVolume.isMuted ? "muted" : "unmuted")
        if let volume = SystemVolume.volume { message.v = Double(volume) }
        session.send(message)
    }

    fileprivate func sendBrightness(to session: ClientSession) {
        guard let value = Brightness.current() else { return }
        session.send(RemoteCommand(t: "brightness", v: (value * 100).rounded()))
    }

    // MARK: - One connected phone

    fileprivate final class ClientSession {
        private enum Phase {
            case awaitingHello
            case handshaking(MacHandshake)
            case awaitingApproval
            case established(SecureChannel)
        }

        let connection: NWConnection
        weak var server: RemoteServer?
        private(set) var phoneId: String?
        private(set) var phoneName = "iPhone"
        private(set) var udpChannel: SecureChannel?
        let udpSessionId = Data((0..<8).map { _ in UInt8.random(in: 0...255) })

        private var phase = Phase.awaitingHello
        private var buffer = Data()
        private var closed = false

        var isEstablished: Bool {
            if case .established = phase { return true }
            return false
        }

        init(connection: NWConnection, server: RemoteServer) {
            self.connection = connection
            self.server = server
        }

        private var peer: String { "\(connection.endpoint)" }

        func start() {
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .failed(let error):
                    self.close(reason: "connection failed: \(error)")
                case .cancelled:
                    self.close(reason: "connection cancelled")
                default:
                    break
                }
            }
            connection.start(queue: .main)
            receive()
            // Pairing can take a minute (finding the QR code, typing the code); then give up.
            DispatchQueue.main.asyncAfter(deadline: .now() + PairingWindow.duration + 30) { [weak self] in
                guard let self, !self.isEstablished else { return }
                self.close(reason: "handshake timed out")
            }
        }

        private func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
                guard let self, !self.closed else { return }
                if let data, !data.isEmpty {
                    self.buffer.append(data)
                    self.processBuffer()
                }
                if let error {
                    self.close(reason: "receive error: \(error)")
                } else if isComplete {
                    self.close(reason: "phone closed the connection")
                } else if !self.closed {
                    self.receive()
                }
            }
        }

        private func processBuffer() {
            while !closed, let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                if !line.isEmpty { handle(line) }
            }
            if buffer.count > RemoteConstants.maxLineLength { close(reason: "too much data") }
        }

        private func handle(_ line: Data) {
            guard let server else { return }
            switch phase {
            case .awaitingHello:
                guard let message = try? JSONDecoder().decode(HandshakeMessage.self, from: line),
                      message.t == "hello" else {
                    // Old app versions or random traffic.
                    sendPlain(HandshakeMessage(t: "error", e: "Please update Couchpad on your iPhone."))
                    closeSoon(reason: "not a Couchpad hello")
                    return
                }
                guard server.acceptsHandshakes else {
                    sendPlain(HandshakeMessage(t: "error", e: "Too many failed attempts. Try again in a minute."))
                    closeSoon(reason: "locked out")
                    return
                }
                let handshake = MacHandshake(macId: server.pairings.macId, macName: server.computerName)
                do {
                    let reply = try handshake.receive(phoneHello: message, longTermKey: { server.pairings.key(for: $0) })
                    phoneId = handshake.phoneId
                    phoneName = handshake.phoneName ?? "iPhone"
                    phase = .handshaking(handshake)
                    sendPlain(reply)
                    if !handshake.phoneIsKnown {
                        Log.write("📱 “\(phoneName)” wants to pair.\(server.pairingWindow == nil ? " Click “Pair iPhone” to allow it." : "")")
                        server.onPairingRequested?(phoneName)
                    }
                } catch {
                    reject(error)
                }

            case .handshaking(let handshake):
                guard let message = try? JSONDecoder().decode(HandshakeMessage.self, from: line) else {
                    close(reason: "bad handshake message")
                    return
                }
                switch message.t {
                case "auth":
                    do {
                        establish(try handshake.receive(auth: message))
                    } catch {
                        server.recordFailure()
                        reject(error)
                    }
                case "pair":
                    do {
                        let result = try handshake.receive(pair: message, secret: { method in
                            if method == .code && !server.allowCodePairing { return nil }
                            return server.pairingWindow?.secret(for: method)
                        })
                        guard let phoneId else { return close(reason: "no phone id") }
                        server.pairings.add(phoneId: phoneId, name: phoneName, key: result.longTermKey)
                        sendPlain(result.reply)
                        server.pairingSucceeded(phoneName: phoneName)
                        establish(result.keys)
                    } catch HandshakeError.notAuthentic {
                        Log.write("⚠️  Wrong pairing code from “\(phoneName)”.")
                        server.pairingFailedAttempt()
                        sendPlain(HandshakeMessage(t: "pair_failed", e: "That code didn't match. Check the code on your Mac and try again."))
                        closeSoon(reason: "wrong pairing code")
                    } catch {
                        reject(error)
                    }
                default:
                    close(reason: "unexpected \(message.t)")
                }

            case .awaitingApproval:
                // The iPhone sends nothing until it gets auth_ok.
                break

            case .established(let channel):
                guard let sealed = Data(base64Encoded: line),
                      let plaintext = try? channel.open(sealed),
                      let command = try? JSONDecoder().decode(RemoteCommand.self, from: plaintext) else {
                    close(reason: "message failed decryption")
                    return
                }
                server.perform(command, from: self)
            }
        }

        private func establish(_ keys: SessionKeys) {
            guard let server else { return }
            if let ask = server.approvalHandler {
                phase = .awaitingApproval
                Log.write("❓ Waiting for approval on the Mac for “\(phoneName)”…")
                var answered = false
                ask(phoneName) { [weak self] allowed in
                    guard let self, !answered, !self.closed else { return }
                    answered = true
                    if allowed {
                        self.finishEstablishing(keys)
                    } else {
                        Log.write("🚫 Declined “\(self.phoneName)”.")
                        self.sendPlain(HandshakeMessage(t: "error", e: "The Mac declined the connection."))
                        self.closeSoon(reason: "declined on the Mac")
                    }
                }
                return
            }
            finishEstablishing(keys)
        }

        private func finishEstablishing(_ keys: SessionKeys) {
            guard let server else { return }
            phase = .established(SecureChannel(sendKey: keys.tcpSend, receiveKey: keys.tcpReceive, ordering: .strict))
            udpChannel = SecureChannel(sendKey: keys.udpSend, receiveKey: keys.udpReceive, ordering: .increasing)
            if let phoneId { server.pairings.markSeen(phoneId, name: phoneName) }
            Log.write("📱 “\(phoneName)” connected (\(peer)) – encrypted.")

            var ok = RemoteCommand(t: "auth_ok", s: server.computerName, m: server.capabilities,
                                   k: udpSessionId.map { String(format: "%02x", $0) }.joined())
            if let port = server.udpPort { ok.p = Int(port) }
            send(ok)
            server.sendVolume(to: self)
            server.sendBrightness(to: self)
            server.sessionEstablished(self)
        }

        private func reject(_ error: Error) {
            let text: String
            switch error {
            case HandshakeError.pairingRejected(let reason):
                text = reason
            case HandshakeError.notAuthentic:
                text = "This iPhone isn't paired with this Mac anymore. Pair again."
            default:
                text = "Couldn't connect securely. Update Couchpad on both devices and try again."
            }
            Log.write("⚠️  Refused “\(phoneName)” (\(peer)): \(error)")
            sendPlain(HandshakeMessage(t: "error", e: text))
            closeSoon(reason: "handshake failed")
        }

        /// Sends an encrypted command. Does nothing until the handshake has finished.
        func send(_ command: RemoteCommand) {
            guard !closed, case .established(let channel) = phase,
                  let json = try? JSONEncoder().encode(command),
                  let sealed = try? channel.seal(json) else { return }
            var line = Data(sealed.base64EncodedString().utf8)
            line.append(0x0A)
            connection.send(content: line, completion: .contentProcessed { _ in })
        }

        private func sendPlain(_ message: HandshakeMessage) {
            guard !closed, var data = try? JSONEncoder().encode(message) else { return }
            data.append(0x0A)
            connection.send(content: data, completion: .contentProcessed { _ in })
        }

        private func closeSoon(reason: String) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.close(reason: reason) }
        }

        func close(reason: String = "") {
            guard !closed else { return }
            closed = true
            if isEstablished {
                Log.write("👋 “\(phoneName)” disconnected\(reason.isEmpty ? "" : " – \(reason)")")
            }
            connection.stateUpdateHandler = nil
            connection.cancel()
            server?.remove(self)
        }
    }
}
