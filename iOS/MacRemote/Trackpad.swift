import SwiftUI
import UIKit

/// Raw multi-touch surface that behaves like a Mac trackpad:
/// - 1 finger: move pointer (with acceleration)
/// - tap: left click, two-finger tap: right click
/// - 2 fingers: scroll
/// - touch & hold, then move: drag
final class TrackpadUIView: UIView {
    var pointerSpeed: CGFloat = 1.5
    var scrollSpeed: CGFloat = 1
    var invertScroll = false
    var hapticsEnabled = true

    var onMove: ((Double, Double) -> Void)?
    var onScroll: ((Double, Double) -> Void)?
    var onClick: ((_ right: Bool) -> Void)?
    var onDragStart: (() -> Void)?
    var onDragEnd: (() -> Void)?

    private var touchesDown = Set<UITouch>()
    private var gestureStartTime: TimeInterval = 0
    private var maxTouchCount = 0
    private var travel: CGFloat = 0
    private var lastCentroid: CGPoint?
    private var lastTimestamp: TimeInterval = 0
    private var dragging = false
    private var holdTimer: Timer?

    private let tapFeedback = UIImpactFeedbackGenerator(style: .light)
    private let holdFeedback = UIImpactFeedbackGenerator(style: .medium)

    private let tapMaxDuration: TimeInterval = 0.3
    private let tapMaxTravel: CGFloat = 10
    private let holdDelay: TimeInterval = 0.45

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func centroid() -> CGPoint? {
        guard !touchesDown.isEmpty else { return nil }
        var x: CGFloat = 0, y: CGFloat = 0
        for touch in touchesDown {
            let p = touch.location(in: self)
            x += p.x
            y += p.y
        }
        let n = CGFloat(touchesDown.count)
        return CGPoint(x: x / n, y: y / n)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let now = event?.timestamp ?? ProcessInfo.processInfo.systemUptime
        if touchesDown.isEmpty {
            gestureStartTime = now
            maxTouchCount = 0
            travel = 0
            dragging = false
            tapFeedback.prepare()
            startHoldTimer()
        }
        touchesDown.formUnion(touches)
        maxTouchCount = max(maxTouchCount, touchesDown.count)
        if touchesDown.count > 1 && !dragging { cancelHoldTimer() }
        lastCentroid = centroid()          // reset so adding a finger doesn't make the pointer jump
        lastTimestamp = now
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let c = centroid(), let last = lastCentroid else { return }
        let now = event?.timestamp ?? ProcessInfo.processInfo.systemUptime
        let dt = max(now - lastTimestamp, 1.0 / 240.0)
        let dx = c.x - last.x
        let dy = c.y - last.y
        lastCentroid = c
        lastTimestamp = now

        let distance = hypot(dx, dy)
        travel += distance
        if travel > tapMaxTravel && !dragging { cancelHoldTimer() }

        if dragging || maxTouchCount == 1 {
            // Pointer acceleration: slow movements are precise, fast flicks cover the screen.
            let speed = distance / CGFloat(dt)              // points per second
            let acceleration = min(1 + speed / 700, 3.5)
            let gain = pointerSpeed * acceleration
            onMove?(Double(dx * gain), Double(dy * gain))
        } else if touchesDown.count >= 2 {
            let sign: CGFloat = invertScroll ? -1 : 1
            let gain = 2.5 * scrollSpeed * sign
            onScroll?(Double(dx * gain), Double(dy * gain))
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        endTouches(touches, event: event, cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        endTouches(touches, event: event, cancelled: true)
    }

    private func endTouches(_ touches: Set<UITouch>, event: UIEvent?, cancelled: Bool) {
        touchesDown.subtract(touches)
        guard touchesDown.isEmpty else {
            lastCentroid = centroid()
            return
        }
        cancelHoldTimer()
        let now = event?.timestamp ?? ProcessInfo.processInfo.systemUptime
        if dragging {
            dragging = false
            onDragEnd?()
        } else if !cancelled && now - gestureStartTime < tapMaxDuration && travel < tapMaxTravel {
            onClick?(maxTouchCount >= 2)
            if hapticsEnabled { tapFeedback.impactOccurred() }
        }
        lastCentroid = nil
    }

    private func startHoldTimer() {
        cancelHoldTimer()
        holdTimer = Timer.scheduledTimer(withTimeInterval: holdDelay, repeats: false) { [weak self] _ in
            guard let self, self.touchesDown.count == 1, self.travel < self.tapMaxTravel else { return }
            self.dragging = true
            if self.hapticsEnabled { self.holdFeedback.impactOccurred() }
            self.onDragStart?()
        }
    }

    private func cancelHoldTimer() {
        holdTimer?.invalidate()
        holdTimer = nil
    }
}

struct TrackpadSurface: UIViewRepresentable {
    let remote: RemoteConnection
    var pointerSpeed: Double
    var scrollSpeed: Double
    var invertScroll: Bool
    var haptics: Bool

    func makeUIView(context: Context) -> TrackpadUIView {
        TrackpadUIView()
    }

    func updateUIView(_ view: TrackpadUIView, context: Context) {
        let remote = self.remote
        view.pointerSpeed = CGFloat(pointerSpeed)
        view.scrollSpeed = CGFloat(scrollSpeed)
        view.invertScroll = invertScroll
        view.hapticsEnabled = haptics
        view.onMove = { remote.move(dx: $0, dy: $1) }
        view.onScroll = { remote.scroll(dx: $0, dy: $1) }
        view.onClick = { remote.click(right: $0) }
        view.onDragStart = { remote.mouseDown() }
        view.onDragEnd = { remote.mouseUp() }
    }
}

/// A big mouse button. Press and hold it while moving on the trackpad with another finger to drag.
struct MouseButtonView: View {
    @EnvironmentObject var remote: RemoteConnection
    let title: String
    let right: Bool
    let haptics: Bool
    @State private var pressed = false

    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(pressed ? Color.accentColor.opacity(0.35) : Color(.tertiarySystemFill))
            .overlay(Text(title).font(.headline))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed else { return }
                        pressed = true
                        remote.mouseDown(right: right)
                        if haptics { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                    }
                    .onEnded { _ in
                        pressed = false
                        remote.mouseUp(right: right)
                    }
            )
    }
}
