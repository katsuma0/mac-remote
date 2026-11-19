import AppKit
import ApplicationServices

/// AirPlay screen mirroring, driven through the Screen Mirroring menu in the menu bar.
///
/// macOS has no API for starting AirPlay mirroring, so this presses the same buttons you would,
/// using the Accessibility API (the permission the server already has for mouse and keyboard).
///
/// What it relies on (seen on macOS 26/27):
/// - The menu bar icons live in a process called MenuBarAgent, under AXExtrasMenuBar; the Screen
///   Mirroring icon has the identifier `com.apple.menuextra.screen-mirroring`.
/// - Pressing it opens a Control Center panel whose screens are AXCheckBox toggles with identifiers
///   starting `screen-mirroring-device-`, the screen's name as description, and value 1 when mirroring.
/// Older layouts (icon hosted by ControlCenter, or only reachable through Control Center) are tried too.
enum Mirroring {
    struct Screen {
        let name: String
        let connected: Bool
    }

    enum Action: String {
        case list, connect, stop, open
    }

    struct MirroringError: Error {
        let message: String
    }

    /// Serial: actions drive the same menu, so they must not overlap. Accessibility calls block,
    /// so they run off the main queue.
    private static let queue = DispatchQueue(label: "mirroring", qos: .userInitiated)

    private static let processNames = ["MenuBarAgent", "ControlCenter", "SystemUIServer"]
    private static var cachedApplications: [AXUIElement] = []

