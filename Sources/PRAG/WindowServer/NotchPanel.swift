import AppKit
import Quartz

/// Borderless, non-activating panel that floats above the menu bar on every Space,
/// including over full-screen apps. It only becomes key when the user clicks inside the
/// open shelf (for Space/⌘A/⌫ shortcuts) and never activates PRAG itself.
final class NotchPanel: NSPanel {
    /// Keyboard + QuickLook handling is forwarded here.
    var keyHandler: ((NSEvent) -> Bool)?
    var canBecomeKeyProvider: (() -> Bool)?
    weak var quickLook: QuickLookCoordinator?

    init(contentRect: CGRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false               // SwiftUI draws a shape-accurate shadow
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
    }

    override var canBecomeKey: Bool { canBecomeKeyProvider?() ?? false }

    override func sendEvent(_ event: NSEvent) {
        // Become key on the mouse-down itself so this click and the next keystroke both land
        // immediately. Non-activating: the app you were in stays frontmost.
        if (event.type == .leftMouseDown || event.type == .rightMouseDown), !isKeyWindow, canBecomeKey {
            makeKey()
        }
        super.sendEvent(event)
    }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }

    // Swallow ⌘A / ⌘C at the window level so they reach our handler even when
    // SwiftUI doesn't have a focused control.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    // Never let AppKit constrain us below the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    // MARK: QuickLook (QLPreviewPanelController informal protocol)

    // QuickLook calls these on the main thread.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { quickLook != nil }
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = quickLook
            panel.delegate = quickLook
            panel.level = NSWindow.Level(rawValue: level.rawValue + 1)
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
    }
}
