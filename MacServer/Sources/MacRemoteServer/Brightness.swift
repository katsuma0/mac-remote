import CoreGraphics
import Foundation

/// Reads and sets the built-in display's brightness (0–1).
///
/// macOS has no public API for this, so we use DisplayServices – the private framework the
/// brightness keys and Control Center slider use. It's loaded at runtime: if it's missing on some
/// macOS version, `isSupported` is false and the phone shows that instead of crashing.
/// External monitors aren't supported (they need DDC over the cable).
#if APP_STORE
/// App Store build: private frameworks aren't allowed, so there's no brightness slider.
/// The phone shows brightness −/+ buttons instead (the brightness keys work everywhere).
enum Brightness {
    static var isSupported: Bool { false }
    static func current() -> Double? { nil }
    @discardableResult
    static func set(_ value: Double) -> Bool { false }
}
#else
enum Brightness {
    private typealias GetFunction = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFunction = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let framework = dlopen(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)

    private static let getFunction: GetFunction? = {
        guard let framework, let symbol = dlsym(framework, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(symbol, to: GetFunction.self)
    }()

    private static let setFunction: SetFunction? = {
        guard let framework, let symbol = dlsym(framework, "DisplayServicesSetBrightness") else { return nil }
        return unsafeBitCast(symbol, to: SetFunction.self)
    }()

    /// The built-in screen, or the main display if there isn't one.
    private static var display: CGDirectDisplayID {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        if count > 0 { CGGetActiveDisplayList(count, &ids, &count) }
        return ids.first(where: { CGDisplayIsBuiltin($0) != 0 }) ?? CGMainDisplayID()
    }

    static var isSupported: Bool { current() != nil }

    /// Current brightness 0–1, or nil if it can't be read.
    static func current() -> Double? {
        guard let getFunction else { return nil }
        var value: Float = 0
        guard getFunction(display, &value) == 0 else { return nil }
        return Double(value)
    }

    /// Sets brightness 0–1. Returns false if it isn't supported on this Mac/display.
    @discardableResult
    static func set(_ value: Double) -> Bool {
        guard let setFunction else { return false }
        let clamped = Float(max(0, min(1, value)))
        return setFunction(display, clamped) == 0
    }
}
#endif
