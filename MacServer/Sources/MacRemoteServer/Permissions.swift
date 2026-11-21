import ApplicationServices
import CoreGraphics

/// Accessibility permission: needed to move the mouse, type, and press the Screen Mirroring menu.
enum Permissions {
    static var isGranted: Bool {
        #if APP_STORE
        // Sandboxed apps also need the "post events" permission to send mouse and keyboard input.
        return AXIsProcessTrusted() && CGPreflightPostEventAccess()
        #else
        return AXIsProcessTrusted()
        #endif
    }

    /// Shows macOS's permission prompt(s) if needed.
    static func request() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        #if APP_STORE
        if !CGPreflightPostEventAccess() {
            _ = CGRequestPostEventAccess()
        }
        #endif
    }
}
