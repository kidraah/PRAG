import AppKit

/// All the math for where the shelf lives on one screen. Coordinates are global AppKit
/// screen coordinates (origin bottom-left of the primary display, y up). The shelf always
/// grows from the top centre: out of the camera housing on a notched display, out of a
/// slim dormant pill on any other display.
struct NotchGeometry: Equatable {
    enum Kind: Equatable {
        case notch      // built-in display with a camera housing
        case pill       // any display without a notch
    }

    let displayID: CGDirectDisplayID
    let screenFrame: CGRect
    let kind: Kind
    /// Physical notch footprint (for .notch) or the dormant pill body.
    let notchSize: CGSize
    /// Height of the band at the top of the expanded shelf that sits beside the camera.
    let topBandHeight: CGFloat

    // Visual constants
    static let wingWidth: CGFloat = 34
    /// Body below the top band: tab strip + tray + action bar.
    static let expandedBody = CGSize(width: 660, height: 212)
    static let shadowPad: CGFloat = 28
    static let triggerDistance: CGFloat = 60
    static let peekDistance: CGFloat = 170
    /// Extra depth while the settings page is showing.
    static let settingsExtra: CGFloat = 34

    static func make(for screen: NSScreen) -> NotchGeometry? {
        guard let id = screen.displayID else { return nil }
        let frame = screen.frame
        let top = screen.safeAreaInsets.top
        if top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            // The notch is whatever the two unobscured menu-bar areas leave in between.
            let width = frame.width - left.width - right.width
            return NotchGeometry(displayID: id, screenFrame: frame, kind: .notch,
                                 notchSize: CGSize(width: width, height: top), topBandHeight: top)
        }
        let menuBar = frame.maxY - screen.visibleFrame.maxY
        return NotchGeometry(displayID: id, screenFrame: frame, kind: .pill,
                             notchSize: CGSize(width: 132, height: 6),
                             topBandHeight: max(menuBar, 28))
    }

    // MARK: Shape sizes (the visible body, including the concave ears)

    /// How far the concave flare extends past the body at the bezel.
    func earRadius(for mode: ShelfMode, hasIndicator: Bool) -> CGFloat {
        switch mode {
        case .collapsed: (kind == .notch && !hasIndicator) ? 0 : 6
        case .peek: 10
        case .expanded: 16
        }
    }

    func bottomRadius(for mode: ShelfMode) -> CGFloat {
        switch mode {
        case .collapsed: kind == .notch ? 10 : 3
        case .peek: 14
        case .expanded: 26
        }
    }

    /// Body size excluding ears.
    func bodySize(for mode: ShelfMode, hasIndicator: Bool, settings: Bool = false) -> CGSize {
        switch (kind, mode) {
        case (.notch, .collapsed):
            let wings = hasIndicator ? Self.wingWidth * 2 : 0
            return CGSize(width: notchSize.width + wings, height: notchSize.height)
        case (.notch, .peek):
            return CGSize(width: notchSize.width + 96, height: notchSize.height + 22)
        case (.pill, .collapsed):
            return hasIndicator ? CGSize(width: 150, height: 8) : notchSize
        case (.pill, .peek):
            return CGSize(width: 240, height: 34)
        case (_, .expanded):
            return CGSize(width: Self.expandedBody.width,
                          height: Self.expandedBody.height + topBandHeight + (settings ? Self.settingsExtra : 0))
        }
    }

    /// Full shape size (ears add to the width).
    func shapeSize(for mode: ShelfMode, hasIndicator: Bool, settings: Bool = false) -> CGSize {
        let body = bodySize(for: mode, hasIndicator: hasIndicator, settings: settings)
        let ear = earRadius(for: mode, hasIndicator: hasIndicator)
        return CGSize(width: body.width + ear * 2, height: body.height)
    }

    /// The largest the shape ever gets — content is laid out once at this size and masked,
    /// so nothing re-flows while the silhouette animates.
    var maxShapeSize: CGSize { shapeSize(for: .expanded, hasIndicator: true, settings: true) }

    // MARK: Frames

    /// Window frame that exactly hugs a shape of the given size (plus shadow room when padded).
    func panelFrame(shapeSize s: CGSize, padded: Bool) -> CGRect {
        let p: CGFloat = padded ? Self.shadowPad : 0
        return CGRect(x: screenFrame.midX - s.width / 2 - p, y: screenFrame.maxY - s.height - p,
                      width: s.width + 2 * p, height: s.height + p)
    }

    /// Collapsed footprint. The panel is click-through while collapsed, so this only needs to
    /// be big enough to draw the notch wings / pill.
    func collapsedFrame(hasIndicator: Bool) -> CGRect {
        var f = panelFrame(shapeSize: shapeSize(for: .collapsed, hasIndicator: hasIndicator), padded: false)
        if kind == .pill {
            f = f.insetBy(dx: -8, dy: 0)
            f.origin.y = screenFrame.maxY - 10
            f.size.height = 10
        }
        return f
    }

    /// Open-state window frame: big enough for the largest shape and its shadow.
    var openFrame: CGRect { panelFrame(shapeSize: maxShapeSize, padded: true) }

    /// The hot target used for hover and drag proximity (the notch / pill body).
    var triggerRect: CGRect {
        var r = panelFrame(shapeSize: shapeSize(for: .collapsed, hasIndicator: false), padded: false)
        if kind == .pill {   // a 6 pt pill is hard to hit: give it a taller invisible strip
            r = r.insetBy(dx: -10, dy: 0)
            r.origin.y = screenFrame.maxY - 8
            r.size.height = 8
        }
        return r
    }

    /// Distance from a point to the trigger rect (0 when inside).
    func distanceToTrigger(_ p: CGPoint) -> CGFloat {
        let r = triggerRect
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
