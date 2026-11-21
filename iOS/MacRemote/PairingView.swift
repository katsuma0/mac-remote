import SwiftUI

/// Shown when the Mac doesn't know this iPhone yet: scan the QR code or type the 6-digit code
/// that the Mac shows under "Pair iPhone…".
struct PairingView: View {
    @EnvironmentObject var remote: RemoteConnection
    @State private var code = ""
    @State private var showScanner = false
    @FocusState private var codeFocused: Bool

    private var isWorking: Bool {
        if case .pairing = remote.state { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.tint)
                        .padding(.top, 12)

                    VStack(spacing: 8) {
                        Text("Pair with \(remote.macName)")
                            .font(.title2.weight(.bold))
                            .multilineTextAlignment(.center)
                        Text("Only paired iPhones can control your Mac. On the Mac, open Couchpad and click **Pair iPhone…**")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        showScanner = true
                    } label: {
                        Label("Scan Pairing Code", systemImage: "qrcode.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isWorking)

                    VStack(spacing: 8) {
                        Text("or enter the 6-digit code")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        TextField("000000", text: $code)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                            .font(.system(size: 34, weight: .semibold, design: .monospaced))
                            .multilineTextAlignment(.center)
                            .padding(.vertical, 10)
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                            .focused($codeFocused)
                            .disabled(isWorking)
                            .onChange(of: code) { _, newValue in
                                let digits = String(newValue.filter(\.isNumber).prefix(6))
                                if digits != newValue { code = digits }
                                if digits.count == 6 { remote.pair(code: digits) }
                            }
                    }

                    if isWorking {
                        ProgressView("Pairing…")
                    }

                    if let error = remote.pairingError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(24)
            }
            .navigationTitle("Pair")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { remote.cancelPairing() }
                }
            }
            .onChange(of: remote.pairingError) { _, error in
                if error != nil { code = "" }
            }
            .sheet(isPresented: $showScanner) {
                ScanSheet { link in remote.pair(with: link) }
            }
        }
    }
}
