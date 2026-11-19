import AppKit
import CoreGraphics

/// Turns remote commands into real mouse / keyboard / media-key events on this Mac.
/// Requires Accessibility permission (System Settings → Privacy & Security → Accessibility).
final class InputController {
    private let source = CGEventSource(stateID: .hidSystemState)

    private var leftDown = false
    private var rightDown = false

    // Double/triple-click tracking.
    private var clickState: Int64 = 1
    private var lastDownTime: TimeInterval = 0
    private var lastDownButton: CGMouseButton = .left
    private var lastDownPoint: CGPoint = .zero

    // Sub-pixel scroll amounts that haven't been sent yet.
    private var scrollRemainder = CGPoint.zero

    // While the phone is streaming movement we track the pointer ourselves: asking macOS for the
    // cursor position right after posting an event returns a slightly stale value, which loses
    // movement and makes the pointer feel sluggish. After a short pause we re-sync with the real
    // position, so using the Mac's own trackpad in between still works.
    private var virtualCursor: CGPoint?
    private var lastMoveTime: TimeInterval = 0
    private let resyncAfter: TimeInterval = 0.25

    private var cursor: CGPoint {
        if let virtualCursor, ProcessInfo.processInfo.systemUptime - lastMoveTime < resyncAfter {
            return virtualCursor
        }
        return CGEvent(source: nil)?.location ?? .zero
    }

    // Display bounds are cached briefly instead of being queried for every movement.
    private var displayRects: [CGRect] = []
    private var displayRectsTime: TimeInterval = -1

    // MARK: Mouse

