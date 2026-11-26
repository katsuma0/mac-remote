import AppKit
#if canImport(RemoteCore)
import RemoteCore
#endif

/// The app switcher: running apps (with small icons), a few favorites to open, switch and quit.
/// Uses only NSWorkspace / NSRunningApplication, which work inside the App Store sandbox.
enum MacApps {
    /// Apps offered in "Open an App" when they're installed.
    private static let favorites = [
        "com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox", "com.microsoft.edgemac",
        "com.apple.Music", "com.spotify.client", "com.apple.TV", "com.apple.podcasts",
        "com.apple.QuickTimePlayerX", "org.videolan.vlc", "com.apple.Photos", "com.apple.finder",
        "com.apple.iWork.Keynote", "com.microsoft.Powerpoint", "us.zoom.xos", "com.apple.FaceTime",
        "com.apple.Notes", "com.apple.systempreferences",
    ]

    private static var iconCache: [String: String] = [:]

    static func list() -> [AppInfo] {
        let ownId = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        var result: [AppInfo] = []

        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let id = app.bundleIdentifier, id != ownId, seen.insert(id).inserted else { continue }
            result.append(AppInfo(id: id, name: app.localizedName ?? id, icon: icon(for: id, url: app.bundleURL),
                                  running: true, active: app.isActive))
        }
        result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        for id in favorites where !seen.contains(id) {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { continue }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            result.append(AppInfo(id: id, name: name, icon: icon(for: id, url: url), running: false))
        }
        return Array(result.prefix(60))
    }

    /// Brings a running app to the front, or launches it.
    static func open(_ bundleId: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error { Log.write("⚠️  Couldn't open \(bundleId): \(error.localizedDescription)") }
        }
    }

    static func quit(_ bundleId: String) {
        guard bundleId != Bundle.main.bundleIdentifier else { return }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleId) {
            app.terminate()
        }
    }

    /// 40×40 pt PNG (80 px), base64 – small enough to send a whole list at once.
    private static func icon(for bundleId: String, url: URL?) -> String? {
        if let cached = iconCache[bundleId] { return cached }
        guard let url else { return nil }
        let source = NSWorkspace.shared.icon(forFile: url.path)
        let size = NSSize(width: 80, height: 80)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 80, pixelsHigh: 80,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        source.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        let encoded = png.base64EncodedString()
        iconCache[bundleId] = encoded
        return encoded
    }
}

/// Clipboard sharing, only when the paired iPhone asks.
enum MacClipboard {
    static func set(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(String(text.prefix(Capability.clipboardLimit)), forType: .string)
    }

    static var text: String {
        String((NSPasteboard.general.string(forType: .string) ?? "").prefix(Capability.clipboardLimit))
    }
}

/// Knows whether the Mac's screen is locked, so a phone can't type at the login screen.
final class ScreenLockMonitor {
    static let shared = ScreenLockMonitor()
    private(set) var isLocked = false

    private init() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.isLocked = true
        }
        center.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.isLocked = false
        }
    }
}
