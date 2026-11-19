import AppKit
import ApplicationServices

/// Diagnostic: dumps the menu bar's accessibility tree using the Accessibility API directly
/// (not AppleScript), to find how this macOS version exposes the Screen Mirroring menu.
///
///   swift run -c release MacRemoteServer --dump-menubar             # read only
///   swift run -c release MacRemoteServer --dump-menubar Mirroring   # also press the first item
///                                                                   # whose label contains "Mirroring"
///                                                                   # and dump the panel that opens
enum MenuBarInspector {
    static let processNames = ["MenuBarAgent", "ControlCenter", "SystemUIServer"]

    static func run(pressMatching needle: String?) {
        print("Accessibility trusted: \(AXIsProcessTrusted())\n")
        var pressed = false
        for name in processNames {
            guard let pid = pid(of: name) else {
                print("== \(name): not running\n")
                continue
            }
            print("== \(name) (pid \(pid))")
            let app = AXUIElementCreateApplication(pid)
            print("  attributes: \(attributeNames(app).joined(separator: ", "))")
            for attribute in [kAXExtrasMenuBarAttribute, kAXMenuBarAttribute, kAXWindowsAttribute, kAXChildrenAttribute] {
                let (value, error) = copy(app, attribute)
                guard let value else {
                    print("  \(attribute): <\(describe(error))>")
                    continue
                }
                print("  \(attribute):")
                for element in elements(from: value) {
                    dump(element, depth: 2, maxDepth: 6)
                }
            }
            if let needle, !pressed, let target = findElement(in: app, matching: needle) {
                print("\n  >>> Pressing: \(label(target))")
                let result = AXUIElementPerformAction(target, kAXPressAction as CFString)
                print("  >>> Result: \(describe(result))")
                pressed = true
            }
            print("")
        }

        guard pressed else {
            if needle != nil { print("Nothing matching \"\(needle!)\" was found to press.") }
            return
        }

        // Give the panel time to open and AirPlay devices time to appear, then dump everything again.
        Thread.sleep(forTimeInterval: 2.5)
        print("========== After pressing ==========")
        for name in processNames {
            guard let pid = pid(of: name) else { continue }
            let app = AXUIElementCreateApplication(pid)
            let (value, error) = copy(app, kAXWindowsAttribute)
            print("== \(name) windows:\(value == nil ? " <\(describe(error))>" : "")")
            if let value {
                for window in elements(from: value) {
                    dump(window, depth: 1, maxDepth: 10)
                }
            }
        }
        // Close whatever opened.
        for down in [true, false] {
            CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: down)?.post(tap: .cghidEventTap)
        }
    }

    // MARK: Helpers

    private static func pid(of processName: String) -> pid_t? {
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.executableURL?.lastPathComponent == processName || $0.localizedName == processName
        }) {
            return app.processIdentifier
        }
        // Background agents may not be listed by NSWorkspace; fall back to pgrep.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", processName]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return output.split(separator: "\n").first.flatMap { pid_t($0) }
    }

    private static func copy(_ element: AXUIElement, _ attribute: String) -> (CFTypeRef?, AXError) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return (error == .success ? value : nil, error)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String {
        guard let value = copy(element, attribute).0 else { return "" }
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return ""
    }

    private static func elements(from value: CFTypeRef) -> [AXUIElement] {
        if CFGetTypeID(value) == AXUIElementGetTypeID() {
            return [value as! AXUIElement]
        }
        if let array = value as? [AnyObject] {
            return array.compactMap { item in
                CFGetTypeID(item) == AXUIElementGetTypeID() ? (item as! AXUIElement) : nil
            }
        }
        return []
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        guard let value = copy(element, kAXChildrenAttribute).0 else { return [] }
        return elements(from: value)
    }

    private static func attributeNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    private static func actionNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    private static func label(_ element: AXUIElement) -> String {
        let parts = [
            "role=" + string(element, kAXRoleAttribute),
            "subrole=" + string(element, kAXSubroleAttribute),
            "title=" + string(element, kAXTitleAttribute),
            "desc=" + string(element, kAXDescriptionAttribute),
            "id=" + string(element, kAXIdentifierAttribute),
            "value=" + string(element, kAXValueAttribute),
        ]
        return parts.filter { !$0.hasSuffix("=") }.joined(separator: "  ")
    }

    private static func dump(_ element: AXUIElement, depth: Int, maxDepth: Int) {
        let indent = String(repeating: "  ", count: depth)
        var line = indent + "- " + label(element)
        let actions = actionNames(element)
        if !actions.isEmpty { line += "  actions=" + actions.joined(separator: ",") }
        if label(element).isEmpty {
            line += "  (no readable attributes; has: \(attributeNames(element).joined(separator: ",")))"
        }
        print(line)
        guard depth < maxDepth else { return }
        for child in children(element) {
            dump(child, depth: depth + 1, maxDepth: maxDepth)
        }
    }

    private static func findElement(in app: AXUIElement, matching needle: String) -> AXUIElement? {
        var queue: [AXUIElement] = []
        for attribute in [kAXExtrasMenuBarAttribute, kAXMenuBarAttribute, kAXChildrenAttribute] {
            if let value = copy(app, attribute).0 { queue.append(contentsOf: elements(from: value)) }
        }
        var visited = 0
        while !queue.isEmpty && visited < 2000 {
            let element = queue.removeFirst()
            visited += 1
            let text = [kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute, kAXHelpAttribute]
                .map { string(element, $0) }
                .joined(separator: " ")
            if text.localizedCaseInsensitiveContains(needle) { return element }
            queue.append(contentsOf: children(element))
        }
        return nil
    }

    private static func describe(_ error: AXError) -> String {
        switch error {
        case .success: return "ok"
        case .apiDisabled: return "accessibility API disabled (no permission)"
        case .noValue: return "no value"
        case .attributeUnsupported: return "not supported"
        case .cannotComplete: return "cannot complete (process didn't answer)"
        case .notImplemented: return "not implemented"
        case .invalidUIElement: return "invalid element"
        case .actionUnsupported: return "action unsupported"
        default: return "error \(error.rawValue)"
        }
    }
}