    /// Runs the action and calls back on the main queue.
    static func perform(_ action: Action, name: String? = nil,
                        completion: @escaping (Result<[Screen], MirroringError>) -> Void) {
        queue.async {
            let result: Result<[Screen], MirroringError>
            do {
                result = .success(try run(action, name: name))
            } catch let error as MirroringError {
                result = .failure(error)
            } catch {
                result = .failure(MirroringError(message: "\(error)"))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: - Steps

    private static func run(_ action: Action, name: String?) throws -> [Screen] {
        guard AXIsProcessTrusted() else {
            throw MirroringError(message: "Accessibility permission is missing for Terminal or MacRemoteServer (System Settings → Privacy & Security → Accessibility).")
        }

        cachedApplications = processNames.compactMap { MenuBarInspector.pid(of: $0) }
            .map { AXUIElementCreateApplication($0) }

        var openedVia: AXUIElement?   // the menu bar icon we pressed, used to close the panel again
        if !panelIsOpen() {
            openedVia = try openPanel()
        }
        if action == .open { return [] }   // leave it open on the Mac's screen

        defer { closePanel(using: openedVia) }

        var toggles = try waitForToggles()
        switch action {
        case .list, .open:
            break

        case .connect:
            guard let name, let toggle = toggles.first(where: { label($0) == name }) else {
                throw MirroringError(message: "Couldn't find “\(name ?? "")” in Screen Mirroring. Make sure the TV is on and on the same Wi-Fi, then refresh.")
            }
            AXUIElementPerformAction(toggle, kAXPressAction as CFString)
            Thread.sleep(forTimeInterval: 2)
            let after = deviceToggles()
            if after.isEmpty {
                // The panel closed by itself after choosing; report what we just did.
                return toggles.map { Screen(name: label($0), connected: label($0) == name) }
            }
            toggles = after

        case .stop:
            guard let toggle = toggles.first(where: isOn) else {
                throw MirroringError(message: "Your Mac isn't mirroring to anything right now.")
            }
            AXUIElementPerformAction(toggle, kAXPressAction as CFString)
            Thread.sleep(forTimeInterval: 1)
            let after = deviceToggles()
            if after.isEmpty {
                return toggles.map { Screen(name: label($0), connected: false) }
            }
            toggles = after
        }

        var seen = Set<String>()
        return toggles.compactMap { toggle in
            let name = label(toggle)
            guard !name.isEmpty, seen.insert(name).inserted else { return nil }
            return Screen(name: name, connected: isOn(toggle))
        }
    }

    /// Presses the Screen Mirroring icon (or goes through Control Center). Returns the icon pressed.
    private static func openPanel() throws -> AXUIElement? {
        if let icon = menuExtra(where: { id, desc in
            id.contains("screen-mirroring") || id.contains("screenmirroring") || desc.contains("Mirroring")
        }) {
            AXUIElementPerformAction(icon, kAXPressAction as CFString)
            return icon
        }

        // No icon in the menu bar: open Control Center and press its Screen Mirroring tile.
        if let controlCenter = menuExtra(where: { id, _ in id.contains("controlcenter") }) {
            AXUIElementPerformAction(controlCenter, kAXPressAction as CFString)
            Thread.sleep(forTimeInterval: 0.8)
            if let tile = findInWindows(where: { element in
                let role = MenuBarInspector.string(element, kAXRoleAttribute)
                guard role == kAXCheckBoxRole || role == kAXButtonRole else { return false }
                return label(element).contains("Mirroring")
            }) {
                AXUIElementPerformAction(tile, kAXPressAction as CFString)
                return controlCenter
            }
            AXUIElementPerformAction(controlCenter, kAXPressAction as CFString)   // close it again
        }

        throw MirroringError(message: "Couldn't find Screen Mirroring in the menu bar. On the Mac, turn it on in System Settings → Control Center → Screen Mirroring → Always Show in Menu Bar.")
    }

    /// AirPlay screens take a moment to appear; wait until the list stops growing.
    private static func waitForToggles() throws -> [AXUIElement] {
        var toggles: [AXUIElement] = []
        var stableRounds = 0
        for _ in 0..<20 {   // up to ~5 seconds
            Thread.sleep(forTimeInterval: 0.25)
            let current = deviceToggles()
            if !current.isEmpty && current.count == toggles.count {
                stableRounds += 1
                if stableRounds >= 2 { return current }
            } else {
                stableRounds = 0
            }
            toggles = current
        }
        if toggles.isEmpty && !panelIsOpen() {
            throw MirroringError(message: "The Screen Mirroring menu didn't open on the Mac.")
        }
        return toggles   // may be empty: panel is open but no screens were found
    }

    private static func closePanel(using icon: AXUIElement?) {
        guard panelIsOpen() else { return }
        if let icon {
            // Pressing the icon again toggles the panel closed, without sending a key to other apps.
            AXUIElementPerformAction(icon, kAXPressAction as CFString)
        } else {
            for down in [true, false] {
                CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: down)?.post(tap: .cghidEventTap)
            }
        }
    }

    // MARK: - Finding things

    /// Screen toggles in the open Screen Mirroring panel.
    private static func deviceToggles() -> [AXUIElement] {
        var result: [AXUIElement] = []
        forEachWindowElement { element in
            guard MenuBarInspector.string(element, kAXRoleAttribute) == kAXCheckBoxRole else { return }
            if MenuBarInspector.string(element, kAXIdentifierAttribute).hasPrefix("screen-mirroring-device") {
                result.append(element)
            }
        }
        return result
    }

    private static func panelIsOpen() -> Bool {
        findInWindows(where: { element in
            let id = MenuBarInspector.string(element, kAXIdentifierAttribute)
            return id == "screen-mirroring-header" || id == "screen-mirroring-device-list"
                || id.hasPrefix("screen-mirroring-device")
        }) != nil
    }

    private static func menuExtra(where matches: (_ identifier: String, _ description: String) -> Bool) -> AXUIElement? {
        for app in applications() {
            guard let bar = MenuBarInspector.copy(app, kAXExtrasMenuBarAttribute).0 else { continue }
            var queue = MenuBarInspector.elements(from: bar)
            var visited = 0
            while !queue.isEmpty && visited < 300 {
                let element = queue.removeFirst()
                visited += 1
                if MenuBarInspector.string(element, kAXRoleAttribute) == kAXMenuBarItemRole {
                    let id = MenuBarInspector.string(element, kAXIdentifierAttribute)
                    let desc = MenuBarInspector.string(element, kAXDescriptionAttribute)
                        + " " + MenuBarInspector.string(element, kAXTitleAttribute)
                    if matches(id, desc) { return element }
                }
                queue.append(contentsOf: MenuBarInspector.children(element))
            }
        }
        return nil
    }

    private static func findInWindows(where matches: (AXUIElement) -> Bool) -> AXUIElement? {
        var found: AXUIElement?
        forEachWindowElement { element in
            if found == nil && matches(element) { found = element }
        }
        return found
    }

    /// Visits every element in the windows of the menu bar processes (the panel is one of them).
    private static func forEachWindowElement(_ visit: (AXUIElement) -> Void) {
        for app in applications() {
            guard let windows = MenuBarInspector.copy(app, kAXWindowsAttribute).0 else { continue }
            var queue = MenuBarInspector.elements(from: windows)
            var visited = 0
            while !queue.isEmpty && visited < 1500 {
                let element = queue.removeFirst()
                visited += 1
                visit(element)
                queue.append(contentsOf: MenuBarInspector.children(element))
            }
        }
    }

    private static func applications() -> [AXUIElement] {
        cachedApplications
    }

    private static func label(_ element: AXUIElement) -> String {
        let desc = MenuBarInspector.string(element, kAXDescriptionAttribute)
        return desc.isEmpty ? MenuBarInspector.string(element, kAXTitleAttribute) : desc
    }

    private static func isOn(_ element: AXUIElement) -> Bool {
        MenuBarInspector.string(element, kAXValueAttribute) == "1"
    }
}
