import AppKit
import ApplicationServices

/// Thin, allocation-light wrappers over the AX API.
///
/// Every AX call is synchronous IPC into another process, so the whole design here is:
/// read as little as possible, cache aggressively, and write geometry in one batch.
enum AX {

    // MARK: - attribute reads

    @inline(__always)
    static func copy(_ el: AXUIElement, _ name: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name, &value) == .success else { return nil }
        return value
    }

    static func string(_ el: AXUIElement, _ name: CFString) -> String? {
        copy(el, name) as? String
    }

    static func element(_ el: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attribute, &value) == .success,
              let v = value, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func bool(_ el: AXUIElement, _ name: CFString) -> Bool? {
        (copy(el, name) as? NSNumber)?.boolValue
    }

    static func elements(_ el: AXUIElement, _ name: CFString) -> [AXUIElement]? {
        copy(el, name) as? [AXUIElement]
    }

    static func point(_ el: AXUIElement, _ name: CFString) -> CGPoint? {
        guard let v = copy(el, name), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var out = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &out) ? out : nil
    }

    static func size(_ el: AXUIElement, _ name: CFString) -> CGSize? {
        guard let v = copy(el, name), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var out = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &out) ? out : nil
    }

    // MARK: - attribute writes

    @discardableResult
    static func setPosition(_ el: AXUIElement, _ p: CGPoint) -> Bool {
        var p = p
        guard let v = AXValueCreate(.cgPoint, &p) else { return false }
        return AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, v) == .success
    }

    @discardableResult
    static func setSize(_ el: AXUIElement, _ s: CGSize) -> Bool {
        var s = s
        guard let v = AXValueCreate(.cgSize, &s) else { return false }
        return AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, v) == .success
    }

    /// Bring a window to the front of its app's window stack without activating the app.
    static func raise(_ el: AXUIElement) {
        AXUIElementPerformAction(el, kAXRaiseAction as CFString)
    }

    @discardableResult
    static func setBool(_ el: AXUIElement, _ name: CFString, _ value: Bool) -> Bool {
        AXUIElementSetAttributeValue(el, name, value as CFBoolean) == .success
    }

    /// Position then size, in that order, because a window whose new size would push it
    /// past the screen edge gets clamped if you resize first.
    ///
    /// Some apps (notably ones with their own layout engines) only accept one order, so if the
    /// first attempt doesn't take, the opposite order is tried once before giving up.
    static func setFrame(_ el: AXUIElement, _ frame: CGRect) {
        setPosition(el, frame.origin)
        setSize(el, frame.size)
        if let actual = currentFrame(el), actual != frame {
            setSize(el, frame.size)
            setPosition(el, frame.origin)
        }
    }

    // MARK: - windows

    static func appElement(_ pid: pid_t) -> AXUIElement {
        AXUIElementCreateApplication(pid)
    }

    /// Standard, visible, resizable-ish windows of one app.
    ///
    /// Filtering happens once per refresh instead of per layout pass, because the only expensive
    /// part is crossing the process boundary — and that we cannot avoid, only amortise.
    static func windows(of pid: pid_t) -> [AXUIElement] {
        let app = appElement(pid)
        guard let raw = elements(app, kAXWindowsAttribute as CFString) else { return [] }
        var out: [AXUIElement] = []
        out.reserveCapacity(raw.count)
        for w in raw {
            guard let role = string(w, kAXRoleAttribute as CFString), role == kAXWindowRole as String else { continue }
            if let sub = string(w, kAXSubroleAttribute as CFString),
               sub != kAXStandardWindowSubrole as String {
                continue
            }
            if bool(w, kAXMinimizedAttribute as CFString) == true { continue }
            // A window we cannot move is a window we should not tile.
            var settable: DarwinBoolean = false
            if AXUIElementIsAttributeSettable(w, kAXPositionAttribute as CFString, &settable) == .success,
               !settable.boolValue { continue }
            out.append(w)
        }
        return out
    }

    static func title(_ el: AXUIElement) -> String {
        string(el, kAXTitleAttribute as CFString) ?? ""
    }

    static func isMinimized(_ el: AXUIElement) -> Bool {
        bool(el, kAXMinimizedAttribute as CFString) ?? false
    }

    /// Native full-screen detection.
    ///
    /// A full-screen window is a trap for a tiling WM: macOS moves it to its own Space, so writing
    /// geometry to it either does nothing or drags the user out of full screen. Such windows are
    /// left completely alone.
    ///
    /// This deliberately trusts the `AXFullScreen` attribute and *not* geometry. An earlier version
    /// also excluded anything sitting above the menu bar, which wrongly excluded ordinary windows
    /// that happened to open at y = 0 — they then floated over the tiled panes as apparent overlaps.
    /// Geometry is still used as a safety check before *parking* (see Controller.parkOtherWorkspaces).
    static func isFullScreen(_ el: AXUIElement) -> Bool {
        bool(el, "AXFullScreen" as CFString) ?? false
    }

    /// True when the window covers the entire screen, menu bar included. Used only to decide
    /// whether it is safe to move a window off-screen — never to decide whether to manage it.
    static func coversWholeScreen(_ el: AXUIElement, screen: CGRect) -> Bool {
        guard let frame = currentFrame(el) else { return false }
        return frame.width >= screen.width - 1 && frame.height >= screen.height - 1
    }

    static func currentFrame(_ el: AXUIElement) -> CGRect? {
        guard let p = point(el, kAXPositionAttribute as CFString),
              let s = size(el, kAXSizeAttribute as CFString) else { return nil }
        return CGRect(origin: p, size: s)
    }

}
