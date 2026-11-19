import AppKit
import SwiftUI

/// The Mac app: a window with a Start button and the PIN, a Dock icon, and a menu bar icon that
/// stays while it runs in the background. Closing the window doesn't quit; use Quit in either menu.
struct MacRemoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("Mac Remote", id: "main") {
            MainWindow()
                .environmentObject(model)
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuBarMenu()
                .environmentObject(model)
        } label: {
            Image(systemName: model.isRunning
                  ? (model.connectedPhones > 0 ? "iphone.radiowaves.left.and.right" : "iphone")
                  : "iphone.slash")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)          // show in the Dock
        NSApp.applicationIconImage = AppIcon.image()
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
        VStack(spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: AppIcon.image())
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mac Remote")
                        .font(.title2.weight(.bold))
                    Text(model.computerName)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            // Status
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

            // The big button
            Button {
                model.toggle()
            } label: {
                Label(model.isRunning ? "Stop" : "Connect – make this Mac findable",
                      systemImage: model.isRunning ? "stop.fill" : "antenna.radiowaves.left.and.right")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isRunning ? .red : .accentColor)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)

            // PIN
            VStack(spacing: 6) {
                Text("PIN to enter on your iPhone")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(spacedPin)
                    .font(.system(size: 40, weight: .bold, design: .monospaced))
                    .textSelection(.enabled)
                HStack {
                    Button("Copy") { model.copyPin() }
                    Button("New PIN") { model.newPin() }
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity)
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

            if !model.accessibilityGranted {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Permission needed", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    Text("To move the mouse and type, turn on **Mac Remote** in System Settings → Privacy & Security → Accessibility.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Accessibility Settings") { model.openAccessibilitySettings() }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Start automatically when Mac Remote opens", isOn: $model.startAutomatically)
                Toggle("Open Mac Remote when I log in", isOn: $model.openAtLogin)
                Toggle("Allow direct connection without Wi-Fi (can add lag)", isOn: $model.peerToPeer)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

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
                    .frame(height: 120)
                    .onChange(of: model.activity.count) { count in
                        proxy.scrollTo(count - 1, anchor: .bottom)
                    }
                }
            }

            Text("You can close this window – Mac Remote keeps running in the menu bar.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 440)
    }

    private var statusColor: Color {
        guard model.isRunning else { return .gray }
        if model.connectedPhones > 0 { return .green }
        return model.isListening ? .blue : .yellow
    }

    private var spacedPin: String {
        model.pin.count == 6 ? "\(model.pin.prefix(3)) \(model.pin.suffix(3))" : model.pin
    }
}

// MARK: - Menu bar

struct MenuBarMenu: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.statusText)
        if model.isRunning {
            Text("PIN: \(model.pin)")
        }
        Divider()
        Button(model.isRunning ? "Stop" : "Connect – make this Mac findable") {
            model.toggle()
        }
        Button("Show Mac Remote Window") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("Quit Mac Remote") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

// MARK: - Icon

/// The app icon, drawn in code (blue rounded square with a phone + radio waves).
enum AppIcon {
    private static var cached: NSImage?

    static func image() -> NSImage {
        if let cached { return cached }
        let image = draw(size: 1024)
        cached = image
        return image
    }

    static func draw(size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        let inset = size * 0.08
        let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
        let background = NSBezierPath(roundedRect: rect, xRadius: size * 0.2, yRadius: size * 0.2)
        NSGradient(starting: NSColor(calibratedRed: 0.25, green: 0.55, blue: 1.0, alpha: 1),
                   ending: NSColor(calibratedRed: 0.35, green: 0.25, blue: 0.85, alpha: 1))?
            .draw(in: background, angle: -90)

        let config = NSImage.SymbolConfiguration(pointSize: size * 0.42, weight: .semibold)
        if let symbol = NSImage(systemSymbolName: "iphone.radiowaves.left.and.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            let symbolSize = symbol.size
            let white = NSImage(size: symbolSize)
            white.lockFocus()
            symbol.draw(in: NSRect(origin: .zero, size: symbolSize))
            NSColor.white.set()
            NSRect(origin: .zero, size: symbolSize).fill(using: .sourceAtop)
            white.unlockFocus()
            white.draw(in: NSRect(x: (size - symbolSize.width) / 2, y: (size - symbolSize.height) / 2,
                                  width: symbolSize.width, height: symbolSize.height))
        }
        image.unlockFocus()
        return image
    }

    /// Used by make-app.sh to build the .icns file.
    static func writePNG(to url: URL) -> Bool {
        let image = draw(size: 1024)
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: url)
            return true
        } catch {
            return false
        }
    }
}
