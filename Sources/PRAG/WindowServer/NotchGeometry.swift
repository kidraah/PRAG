import AppKit

/// Which screen edge the shelf grows out of.
enum ShelfAnchor: Equatable {
    case top, leading, trailing
    var isVertical: Bool { self != .top }
}

/// All the math for where the shelf lives on one screen. Coordinates are global AppKit
/// screen coordinates (origin bottom-left of the primary display, y up).
struct NotchGeometry: Equatable {
    enum Kind: Equatable {
        case notch      // built-in display with a camera housing
        case pill       // external display: dormant pill at top center
        case edge       // external display: tab docked to the left/right edge
    }

    let displayID: CGDirectDisplayID
    let screenFrame: CGRect
    let kind: Kind
    let anchor: ShelfAnchor
    /// Physical notch footprint (for .notch) or the dormant pill/tab body.
    let notchSize: CGSize
    /// Height of the band at the top of the expanded shelf that sits beside the camera.
    let topBandHeight: CGFloat

    // Visual constants
    static let wingWidth: CGFloat = 34
    static let expandedTop = CGSize(width: 660, height: 182)      // body below the notch band
    static let expandedEdge = CGSize(width: 340, height: 480)
    static let shadowPad: CGFloat = 28
    /// Extra depth the top shelf grows by while the settings page is showing.
    static let settingsExtra: CGFloat = 58
    static let triggerDistance: CGFloat = 60
    static let peekDistance: CGFloat = 170

    static func make(for screen: NSScreen, externalStyle: Settings.ExternalDisplayStyle) -> NotchGeometry? {
        guard let id = screen.displayID else { return nil }
        let frame = screen.frame
        let top = screen.safeAreaInsets.top
        if top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            // The notch is whatever the two unobscured menu-bar areas leave in between.
            let width = frame.width - left.width - right.width
            return NotchGeometry(displayID: id, screenFrame: frame, kind: .notch, anchor: .top,
                                 notchSize: CGSize(width: width, height: top), topBandHeight: top)
        }
        let menuBar = frame.maxY - screen.visibleFrame.maxY
        switch externalStyle {
        case .off:
            return nil
        case .topPill:
            return NotchGeometry(displayID: id, screenFrame: frame, kind: .pill, anchor: .top,
                                 notchSize: CGSize(width: 132, height: 6),
                                 topBandHeight: max(menuBar, 24))
        case .leftEdge, .rightEdge:
            return NotchGeometry(displayID: id, screenFrame: frame, kind: .edge,
                                 anchor: externalStyle == .leftEdge ? .leading : .trailing,
                                 notchSize: CGSize(width: 6, height: 96), topBandHeight: 0)
        }
    }

    // MARK: Shape sizes (the visible black/glass body, including the concave ears)

    /// Ear radius: how far the concave flare extends past the body on the anchored edge.
    func earRadius(for mode: ShelfMode, hasIndicator: Bool) -> CGFloat {
        switch mode {
        case .collapsed: return (kind == .notch && !hasIndicator) ? 0 : 6
        case .peek: return 10
        case .expanded: return 16
        }
    }

    func bottomRadius(for mode: ShelfMode) -> CGFloat {
        switch mode {
        case .collapsed: return kind == .notch ? 10 : 3
        case .peek: return 14
        case .expanded: return 26
        }
    }

    /// Body size excluding ears, in the anchor's own orientation (width along the edge).
    func bodySize(for mode: ShelfMode, hasIndicator: Bool) -> CGSize {
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
        case (.edge, .collapsed):
            return hasIndicator ? CGSize(width: 116, height: 8) : CGSize(width: notchSize.height, height: notchSize.width)
        case (.edge, .peek):
            return CGSize(width: 180, height: 30)
        case (.edge, .expanded):
            return CGSize(width: Self.expandedEdge.height, height: Self.expandedEdge.width)
        case (_, .expanded):
            return CGSize(width: Self.expandedTop.width, height: Self.expandedTop.height + topBandHeight)
        }
    }

    /// Full shape size in the anchor's orientation (ears add to the along-edge dimension).
    func shapeSize(for mode: ShelfMode, hasIndicator: Bool, settings: Bool = false) -> CGSize {
        var body = bodySize(for: mode, hasIndicator: hasIndicator)
        if settings && mode == .expanded && anchor == .top { body.height += Self.settingsExtra }
        let ear = earRadius(for: mode, hasIndicator: hasIndicator)
        return CGSize(width: body.width + ear * 2, height: body.height)
    }

    /// Shape size in screen orientation (swapped for vertical edges).
    func screenShapeSize(for mode: ShelfMode, hasIndicator: Bool, settings: Bool = false) -> CGSize {
        let s = shapeSize(for: mode, hasIndicator: hasIndicator, settings: settings)
        return anchor.isVertical ? CGSize(width: s.height, height: s.width) : s
    }

    // MARK: Anchor point

    /// Midpoint of the anchored edge segment where the shelf attaches.
    var anchorPoint: CGPoint {
        switch anchor {
        case .top: CGPoint(x: screenFrame.midX, y: screenFrame.maxY)
        case .leading: CGPoint(x: screenFrame.minX, y: screenFrame.midY)
        case .trailing: CGPoint(x: screenFrame.maxX, y: screenFrame.midY)
        }
    }

    /// Window frame that exactly hugs a shape of the given screen-oriented size,
    /// plus shadow padding on the free sides when `padded`.
    func panelFrame(shapeSize s: CGSize, padded: Bool) -> CGRect {
        let p: CGFloat = padded ? Self.shadowPad : 0
        let a = anchorPoint
        switch anchor {
        case .top:
            return CGRect(x: a.x - s.width / 2 - p, y: a.y - s.height - p, width: s.width + 2 * p, height: s.height + p)
        case .leading:
            return CGRect(x: a.x, y: a.y - s.height / 2 - p, width: s.width + p, height: s.height + 2 * p)
        case .trailing:
            return CGRect(x: a.x - s.width - p, y: a.y - s.height / 2 - p, width: s.width + p, height: s.height + 2 * p)
        }
    }

    /// Collapsed footprint — the ONLY area the panel occupies while collapsed, so it never
    /// steals clicks from neighbouring menu-bar items. A thin pill gets a slightly taller
    /// invisible hover strip so it is reachable.
    func collapsedFrame(hasIndicator: Bool) -> CGRect {
        var f = panelFrame(shapeSize: screenShapeSize(for: .collapsed, hasIndicator: hasIndicator), padded: false)
        switch kind {
        case .notch: break
        case .pill:
            f = f.insetBy(dx: -8, dy: 0)
            f.origin.y = screenFrame.maxY - 10
            f.size.height = 10
        case .edge:
            f.size.width = 10
            if anchor == .trailing { f.origin.x = screenFrame.maxX - 10 }
        }
        return f
    }

    /// Open-state window frame: big enough for the expanded shape and its shadow.
    var openFrame: CGRect {
        panelFrame(shapeSize: screenShapeSize(for: .expanded, hasIndicator: true, settings: true), padded: true)
    }

    /// The hot target used for drag proximity (the notch / pill / tab body).
    var triggerRect: CGRect {
        panelFrame(shapeSize: screenShapeSize(for: .collapsed, hasIndicator: false), padded: false)
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

    var hasNotch: Bool { safeAreaInsets.top > 0 && auxiliaryTopLeftArea != nil }
}
