import Foundation

/// One command or event. Before pairing/authentication nothing but the handshake is accepted;
/// afterwards every message travels encrypted (see SecureSession.swift).
///
/// t (type), phone → Mac: move | scroll | click | dblclick | down | up | text | key | media |
///                         volume | brightness | system | mirror | apps | app_open | app_quit |
///                         clip_set | clip_get | ping | hello (UDP check)
///           Mac → phone: auth_ok | volume | brightness | mirroring | apps | clipboard | locked |
///                         pong | hello_ok
public struct RemoteCommand: Codable, Equatable {
    public var t: String
    public var dx: Double?        // move / scroll delta
    public var dy: Double?
    public var b: String?         // mouse button: "left" | "right"
    public var s: String?         // text, key name, media key, action, Mac name, or state
    public var m: [String]?       // modifiers, mirroring screen names, or capabilities
    public var v: Double?         // value (volume / brightness 0–100)
    public var k: String?         // UDP session id (hex), sent in auth_ok
    public var p: Int?            // UDP port, sent in auth_ok
    public var q: Int?            // reserved
    public var e: String?         // error message
    public var apps: [AppInfo]?   // running / favorite apps (t = "apps")

    public init(t: String, dx: Double? = nil, dy: Double? = nil, b: String? = nil, s: String? = nil,
                m: [String]? = nil, v: Double? = nil, k: String? = nil, p: Int? = nil, q: Int? = nil,
                e: String? = nil, apps: [AppInfo]? = nil) {
        self.t = t
        self.dx = dx
        self.dy = dy
        self.b = b
        self.s = s
        self.m = m
        self.v = v
        self.k = k
        self.p = p
        self.q = q
        self.e = e
        self.apps = apps
    }
}

/// An app on the Mac, for the app switcher.
public struct AppInfo: Codable, Equatable, Identifiable {
    public var id: String          // bundle identifier
    public var name: String
    public var icon: String?       // small PNG, base64
    public var running: Bool
    public var active: Bool?

    public init(id: String, name: String, icon: String? = nil, running: Bool, active: Bool? = nil) {
        self.id = id
        self.name = name
        self.icon = icon
        self.running = running
        self.active = active
    }
}

public enum RemoteConstants {
    public static let serviceType = "_couchpad._tcp"
    public static let defaultPort: UInt16 = 51515
    /// Lines longer than this are treated as garbage and the connection is dropped.
    public static let maxLineLength = 1024 * 1024
}

/// Features the Mac reports in auth_ok (`m`), so the phone only shows controls that work.
public enum Capability {
    /// 0–100% brightness slider (needs a private framework, so not in the Mac App Store build).
    public static let brightnessSlider = "brightness-slider"
    public static let sleepDisplay = "sleep-display"
    public static let screenMirroring = "screen-mirroring"
    public static let apps = "apps"
    public static let clipboard = "clipboard"
    /// Maximum clipboard text sent in either direction (characters).
    public static let clipboardLimit = 100_000
}
