import SwiftUI

/// Shown when not connected: scan a pairing code, or pick a Mac on the network.
struct ConnectView: View {
    @EnvironmentObject var remote: RemoteConnection

    @State private var manualHost = ""
    @State private var showScanner = false
    @AppStorage("peerToPeer") private var peerToPeer = false

    var body: some View {
        NavigationStack {
            List {
                statusSection

                Section {
                    Button {
                        showScanner = true
                    } label: {
                        Label("Scan Pairing Code", systemImage: "qrcode.viewfinder")
                            .font(.headline)
                    }
                } footer: {
                    Text("First time? On your Mac, open Couchpad and click **Pair iPhone…**, then scan the code it shows.")
                }

                Section {
                    if remote.discovered.isEmpty {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Looking for Macs…").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(remote.discovered) { mac in
                        Button {
                            remote.connect(to: mac)
                        } label: {
                            HStack {
                                Label(mac.name, systemImage: "laptopcomputer")
                                    .foregroundStyle(.primary)
                                Spacer()
                                if mac.isPaired {
                                    Image(systemName: "checkmark.seal.fill")
                                        .foregroundStyle(.green)
                                        .accessibilityLabel("Paired")
                                } else {
                                    Text("Not paired")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Macs nearby")
                } footer: {
                    Text("Turn Couchpad on on your Mac. Both devices should be on the same Wi-Fi.")
                }

                Section {
                    TextField("e.g. 192.168.1.20", text: $manualHost)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Connect") {
                        remote.connect(host: manualHost)
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
                    Text("Connects AirDrop-style when your iPhone and Mac aren't on the same Wi-Fi. Turn on the same option on the Mac. Leave this off at home: it can make the pointer lag.")
                }

                if let problem = remote.browseProblem {
                    Section {
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Couchpad")
            .sheet(isPresented: $showScanner) {
                ScanSheet { link in remote.pair(with: link) }
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
}
