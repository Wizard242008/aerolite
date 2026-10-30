import AppKit

// Development hooks, driven from outside the process with `notifyutil`. None of this runs unless
// something posts one of the notifications, so it costs nothing in normal use.

extension Controller {

    func installDebugHooks() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer: CFNotificationCallback = { _, _, name, _, _ in
            guard let raw = name?.rawValue as String? else { return }
            DispatchQueue.main.async {
                guard let controller = Controller.shared else { return }
                if raw.hasSuffix(".dump") { controller.dumpState() }
                if raw.hasSuffix(".retile") { controller.refresh() }
                if raw.hasSuffix(".cmd") { controller.runCommandFromFile() }
            }
        }
        CFNotificationCenterAddObserver(center, nil, observer,
                                        "com.devansh.pulsar.dump" as CFString, nil, .deliverImmediately)
        CFNotificationCenterAddObserver(center, nil, observer,
                                        "com.devansh.pulsar.retile" as CFString, nil, .deliverImmediately)
        // Darwin notifications carry no payload, so the command travels in a file and this is the
        // trigger. Registered under one fixed name — observing all notifications system-wide would
        // wake the app for unrelated traffic and defeat the point of an idle-free WM.
        CFNotificationCenterAddObserver(center, nil, observer,
                                        "com.devansh.pulsar.cmd" as CFString, nil, .deliverImmediately)
    }

    var commandFileURL: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/Pulsar.cmd")
    }

    func runCommandFromFile() {
        let url = commandFileURL
        guard let command = try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else { return }
        try? FileManager.default.removeItem(at: url)
        log("debug command: \(command)")
        runDebugCommand(command)
    }

    /// Drive the WM from outside for testing: `notifyutil -p com.devansh.pulsar.cmd.ws-2`.
    /// Commands: ws-<name>, move-<name>, focus-<dir>, orient, dump.
    /// Try every known way of hiding a window and report which one the window server accepts.
    /// macOS clamps window positions to keep a sliver on screen, so "park at -30000" silently
    /// becomes "park at -800" — visible to the user and useless as a hide.
    func parkProbe() {
        guard let win = store.windows(store.current).first else { log("parkProbe: no window"); return }
        let app = win.app.localizedName ?? "?"
        guard let original = AX.currentFrame(win.el) else { return }
        log("parkProbe on \(app) \(Int(original.width))x\(Int(original.height))")

        func report(_ label: String) {
            let f = AX.currentFrame(win.el) ?? .zero
            log("  \(label): x=\(Int(f.minX)) y=\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))")
        }

        AX.setPosition(win.el, CGPoint(x: -30000, y: 0)); report("x=-30000")
        AX.setPosition(win.el, CGPoint(x: 0, y: 3000));  report("y=+3000")
        AX.setPosition(win.el, CGPoint(x: -30000, y: 3000)); report("both")
        AX.setSize(win.el, CGSize(width: 1, height: 1)); report("size 1x1")
        AX.setSize(win.el, CGSize(width: original.width, height: original.height))
        AX.setPosition(win.el, original.origin)
        AX.setBool(win.el, kAXMinimizedAttribute as CFString, true); report("minimized")
        AX.setBool(win.el, kAXMinimizedAttribute as CFString, false); report("restored")
        let v = axVisibleFrame
        AX.setPosition(win.el, CGPoint(x: v.minX - original.width + 1, y: v.maxY - 1)); report("corner park")
        AX.setPosition(win.el, original.origin)
        log("parkProbe done")
    }

    func runDebugCommand(_ command: String) {
        // Single-word commands never reach the verb-argument split below.
        if command == "drag" {
            guard let win = focused(), let f = AX.currentFrame(win.el) else { return }
            let newWidth = max(f.width * 1.45, 200)
            AX.setSize(win.el, CGSize(width: newWidth, height: f.height))
            log("drag: forced width \(Int(f.width)) -> \(Int(newWidth)), cached frame left stale")
            return
        }
        if command == "orient" { toggleOrientation(); return }
        if command == "axraw" {
            // What the Accessibility layer really returns, before any filtering: used to tell a
            // window the manager refuses from a window the system never offered.
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
                let el = AXUIElementCreateApplication(app.processIdentifier)
                var value: CFTypeRef?
                let err = AXUIElementCopyAttributeValue(el, kAXWindowsAttribute as CFString, &value)
                let list = value as? [AXUIElement] ?? []
                if list.isEmpty && err != .success { continue }
                log("axraw \(app.localizedName ?? "?") pid=\(app.processIdentifier) count=\(list.count) err=\(err.rawValue)")
                for w in list {
                    func attr(_ name: String) -> String {
                        var v: CFTypeRef?
                        AXUIElementCopyAttributeValue(w, name as CFString, &v)
                        if let s = v as? String { return s }
                        if let n = v as? NSNumber { return n.stringValue }
                        return "nil"
                    }
                    var settable: DarwinBoolean = false
                    AXUIElementIsAttributeSettable(w, kAXPositionAttribute as CFString, &settable)
                    log("    role=\(attr(kAXRoleAttribute)) sub=\(attr(kAXSubroleAttribute)) min=\(attr(kAXMinimizedAttribute)) movable=\(settable.boolValue) title=\(attr(kAXTitleAttribute))")
                }
            }
            return
        }
        if command == "menudump" {
            guard let menu = statusItem?.menu else { log("menudump: no menu"); return }
            rebuildMenu()
            func walk(_ menu: NSMenu, depth: Int) {
                for item in menu.items {
                    let mods = item.keyEquivalentModifierMask
                    var glyphs = ""
                    if mods.contains(.control) { glyphs += "^" }
                    if mods.contains(.option)  { glyphs += "~" }
                    if mods.contains(.shift)   { glyphs += "S" }
                    if mods.contains(.command) { glyphs += "@" }
                    let key = item.keyEquivalent.isEmpty ? "" : " [\(glyphs)\(item.keyEquivalent)]"
                    log("  \(String(repeating: "  ", count: depth))\(item.title)\(key)")
                    if let sub = item.submenu { walk(sub, depth: depth + 1) }
                }
            }
            walk(menu, depth: 0)
            return
        }
        if command == "dump" { dumpState(); return }
        if command == "settings" { showSettings(); return }
        if command == "about" { showAboutPanel(); return }
        if command == "menu" {
            // Opens the status-item menu for screenshots. Enters menu tracking, so this call does
            // not return until the menu is dismissed.
            statusItem?.button?.performClick(nil)
            return
        }
        if command == "updateinstall" {
            Updater.check { result in
                guard case .available(let release) = result else {
                    log("updateinstall: nothing available")
                    return
                }
                log("updateinstall: installing \(release.version)")
                Updater.install(release) { error in
                    if let error { log("updateinstall failed: \(error)") }
                    else {
                        log("updateinstall: handing off to the swap script, quitting")
                        NSApp.terminate(nil)
                    }
                }
            }
            return
        }
        if command == "updatecheck" {
            Updater.check { result in
                switch result {
                case .upToDate(let v):  log("update check: up to date (\(v))")
                case .available(let r): log("update check: \(r.version) available, dmg=\(r.dmgURL != nil), notes=\(r.notes.count) chars")
                case .failed(let m):    log("update check failed: \(m)")
                }
            }
            return
        }
        if command == "help" { showHelp(); return }
        if command == "hoveron" {
            focusFollowsMouse = true
            UserDefaults.standard.set(true, forKey: "focusFollowsMouse")
            log("focus follows mouse: on")
            return
        }
        if command == "hoveroff" {
            focusFollowsMouse = false
            UserDefaults.standard.set(false, forKey: "focusFollowsMouse")
            log("focus follows mouse: off")
            return
        }
        if command == "hover" {
            // Warp the pointer over the second window and post a real mouseMoved event, so the
            // global monitor is exercised exactly as it would be by a hand on the trackpad.
            guard let screen = NSScreen.screens.first else { return }
            let windows = store.windows(store.current)
            guard windows.count > 1 else { log("hover: need 2+ windows"); return }
            let target = windows[1]
            let ax = CGPoint(x: target.frame.midX, y: target.frame.midY)
            let point = CGPoint(x: ax.x, y: screen.frame.height - ax.y)
            CGWarpMouseCursorPosition(point)
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                    mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            log("hover: pointer over \(target.title.prefix(24))")
            return
        }

        let parts = command.split(separator: "-", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            if command == "orient" { toggleOrientation() }
            return
        }
        let (verb, arg) = (parts[0], parts[1])
        switch verb {
        case "probe": parkProbe()
        case "ws":    switchWorkspace(arg)
        case "move":  moveToWorkspace(arg)
        case "focus":
            switch arg {
            case "left": focus(.left); case "right": focus(.right)
            case "up": focus(.up); case "down": focus(.down)
            default: break
            }
        default: break
        }
    }

    /// Print every AX window per app: subrole, title, frame, and whether we track it.
    /// This is the ground truth for "why is that window not tiled?".
    func dumpState() {
        log("=== DUMP ws=\(store.current) orientation=\(store.orientation) "
            + "tracked=\(store.byHash.count) trusted=\(AXIsProcessTrusted())")
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let pid = app.processIdentifier
            let wins = AX.windows(of: pid)
            guard !wins.isEmpty else { continue }
            log("  app \(app.localizedName ?? "?") pid=\(pid) axWindows=\(wins.count)")
            for el in wins {
                let title = AX.string(el, kAXTitleAttribute as CFString) ?? ""
                let sub = AX.string(el, kAXSubroleAttribute as CFString) ?? "(no subrole)"
                let f = AX.currentFrame(el) ?? .zero
                let tracked = store.byHash[CFHash(el)] != nil
                let focused = AX.bool(el, kAXFocusedAttribute as CFString) ?? false
                log("    [\(sub)] \"\(title.prefix(36))\" "
                    + "\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height)) "
                    + "tracked=\(tracked)" + (focused ? " FOCUSED" : ""))
            }
        }
        log("=== END DUMP")
    }

    /// Ask for Accessibility, and — if it isn't granted yet — watch for it briefly.
    ///
    /// The watcher is deliberately bounded: once a second for one minute, then it stops forever.
    /// A permanent poll would undo the whole point of an idle-free window manager.
}
