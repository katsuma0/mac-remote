import Foundation
import Network
import SystemConfiguration

/// Listens for the iPhone app on the local network (Wi-Fi, Ethernet, or peer-to-peer Wi-Fi/AWDL)
/// and advertises itself with Bonjour so the phone finds it automatically.
/// Everything runs on the main queue.
final class RemoteServer {
    let pin: String
    let input = InputController()
    let computerName: String = (SCDynamicStoreCopyComputerName(nil, nil) as String?)
        ?? Host.current().localizedName ?? "Mac"

    /// Peer-to-peer Wi-Fi (AWDL, what AirDrop uses) lets the phone connect with no shared network,
    /// but it makes the Wi-Fi radio hop channels and adds latency spikes, so it is opt-in (--p2p).
    let peerToPeer: Bool

    private var listener: NWListener?
    private var udpListener: NWListener?
    private var udpFlows: [ObjectIdentifier: NWConnection] = [:]
    private var sessions: [ObjectIdentifier: ClientSession] = [:]

    // Brute-force protection for the PIN.
    private var failedAttempts = 0
    private var lockedUntil = Date.distantPast

    init(pin: String, peerToPeer: Bool) {
        self.pin = pin
        self.peerToPeer = peerToPeer
    }

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

    // MARK: UDP (mouse movement)

