import SwiftUI

struct ConnectView: View {
    @EnvironmentObject var remote: RemoteConnection

    @State private var pinTarget: DiscoveredMac?
    @State private var pinText = ""
    @State private var showPinPrompt = false
    @State private var manualHost = ""
    @AppStorage("peerToPeer") private var peerToPeer = false

    var body: some View {
        NavigationStack {
            List {
                statusSection

                Section {
                    if remote.discovered.isEmpty {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Looking for Macs…").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(remote.discovered) { mac in
                        Button {
                            tapped(mac)
                        } label: {
                            HStack {
                                Label(mac.name, systemImage: "laptopcomputer")
                                Spacer()
                                if remote.savedPin(for: mac.name) != nil {
                                    Image(systemName: "key.fill").foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Macs nearby")
                } footer: {
                    Text("Start MacRemoteServer on your Mac first. Both devices should be on the same Wi-Fi.")
                }

                Section {
                    TextField("e.g. 192.168.1.20", text: $manualHost)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Connect") {
                        pinTarget = nil
                        pinText = remote.savedPin(for: manualHost) ?? ""
                        showPinPrompt = true
                    }
                    .disabled(manualHost.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: {
                    Text("Or connect by IP address")
                } footer: {
                    Text("Find your Mac's IP in System Settings → Wi-Fi → Details.")
                }

                Section {
                    Toggle("Direct connection (no Wi-Fi network)", isOn: $peerToPeer)
                        .onChange(of: peerToPeer) { _, _ in remote.startBrowsing() }
                } footer: {
                    Text("Connects AirDrop-style when your iPhone and Mac aren't on the same Wi-Fi. Start the Mac side with --p2p too. Leave this off at home: it can make the mouse lag.")
                }

                if let problem = remote.browseProblem {
                    Section {
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Mac Remote")
            .alert("Enter PIN", isPresented: $showPinPrompt) {
                TextField("PIN", text: $pinText)
                    .keyboardType(.numberPad)
                Button("Connect") { submit() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The PIN is shown on your Mac where MacRemoteServer is running.")
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        switch remote.state {
        case .connecting(let name):
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Connecting to \(name)…")
                }
            }
        case .failed(let message):
            Section {
                Label(message, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
            }
        default:
            EmptyView()
        }
    }

    private func tapped(_ mac: DiscoveredMac) {
        if let pin = remote.savedPin(for: mac.name) {
            remote.connect(to: mac, pin: pin)
        } else {
            pinTarget = mac
            pinText = ""
            showPinPrompt = true
        }
    }

    private func submit() {
        let pin = pinText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pin.isEmpty else { return }
        if let mac = pinTarget {
            remote.connect(to: mac, pin: pin)
        } else {
            remote.connect(host: manualHost, pin: pin)
        }
    }
}
