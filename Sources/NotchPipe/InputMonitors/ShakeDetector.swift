import Foundation
import CoreGraphics

/// Detects a horizontal "shake" from a stream of cursor samples: N fast direction reversals
/// of the X velocity within a short window. Pure value type — no timers, trivially testable.
struct ShakeDetector {
    var reversalsNeeded = 3
    var window: TimeInterval = 0.45
    /// Minimum peak speed (pt/s) a stroke needs to count.
    var minSpeed: CGFloat = 700
    /// Minimum stroke length (pt) between reversals.
    var minStroke: CGFloat = 22
    var cooldown: TimeInterval = 0.9

    private var lastX: CGFloat?
    private var lastT: TimeInterval = 0
    private var direction: CGFloat = 0
    private var strokeStartX: CGFloat = 0
    private var strokePeakSpeed: CGFloat = 0
    private var reversals: [TimeInterval] = []
    private var lastFire: TimeInterval = -.infinity

    mutating func reset() {
        lastX = nil
        direction = 0
        reversals.removeAll()
        strokePeakSpeed = 0
    }

    /// Feed one sample; returns true exactly when a shake completes.
    mutating func add(x: CGFloat, at t: TimeInterval) -> Bool {
        defer { lastX = x; lastT = t }
        guard let px = lastX else { strokeStartX = x; return false }
        let dt = t - lastT
        guard dt > 0.0005 else { return false }
        let dx = x - px
        guard abs(dx) > 0.25 else { return false }
        let speed = abs(dx) / CGFloat(dt)
        let dir: CGFloat = dx > 0 ? 1 : -1

        if direction == 0 {
            direction = dir
            strokeStartX = px
            strokePeakSpeed = speed
            return false
        }
        if dir == direction {
            strokePeakSpeed = max(strokePeakSpeed, speed)
            return false
        }
        // Direction flipped: was the finished stroke a real flick?
        let stroke = abs(px - strokeStartX)
        if stroke >= minStroke && strokePeakSpeed >= minSpeed {
            reversals.append(t)
        }
        direction = dir
        strokeStartX = px
        strokePeakSpeed = speed
        reversals.removeAll { t - $0 > window }
        if reversals.count >= reversalsNeeded && t - lastFire > cooldown {
            lastFire = t
            reversals.removeAll()
            return true
        }
        return false
    }
}
