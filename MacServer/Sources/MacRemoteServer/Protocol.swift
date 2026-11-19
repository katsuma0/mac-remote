import Foundation

/// One message on the wire. Messages are JSON objects separated by newlines.
/// Keep this file identical to iOS/MacRemote/Protocol.swift.
///
/// t (type):  auth | auth_ok | auth_fail | move | scroll | click | down | up |
///            text | key | media | volume | system | ping | pong | hello | hello_ok |
///            dblclick | brightness | mirror (phone → Mac: s = list|connect|stop|open, m = [name])
///            mirroring (Mac → phone: m = screen names, s = connected screen, e = error)
///
/// Mouse movement and scrolling go over UDP (port `p` from auth_ok) so a lost Wi-Fi packet
/// never stalls the pointer; everything else goes over the TCP connection.
struct RemoteCommand: Codable {
    var t: String
    var dx: Double? = nil      // move / scroll delta
    var dy: Double? = nil
    var b: String? = nil       // mouse button: "left" | "right"
    var s: String? = nil       // text, key name, media key, system action, or message
    var m: [String]? = nil     // modifiers: cmd, shift, alt, ctrl
    var v: Double? = nil       // value (volume 0-100)
    var pin: String? = nil
    var k: String? = nil       // session token (UDP packets must carry it)
    var p: Int? = nil          // UDP port, sent in auth_ok
    var q: Int? = nil          // UDP sequence number
    var e: String? = nil       // error message
}

enum RemoteConstants {
    static let serviceType = "_macremote._tcp"
    static let defaultPort: UInt16 = 51515
}
