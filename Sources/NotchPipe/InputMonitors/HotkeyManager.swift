import AppKit
import Carbon.HIToolbox

/// System-wide hotkeys via Carbon's RegisterEventHotKey — works without Accessibility or
/// Input Monitoring permission, unlike global keyDown monitors.
@MainActor
final class HotkeyManager {
    struct Combo: Equatable {
        var keyCode: UInt32
        var modifiers: UInt32   // Carbon modifier mask (cmdKey, shiftKey, …)

        static let commandShiftSpace = Combo(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | shiftKey))

        var display: String {
            var s = ""
            if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
            if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
            if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
            if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
            s += keyCode == UInt32(kVK_Space) ? "Space" : "#\(keyCode)"
            return s
        }
    }

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    private var nextID: UInt32 = 1

    @discardableResult
    func register(_ combo: Combo, handler: @escaping () -> Void) -> Bool {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4E504950), id: id) // 'NPIP'
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            NSLog("NotchPipe: hotkey \(combo.display) unavailable (status \(status)) — another app may own it")
            return false
        }
        refs[id] = ref
        handlers[id] = handler
        return true
    }

    func unregisterAll() {
        refs.values.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        handlers.removeAll()
    }

    fileprivate func fire(_ id: UInt32) {
        handlers[id]?()
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hk = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            guard err == noErr else { return err }
            let id = hk.id
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            // Carbon delivers on the main run loop.
            MainActor.assumeIsolated { manager.fire(id) }
            return noErr
        }, 1, &spec, selfPtr, &eventHandler)
    }
}

/// Asks Finder for its current selection (used by the stash hotkey when Finder is frontmost).
enum FinderSelection {
    @MainActor
    static func selectedURLs() -> [URL] {
        let source = """
        tell application "Finder"
            set out to {}
            repeat with i in (get selection)
                set end of out to POSIX path of (i as alias)
            end repeat
            return out
        end tell
        """
        guard let script = NSAppleScript(source: source) else { return [] }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error { NSLog("NotchPipe: Finder selection failed: \(error)"); return [] }
        var urls: [URL] = []
        if result.numberOfItems == 0, let s = result.stringValue {
            urls.append(URL(fileURLWithPath: s))
        } else if result.numberOfItems > 0 {
            for i in 1...result.numberOfItems {
                if let s = result.atIndex(i)?.stringValue { urls.append(URL(fileURLWithPath: s)) }
            }
        }
        return urls
    }
}