    func move(dx: Double, dy: Double) {
        let current = cursor
        let target = clampToDisplays(CGPoint(x: current.x + dx, y: current.y + dy))
        virtualCursor = target
        lastMoveTime = ProcessInfo.processInfo.systemUptime
        let type: CGEventType
        let button: CGMouseButton
        if leftDown {
            type = .leftMouseDragged; button = .left
        } else if rightDown {
            type = .rightMouseDragged; button = .right
        } else {
            type = .mouseMoved; button = .left
        }
        guard let e = CGEvent(mouseEventSource: source, mouseType: type,
                              mouseCursorPosition: target, mouseButton: button) else { return }
        e.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx.rounded()))
        e.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy.rounded()))
        e.post(tap: .cghidEventTap)
    }

    func mouseDown(right: Bool) {
        let button: CGMouseButton = right ? .right : .left
        let p = cursor
        let now = ProcessInfo.processInfo.systemUptime
        let closeEnough = hypot(p.x - lastDownPoint.x, p.y - lastDownPoint.y) < 6
        if button == lastDownButton && now - lastDownTime < NSEvent.doubleClickInterval && closeEnough {
            clickState = min(clickState + 1, 3)
        } else {
            clickState = 1
        }
        lastDownTime = now
        lastDownButton = button
        lastDownPoint = p

        postMouse(right ? .rightMouseDown : .leftMouseDown, at: p, button: button)
        if right { rightDown = true } else { leftDown = true }
    }

    func mouseUp(right: Bool) {
        if right {
            guard rightDown else { return }
            rightDown = false
            postMouse(.rightMouseUp, at: cursor, button: .right)
        } else {
            guard leftDown else { return }
            leftDown = false
            postMouse(.leftMouseUp, at: cursor, button: .left)
        }
    }

    func click(right: Bool) {
        mouseDown(right: right)
        mouseUp(right: right)
    }

    /// A real double-click (click state 1 then 2), e.g. to open a file.
    func doubleClick() {
        releaseAll()
        let p = cursor
        for state: Int64 in [1, 2] {
            clickState = state
            postMouse(.leftMouseDown, at: p, button: .left)
            postMouse(.leftMouseUp, at: p, button: .left)
        }
        // A click right after this counts as a triple-click, like on a real trackpad.
        lastDownTime = ProcessInfo.processInfo.systemUptime
        lastDownButton = .left
        lastDownPoint = p
    }

    func releaseAll() {
        mouseUp(right: false)
        mouseUp(right: true)
    }

    func scroll(dx: Double, dy: Double) {
        scrollRemainder.x += dx
        scrollRemainder.y += dy
        let sx = Int32(scrollRemainder.x.rounded(.towardZero))
        let sy = Int32(scrollRemainder.y.rounded(.towardZero))
        guard sx != 0 || sy != 0 else { return }
        scrollRemainder.x -= Double(sx)
        scrollRemainder.y -= Double(sy)
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                              wheelCount: 2, wheel1: sy, wheel2: sx, wheel3: 0) else { return }
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.post(tap: .cghidEventTap)
    }

    private func postMouse(_ type: CGEventType, at p: CGPoint, button: CGMouseButton) {
        guard let e = CGEvent(mouseEventSource: source, mouseType: type,
                              mouseCursorPosition: p, mouseButton: button) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: clickState)
        e.post(tap: .cghidEventTap)
    }

    private func currentDisplayRects() -> [CGRect] {
        let now = ProcessInfo.processInfo.systemUptime
        if now - displayRectsTime < 2, !displayRects.isEmpty { return displayRects }
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        if count > 0 { CGGetActiveDisplayList(count, &ids, &count) }
        displayRects = ids.prefix(Int(count)).map { CGDisplayBounds($0) }
        displayRectsTime = now
        return displayRects
    }

    private func clampToDisplays(_ p: CGPoint) -> CGPoint {
        let rects = currentDisplayRects()
        guard !rects.isEmpty else { return p }
        if rects.contains(where: { $0.contains(p) }) { return p }

        var best = p
        var bestDistance = CGFloat.infinity
        for r in rects {
            let c = CGPoint(x: min(max(p.x, r.minX), r.maxX - 1),
                            y: min(max(p.y, r.minY), r.maxY - 1))
            let d = hypot(c.x - p.x, c.y - p.y)
            if d < bestDistance { bestDistance = d; best = c }
        }
        return best
    }

    // MARK: Keyboard

    /// Types arbitrary text (any language / emoji) using unicode keyboard events.
    func type(_ text: String) {
        for ch in text {
            switch ch {
            case "\n", "\r", "\r\n": tap(keyCode: 36, flags: [])
            case "\t": tap(keyCode: 48, flags: [])
            default:
                let utf16 = Array(String(ch).utf16)
                for down in [true, false] {
                    guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                    e.flags = []
                    utf16.withUnsafeBufferPointer { buf in
                        e.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
                    }
                    e.post(tap: .cghidEventTap)
                }
            }
        }
    }

    /// Presses a named key (see `keyCodes`) with optional modifiers, e.g. key("c", ["cmd"]).
    func key(_ name: String, modifiers: [String]) {
        let lower = name.lowercased()
        guard let code = Self.keyCodes[lower] else {
            Log.write("Unknown key: \(name)")
            return
        }
        var flags: CGEventFlags = []
        for m in modifiers {
            switch m.lowercased() {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "alt", "option", "opt": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            case "fn": flags.insert(.maskSecondaryFn)
            default: break
            }
        }
        if Self.arrowKeys.contains(lower) {
            flags.insert(.maskNumericPad)
            flags.insert(.maskSecondaryFn)
        } else if Self.fnKeys.contains(lower) {
            flags.insert(.maskSecondaryFn)
        }
        tap(keyCode: code, flags: flags)
    }

    private func tap(keyCode: CGKeyCode, flags: CGEventFlags) {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { continue }
            e.flags = flags
            e.post(tap: .cghidEventTap)
        }
    }

    private static let arrowKeys: Set<String> = ["left", "right", "up", "down"]
    private static let fnKeys: Set<String> = ["home", "end", "pageup", "pagedown", "forwarddelete",
                                              "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12"]

    // macOS virtual key codes (US layout positions).
    static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
        "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47, "`": 50,
        "return": 36, "enter": 36, "tab": 48, "space": 49, " ": 49,
        "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]

    // MARK: Media keys (volume, brightness, playback)

    private static let mediaKeys: [String: Int] = [
        "volup": 0,        // NX_KEYTYPE_SOUND_UP
        "voldown": 1,      // NX_KEYTYPE_SOUND_DOWN
        "brightup": 2,     // NX_KEYTYPE_BRIGHTNESS_UP
        "brightdown": 3,   // NX_KEYTYPE_BRIGHTNESS_DOWN
        "mute": 7,         // NX_KEYTYPE_MUTE
        "play": 16,        // NX_KEYTYPE_PLAY
        "next": 17,        // NX_KEYTYPE_NEXT
        "prev": 18,        // NX_KEYTYPE_PREVIOUS
    ]

    func media(_ name: String) {
        guard let key = Self.mediaKeys[name] else {
            Log.write("Unknown media key: \(name)")
            return
        }
        postSystemKey(key, down: true)
        postSystemKey(key, down: false)
    }

    private func postSystemKey(_ key: Int, down: Bool) {
        let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
        let data1 = (key << 16) | ((down ? 0xa : 0xb) << 8)
        guard let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags,
                                             timestamp: 0, windowNumber: 0, context: nil,
                                             subtype: 8, data1: data1, data2: -1) else { return }
        event.cgEvent?.post(tap: .cghidEventTap)
    }
}
