import AppKit
import SwiftUI

/// The Mac app: a window with an on/off button, paired iPhones and pairing, a Dock icon, and a
/// menu bar icon that stays while it runs in the background. Closing the window doesn't quit.
struct MacRemoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("Couchpad", id: "main") {
            MainWindow()
                .environmentObject(model)
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuBarMenu()
                .environmentObject(model)
        } label: {
            Image(systemName: menuBarSymbol)
        }
    }

    private var menuBarSymbol: String {
        if !model.isRunning { return "cursorarrow.slash" }
        return model.connectedPhoneNames.isEmpty ? "cursorarrow" : "cursorarrow.motionlines"
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)          // show in the Dock
        NSApp.activate(ignoringOtherApps: true)
        AppModel.shared.appDidLaunch()
    }

    /// Keep running in the menu bar after the window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.stop()
    }
}

// MARK: - Window

struct MainWindow: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            header
            statusRow
            onOffButton

            if let name = model.pairingRequestedBy, !model.showingPairing {
                pairingRequestBanner(name)
            }

            pairedPhones

            if !model.accessibilityGranted {
                permissionWarning
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Turn on automatically when Couchpad opens", isOn: $model.startAutomatically)
                Toggle("Open Couchpad when I log in", isOn: $model.openAtLogin)
                Toggle("Allow direct connection without Wi-Fi (can add lag)", isOn: $model.peerToPeer)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            activityLog

            Text("You can close this window – Couchpad keeps running in the menu bar.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 460)
        .sheet(isPresented: $model.showingPairing, onDismiss: { model.endPairing() }) {
            PairingSheet()
                .environmentObject(model)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 60, height: 60)
            VStack(alignment: .leading, spacing: 2) {
                Text("Couchpad")
                    .font(.title2.weight(.bold))
                Text(model.computerName)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var statusRow: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 12, height: 12)
            Text(model.statusText)
                .font(.headline)
            Spacer()
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private var onOffButton: some View {
        Button {
            model.toggle()
        } label: {
            Label(model.isRunning ? "Turn Off" : "Turn On – make this Mac findable",
                  systemImage: model.isRunning ? "power" : "antenna.radiowaves.left.and.right")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(model.isRunning ? .red : .accentColor)
        .controlSize(.large)
    }

    private func pairingRequestBanner(_ name: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "iphone.radiowaves.left.and.right")
                .font(.title2)
            Text("“\(name)” wants to pair with this Mac.")
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Pair…") { model.beginPairing() }
                .buttonStyle(.borderedProminent)
            Button {
                model.pairingRequestedBy = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private var pairedPhones: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Paired iPhones")
                    .font(.headline)
                Spacer()
                Button {
                    model.beginPairing()
                } label: {
                    Label("Pair iPhone…", systemImage: "plus")
                }
                .controlSize(.small)
            }
            if model.pairedPhones.isEmpty {
                Text("No iPhones yet. Click “Pair iPhone…”, then scan the code with your iPhone.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(model.pairedPhones) { phone in
                    HStack(spacing: 10) {
                        Image(systemName: "iphone")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(phone.name)
                            Text(model.isConnected(phone) ? "Connected" : lastSeenText(phone))
                                .font(.caption)
                                .foregroundStyle(model.isConnected(phone) ? Color.green : Color.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            model.unpair(phone)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Unpair this iPhone")
                    }
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private var permissionWarning: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Permission needed", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("To move the pointer and type, turn on **Couchpad** in System Settings → Privacy & Security → Accessibility.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open Accessibility Settings") { model.openAccessibilitySettings() }
                Button("Ask Again") { model.requestAccessibility() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private var activityLog: some View {
        DisclosureGroup("Activity") {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.activity.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                }
                .frame(height: 110)
                .onChange(of: model.activity.count) { count in
                    proxy.scrollTo(count - 1, anchor: .bottom)
                }
            }
        }
    }

    private var statusColor: Color {
        guard model.isRunning else { return .gray }
        if !model.connectedPhoneNames.isEmpty { return .green }
        return model.isListening ? .blue : .yellow
    }

    private func lastSeenText(_ phone: PairedPhone) -> String {
        guard let lastSeen = phone.lastSeen else { return "Paired" }
        return "Last connected " + lastSeen.formatted(.relative(presentation: .named))
    }
}

// MARK: - Pairing sheet

struct PairingSheet: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            if let name = model.justPaired {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.green)
                Text("Paired with \(name)")
                    .font(.title2.weight(.semibold))
                Text("You can now control this Mac from your iPhone.")
                    .foregroundStyle(.secondary)
                Button("Done") { model.endPairing() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            } else if let pairing = model.pairing {
                Text("Pair your iPhone")
                    .font(.title2.weight(.semibold))
                Text("Point your iPhone's camera at this code, or tap **Scan Pairing Code** in Couchpad on your iPhone.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let qr = AppModel.qrCode(for: pairing.link) {
                    Image(nsImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 220, height: 220)
                        .padding(12)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                }

                VStack(spacing: 4) {
                    Text("Or enter this code on your iPhone")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(pairing.code.prefix(3)) \(pairing.code.suffix(3))")
                        .font(.system(size: 36, weight: .bold, design: .monospaced))
                        .textSelection(.enabled)
                }

                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = max(0, Int(pairing.expires.timeIntervalSince(context.date)))
                    Text("Expires in \(remaining / 60):\(String(format: "%02d", remaining % 60))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Button("Cancel") { model.endPairing() }
                    .keyboardShortcut(.cancelAction)
            } else {
                Image(systemName: "clock")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("Pairing closed")
                    .font(.title3.weight(.semibold))
                Text("The code expired or was entered wrong too many times.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Close") { model.endPairing() }
                    Button("Try Again") { model.beginPairing() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(28)
        .frame(width: 380)
    }
}

// MARK: - Menu bar

struct MenuBarMenu: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.statusText)
        Divider()
        Button(model.isRunning ? "Turn Off" : "Turn On") {
            model.toggle()
        }
        Button("Pair iPhone…") {
            showWindow()
            model.beginPairing()
        }
        Button("Show Couchpad Window") {
            showWindow()
        }
        Divider()
        Button("Quit Couchpad") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func showWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
