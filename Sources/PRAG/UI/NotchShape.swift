import SwiftUI

/// The shelf silhouette, growing down from the top edge of the screen.
///
///      ear            body              ear
///   ‾‾‾‾╲_                            _╱‾‾‾‾      ← inverse (concave) ears blend into the bezel
///         |                          |
///          ╲________________________╱            ← soft bottom corners
struct NotchShape: Shape {
    var ear: CGFloat
    var bottom: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(ear, bottom) }
        set { ear = newValue.first; bottom = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let W = rect.width, H = rect.height
        guard W > 0, H > 0 else { return Path() }

        let e = max(0, min(ear, W / 4, H))
        let b = max(0, min(bottom, H - e * 0.5, (W - 2 * e) / 2))

        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        // Left concave ear: curves from the bezel line down into the body wall.
        p.addQuadCurve(to: CGPoint(x: e, y: e), control: CGPoint(x: e, y: 0))
        p.addLine(to: CGPoint(x: e, y: H - b))
        // Bottom-left convex corner (cubic ≈ continuous corner).
        p.addCurve(to: CGPoint(x: e + b, y: H),
                   control1: CGPoint(x: e, y: H - b * 0.45),
                   control2: CGPoint(x: e + b * 0.45, y: H))
        p.addLine(to: CGPoint(x: W - e - b, y: H))
        p.addCurve(to: CGPoint(x: W - e, y: H - b),
                   control1: CGPoint(x: W - e - b * 0.45, y: H),
                   control2: CGPoint(x: W - e, y: H - b * 0.45))
        p.addLine(to: CGPoint(x: W - e, y: e))
        // Right concave ear.
        p.addQuadCurve(to: CGPoint(x: W, y: 0), control: CGPoint(x: W - e, y: 0))
        p.closeSubpath()
        return p.offsetBy(dx: rect.minX, dy: rect.minY)
    }
}
