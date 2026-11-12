import AppKit
import QuartzCore

/// Watches system-wide drags without any special permission:
///  - `NSEvent` global monitors for mouse down/drag/up (no Accessibility prompt needed),
///  - the drag pasteboard's changeCount to tell a real content drag from a window/selection drag,
///  - a 120 Hz sampler that only runs while a content drag is in flight (0% CPU when idle),
///    which feeds proximity, the Shift-hold trigger and the shake detector.
@MainActor
final class DragMonitor {
    var onDragBegan: (() -> Void)?
    var onDragMoved: ((CGPoint) -> Void)?
    var onDragEnded: ((CGPoint) -> Void)?
    var onShiftHold: ((CGPoint) -> Void)?
    var onShake: ((CGPoint) -> Void)?
    /// Any mouse-down anywhere (used for click-outside-to-close).
    var onGlobalMouseDown: ((CGPoint) -> Void)?

    var shiftEnabled = true
    var shakeEnabled = false
    /// How long Shift must be held steady during a drag (spec: 70 ms).
    var shiftHoldDuration: CFTimeInterval = 0.07

    private(set) var isDragActive = false
    private var monitors: [Any] = []
    private var baselineChangeCount = 0
    private var sampler: Timer?
    private var shake = ShakeDetector()
    private var shiftDownAt: CFTimeInterval?
    private var shiftFiredThisPress = false
    private var lastPoint: CGPoint = .zero

    private let dragPasteboard = NSPasteboard(name: .drag)

    func start() {
        guard monitors.isEmpty else { return }
        baselineChangeCount = dragPasteboard.changeCount
        let down = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDown() }
        }
        let drag = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDragged() }
        }
        let up = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            MainActor.assumeIsolated { self?.endDrag() }
        }
        monitors = [down, drag, up].compactMap { $0 }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        endDrag()
    }

    // MARK: Event handlers

    private func mouseDown() {
        baselineChangeCount = dragPasteboard.changeCount
        onGlobalMouseDown?(NSEvent.mouseLocation)
    }

    private func mouseDragged() {
        if !isDragActive {
            // Only a drag that put something on the drag pasteboard counts
            // (ignores window moves, text selection, rubber-band selection…).
            guard dragPasteboard.changeCount != baselineChangeCount else { return }
            beginDrag()
        }
        tick()
    }

    private func beginDrag() {
        isDragActive = true
        shake.reset()
        shiftDownAt = nil
        // Ignore a Shift that was already held when the drag started.
        shiftFiredThisPress = NSEvent.modifierFlags.contains(.shift)
        onDragBegan?()
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.002
        RunLoop.main.add(timer, forMode: .common)
        sampler = timer
    }

    private func endDrag() {
        guard isDragActive else { return }
        isDragActive = false
        sampler?.invalidate()
        sampler = nil
        baselineChangeCount = dragPasteboard.changeCount
        onDragEnded?(NSEvent.mouseLocation)
    }

    /// 120 Hz while dragging. Global drag events stop arriving while the pointer is over our
    /// own panel and can be sparse during system drag sessions, so the sampler carries the load.
    private func tick() {
        guard isDragActive else { return }
        // Mouse released without us seeing the up event (e.g. dropped onto another app).
        if NSEvent.pressedMouseButtons & 1 == 0 {
            endDrag()
            return
        }
        let p = NSEvent.mouseLocation
        let now = CACurrentMediaTime()
        if p != lastPoint {
            lastPoint = p
            onDragMoved?(p)
        }

        if shiftEnabled {
            if NSEvent.modifierFlags.contains(.shift) {
                if shiftDownAt == nil { shiftDownAt = now }
                if !shiftFiredThisPress, let t0 = shiftDownAt, now - t0 >= shiftHoldDuration {
                    shiftFiredThisPress = true
                    onShiftHold?(p)
                }
            } else {
                shiftDownAt = nil
                shiftFiredThisPress = false
            }
        }

        if shakeEnabled, shake.add(x: p.x, at: now) {
            onShake?(p)
        }
    }
}