    /// Mouse movement uses UDP: a lost packet is simply skipped instead of stalling everything
    /// behind it until TCP retransmits it (which feels like 200 ms+ of lag on Wi-Fi).
    func startUDP(port: UInt16? = RemoteConstants.defaultPort) {
        let newListener: NWListener
        do {
            if let port, let nwPort = NWEndpoint.Port(rawValue: port) {
                newListener = try NWListener(using: udpParameters(), on: nwPort)
            } else {
                newListener = try NWListener(using: udpParameters())
            }
        } catch {
            print("⚠️  UDP unavailable (\(error)); mouse movement will use TCP.")
            return
        }
        newListener.stateUpdateHandler = { [weak self, weak newListener] state in
            guard let self, let newListener, newListener === self.udpListener else { return }
            switch state {
            case .ready:
                print("✅ Fast mouse channel (UDP) on port \(newListener.port?.rawValue ?? 0)")
            case .failed(let error):
                newListener.cancel()
                self.udpListener = nil
                if case .posix(let code) = error, code == .EADDRINUSE, port != nil {
                    self.startUDP(port: nil)
                } else {
                    print("⚠️  UDP listener failed (\(error)); retrying.")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.startUDP(port: port) }
                }
            default:
                break
            }
        }
        newListener.newConnectionHandler = { [weak self] flow in
            guard let self else { flow.cancel(); return }
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

    private func handleDatagram(_ data: Data, from flow: NWConnection) {
        guard let cmd = try? JSONDecoder().decode(RemoteCommand.self, from: data),
              let token = cmd.k,
              let session = sessions.values.first(where: { $0.authenticated && $0.token == token })
        else { return }   // unknown or unauthenticated sender: ignore

        switch cmd.t {
        case "hello":
            // Lets the phone confirm UDP actually gets through (firewalls) before relying on it.
            if let reply = try? JSONEncoder().encode(RemoteCommand(t: "hello_ok")) {
                flow.send(content: reply, completion: .idempotent)
            }
        case "move", "scroll":
            // Drop packets that arrive after a newer one (Wi-Fi can reorder); deltas are small.
            if let q = cmd.q {
                if q <= session.lastUDPSequence && session.lastUDPSequence - q < 1_000_000 { return }
                session.lastUDPSequence = q
            }
            perform(cmd, from: session)
        default:
            break
        }
    }

    func start(port: UInt16? = RemoteConstants.defaultPort) {
        let newListener: NWListener
        do {
            if let port, let nwPort = NWEndpoint.Port(rawValue: port) {
                newListener = try NWListener(using: parameters(), on: nwPort)
            } else {
                newListener = try NWListener(using: parameters())
            }
        } catch {
            print("❌ Could not create listener: \(error)")
            retry(port: nil)
            return
        }

        newListener.service = NWListener.Service(name: computerName, type: RemoteConstants.serviceType)

        newListener.stateUpdateHandler = { [weak self, weak newListener] state in
            guard let self, let newListener, newListener === self.listener else { return }
            switch state {
            case .ready:
                print("✅ Listening on port \(newListener.port?.rawValue ?? 0)")
            case .waiting(let error):
                print("⏳ Waiting for network: \(error)")
            case .failed(let error):
                print("❌ Listener failed: \(error)")
                newListener.cancel()
                if case .posix(let code) = error, code == .EADDRINUSE {
                    print("   Port \(port ?? 0) is busy, using a random port instead.")
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
                print("📡 Advertising on Bonjour as \(endpoint)")
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

    private func accept(_ connection: NWConnection) {
        let session = ClientSession(connection: connection, server: self)
        sessions[ObjectIdentifier(session)] = session
        session.start()
    }

    fileprivate func remove(_ session: ClientSession) {
        sessions[ObjectIdentifier(session)] = nil
        if !sessions.values.contains(where: { $0.authenticated }) {
            input.releaseAll()
            udpFlows.values.forEach { $0.cancel() }
            udpFlows.removeAll()
        }
    }

    enum PinResult { case ok, wrong, locked }

    fileprivate func checkPin(_ attempt: String?) -> PinResult {
        if Date() < lockedUntil { return .locked }
        if attempt == pin {
            failedAttempts = 0
            return .ok
        }
        failedAttempts += 1
        if failedAttempts >= 5 {
            failedAttempts = 0
            lockedUntil = Date().addingTimeInterval(60)
            print("🔒 Too many wrong PINs, locking for 60 seconds.")
        }
        return .wrong
    }

    fileprivate func perform(_ cmd: RemoteCommand, from session: ClientSession) {
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
            SystemActions.setVolume(Int((cmd.v ?? 0).rounded()))
        case "brightness":
            if !Brightness.set((cmd.v ?? 0) / 100) {
                session.send(RemoteCommand(t: "brightness", e: "Brightness can't be set on this Mac's display."))
            }
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
                    print("🖥  Screen Mirroring: \(error.message)")
                    session.send(RemoteCommand(t: "mirroring", e: error.message))
                }
            }
        case "system":
            if cmd.s == "sleepdisplay" { SystemActions.sleepDisplay() }
        case "ping":
            session.send(RemoteCommand(t: "pong"))
        default:
            print("Unknown command: \(cmd.t)")
        }
    }

    fileprivate func sendVolume(to session: ClientSession) {
        SystemActions.getVolume { volume, muted in
            var msg = RemoteCommand(t: "volume", s: muted ? "muted" : "unmuted")
            if let volume { msg.v = Double(volume) }
            session.send(msg)
        }
    }

    fileprivate func sendBrightness(to session: ClientSession) {
        if let value = Brightness.get() {
            session.send(RemoteCommand(t: "brightness", v: (value * 100).rounded()))
        } else {
            session.send(RemoteCommand(t: "brightness", e: "Brightness can't be read on this Mac's display."))
        }
    }

    // MARK: - One connected phone

    fileprivate final class ClientSession {
        let connection: NWConnection
        weak var server: RemoteServer?
        private(set) var authenticated = false
        let token = UUID().uuidString
        var lastUDPSequence = -1
        private var buffer = Data()
        private var closed = false

        init(connection: NWConnection, server: RemoteServer) {
            self.connection = connection
            self.server = server
        }

        private var peer: String { "\(connection.endpoint)" }

        func start() {
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .failed, .cancelled:
                    self.close()
                default:
                    break
                }
            }
            connection.start(queue: .main)
            receive()
        }

        private func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
                guard let self, !self.closed else { return }
                if let data, !data.isEmpty {
                    self.buffer.append(data)
                    self.processBuffer()
                }
                if isComplete || error != nil {
                    self.close()
                } else {
                    self.receive()
                }
            }
        }

        private func processBuffer() {
            while !closed, let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                handle(line)
            }
            if buffer.count > 1_000_000 { close() }   // garbage / abuse
        }

        private func handle(_ line: Data) {
            guard !line.isEmpty,
                  let cmd = try? JSONDecoder().decode(RemoteCommand.self, from: line),
                  let server else { return }

            if !authenticated {
                guard cmd.t == "auth" else { return }
                switch server.checkPin(cmd.pin) {
                case .ok:
                    authenticated = true
                    print("📱 Phone connected (\(peer))")
                    var ok = RemoteCommand(t: "auth_ok", s: server.computerName, k: token)
                    if let udpPort = server.udpPort { ok.p = Int(udpPort) }
                    send(ok)
                    server.sendVolume(to: self)
                    server.sendBrightness(to: self)
                case .wrong:
                    print("⚠️  Wrong PIN from \(peer)")
                    send(RemoteCommand(t: "auth_fail", s: "Wrong PIN"))
                    closeSoon()
                case .locked:
                    send(RemoteCommand(t: "auth_fail", s: "Too many wrong PINs. Try again in a minute."))
                    closeSoon()
                }
                return
            }
            server.perform(cmd, from: self)
        }

        func send(_ cmd: RemoteCommand) {
            guard !closed, var data = try? JSONEncoder().encode(cmd) else { return }
            data.append(0x0A)
            connection.send(content: data, completion: .contentProcessed { _ in })
        }

        private func closeSoon() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.close() }
        }

        func close() {
            guard !closed else { return }
            closed = true
            if authenticated { print("👋 Phone disconnected (\(peer))") }
            connection.stateUpdateHandler = nil
            connection.cancel()
            server?.remove(self)
        }
    }
}
