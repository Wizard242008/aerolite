import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// The whole window manager.
///
/// Performance rules this file follows, each one a deliberate design choice:
///
/// 1. **No work on idle.** No timers, no polling, no mouse monitors. We wake only for hotkeys and
///    for app lifecycle notifications the system already broadcasts.
/// 2. **Coalesce bursts.** One app activation emits several notifications; they collapse into a
///    single refresh scheduled 25 ms later.
/// 3. **Never write geometry that is already correct.** Every set is diffed against the cached
///    frame first. Re-applying an identical layout costs zero AX writes.
/// 4. **Park once.** Windows on other workspaces are moved off-screen a single time, not on every
///    layout pass.
/// 5. **Refresh only what changed** where possible: the app that activated, not the whole session.
final class Controller: NSObject {

    let store = Store()
    private var pendingRefresh: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    private var refusalsLogged: Set<CFHashCode> = []
    private weak var lastFocused: Win?
    private var saveWork: DispatchWorkItem?
    /// Hyprland-style hover focus. Off by default because it wakes the process on mouse movement.
    var focusFollowsMouse = false { didSet { updateMouseMonitor() } }
    private var mouseMonitor: Any?
    private var hoverWork: DispatchWorkItem?
    private var lastHoverHash: CFHashCode?
    /// When on, activating an app (Dock click, Cmd-Tab) jumps to the workspace holding its window.
    var followAppAcrossWorkspaces = true
    /// Guards persistence against writing an empty map before the first discovery pass finishes.
    private var hasCompletedFirstRefresh = false
    var statusItem: NSStatusItem?
    private var enabledItem: NSMenuItem?
    var enabled = true

    private let parkOrigin = CGPoint(x: -30000, y: 0)
    private let refreshDelay: TimeInterval = 0.025

    // MARK: - screen

    /// Full screen rect in AX coordinates (origin top-left, y down).
    private var axScreenFrame: CGRect {
        guard let screen = NSScreen.screens.first ?? NSScreen.main else {
            return CGRect(x: 0, y: 0, width: 1440, height: 900)
        }
        return screen.frame
    }

    /// Visible screen area expressed in AX coordinates (origin top-left, y down).
    private var axVisibleFrame: CGRect {
        let screen = NSScreen.screens.first ?? NSScreen.main
        guard let screen else { return CGRect(x: 0, y: 0, width: 1440, height: 900) }
        let vf = screen.visibleFrame
        let screenHeight = screen.frame.height
        return CGRect(x: vf.minX,
                      y: screenHeight - vf.maxY,
                      width: vf.width,
                      height: vf.height)
    }

    // MARK: - lifecycle

    func start() {
        Controller.shared = self
        restoreSavedState()
        installDebugHooks()
        requestAccessibility()
        buildMenuBar()
        registerHotkeys()
        updateMouseMonitor()
        observeApps()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.saveState()
        }
        refresh()
        // Launch is the messiest moment: apps are still placing their windows, so a window can
        // look maximised for a few hundred ms. Re-check a few times, then stop for good.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.autoCheckForUpdates()
        }
        for delay in [0.35, 1.0, 2.5, 5.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refresh()
            }
        }
    }

    static weak var shared: Controller?
    private var trustTimer: Timer?

    /// Debug hooks, driven by `notifyutil -p com.devansh.pulsar.<command>`.
    /// A dump prints what this process — and only this process — can see through Accessibility.
    private func installDebugHooks() {
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

    private var commandFileURL: URL {
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
        if command == "settings" { showSettings(); return }
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
    private func requestAccessibility() {
        if AXIsProcessTrusted() { return }

        // Prompt exactly once, ever. Otherwise the system dialog reappears at every launch and
        // login, which trains the user to click through it — and looks like the permission was
        // never remembered even when it was.
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "didPromptForAccessibility") {
            defaults.set(true, forKey: "didPromptForAccessibility")
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }

        log("Accessibility not granted — enable Pulsar in System Settings → Privacy & Security → Accessibility.")
        var ticks = 0
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            ticks += 1
            if AXIsProcessTrusted() {
                timer.invalidate()
                self?.trustTimer = nil
                log("Accessibility granted — tiling enabled.")
                self?.refresh()
            } else if ticks >= 60 {
                timer.invalidate()
                self?.trustTimer = nil
                log("Still untrusted. Enable Pulsar in System Settings → Privacy & Security → Accessibility, then choose “Re-tile now”.")
            }
        }
    }

    // MARK: - hotkeys

    func reRegisterHotkeys() { registerHotkeys() }

    private func registerHotkeys() {
        Hotkeys.shared.unregisterAll()
        let focus: [(Character, Direction)] = [("h", .left), ("l", .right), ("k", .up), ("j", .down)]
        for (c, dir) in focus {
            guard let key = Key.letter(c) else { continue }
            Hotkeys.shared.register(key, modifiers: hotkeyModifier) { [weak self] in
                self?.focus(dir)
            }
            Hotkeys.shared.register(key, modifiers: hotkeyModifier | UInt32(shiftKey)) { [weak self] in
                self?.move(dir)
            }
        }

        Hotkeys.shared.register(.minus, modifiers: hotkeyModifier) { [weak self] in self?.resize(grow: false) }
        Hotkeys.shared.register(.equal, modifiers: hotkeyModifier) { [weak self] in self?.resize(grow: true) }
        Hotkeys.shared.register(.slash, modifiers: hotkeyModifier) { [weak self] in self?.toggleOrientation() }

        // numeric workspaces
        for n in 1...9 {
            guard let key = Key.digit(n) else { continue }
            let name = String(n)
            Hotkeys.shared.register(key, modifiers: hotkeyModifier) { [weak self] in
                self?.switchWorkspace(name)
            }
            Hotkeys.shared.register(key, modifiers: hotkeyModifier | UInt32(shiftKey)) { [weak self] in
                self?.moveToWorkspace(name)
            }
        }

        // letter workspaces, alongside the numeric ones.
        // h/j/k/l are excluded: they are focus/move keys.
        for scalar in Character("a").asciiValue!...Character("z").asciiValue! {
            guard let c = Character(UnicodeScalar(scalar)) as Character?, !"hjkl".contains(c),
                  let key = Key.letter(c) else { continue }
            let name = String(c)
            Hotkeys.shared.register(key, modifiers: hotkeyModifier) { [weak self] in
                self?.switchWorkspace(name)
            }
            Hotkeys.shared.register(key, modifiers: hotkeyModifier | UInt32(shiftKey)) { [weak self] in
                self?.moveToWorkspace(name)
            }
        }
    }

    // MARK: - observation

    private func observeApps() {
        let nc = NSWorkspace.shared.notificationCenter
        let names: [NSNotification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
            // fires when the user swipes into or out of a full-screen Space, so we can
            // stop/ resume managing that window at the right moment
            NSWorkspace.activeSpaceDidChangeNotification,
        ]
        for name in names {
            let token = nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self else { return }
                if name == NSWorkspace.didActivateApplicationNotification,
                   let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                    self.followActivation(app)
                }
                if name == NSWorkspace.didActivateApplicationNotification,
                   let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                    self.refresh(app: app.processIdentifier)
                } else {
                    self.scheduleRefresh()
                }
            }
            observers.append(token)
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.apply()
        }
    }

    /// Collapse a burst of notifications into one refresh.
    func scheduleRefresh() {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + refreshDelay, execute: work)
    }

    // MARK: - refresh (discovery)

    /// Find windows we are not yet tracking and forget the ones that are gone.
    ///
    /// Full-screen windows are deliberately *removed* from management here rather than skipped
    /// later: once a window owns its own Space, any geometry write from us either does nothing or
    /// yanks the user out of full screen.
    /// Full sweep: every running app. Expensive (~25 Accessibility round trips), so it is reserved
    /// for start-up and for apps launching or quitting.
    func refresh() { refresh(only: nil) }

    /// Re-scan a single app. This is what an activation does: the other apps' windows cannot have
    /// changed just because one app came to the front.
    func refresh(app pid: pid_t) { refresh(only: pid) }

    private func refresh(only: pid_t?) {
        let started = CFAbsoluteTimeGetCurrent()
        defer {
            let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
            if ms > 8 { log(String(format: "refresh took %.1f ms", ms)) }
        }
        guard enabled else { return }

        var live = Set<CFHashCode>()
        var discovered: [Win] = []

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  app.processIdentifier != getpid() else { continue }
            let pid = app.processIdentifier
            if let only, only != pid { continue }
            for el in AX.windows(of: pid) {
                let hash = CFHash(el)

                if AX.isFullScreen(el) {
                    // out of scope: never tiled, never parked
                    if let tracked = store.byHash[hash] {
                        store.remove(tracked)
                    }
                    continue
                }

                live.insert(hash)
                if let tracked = store.byHash[hash] {
                    // The window may have been moved or resized behind our back (the app
                    // restoring its own frame, a user drag, a zoom). Re-read the truth here:
                    // trusting a cached frame is what made windows overlap and stay overlapped.
                    if let actual = AX.currentFrame(el) { tracked.frame = actual }
                    if AX.bool(el, kAXFocusedAttribute as CFString) == true { lastFocused = tracked }
                } else if !discovered.contains(where: { $0.hash == hash }) {
                    let win = Win(el: el, pid: pid, app: app, workspace: store.current)
                    win.frame = AX.currentFrame(el) ?? .zero
                    seedMinimum(for: win)
                    // Put the window back where it was last time, not blindly on the current
                    // workspace. This is what makes a restart feel like nothing moved.
                    if let remembered = savedWorkspace(for: win) { win.workspace = remembered }
                    if let weight = savedWeight(for: win) { win.weight = weight }
                    discovered.append(win)
                }
            }
        }

        for win in discovered {
            store.add(win, to: win.workspace)
        }
        if only == nil {
            store.prune(live: live)
            // Parking costs a read per window on other workspaces; only worth re-verifying when the
            // window set may actually have changed.
            parkOtherWorkspaces()
        }
        apply()
        hasCompletedFirstRefresh = true
        scheduleSave()

        let trusted = AXIsProcessTrusted()
        log("refresh ws=\(store.current) tracked=\(store.byHash.count) onScreen=\(live.count) trusted=\(trusted)")
    }

    /// Move every window that is not on the current workspace off-screen.
    ///
    /// Re-checked on each refresh rather than remembered, because apps routinely restore their own
    /// saved frame when reactivated — a one-shot park leaves last desktop's windows sitting on top
    /// of this one.
    private func parkOtherWorkspaces() {
        let currentHashes = Set(store.windows(store.current).map(\.hash))
        let visible = axVisibleFrame

        for (_, win) in store.byHash where !currentHashes.contains(win.hash) {
            let app = win.app.localizedName ?? "?"
            guard let actual = AX.currentFrame(win.el) else { continue }
            if AX.coversWholeScreen(win.el, screen: axScreenFrame) { continue }   // never touch
            if isParked(actual, visible: visible) { continue }

            // Park at the BOTTOM-LEFT corner, not far off to the left.
            //
            // The window server clamps a window to keep a sliver on screen: asking for x = -30000
            // yields x = -(width - ~40), still plainly visible. The way around it is to move the
            // window so its top sits 1 pt past the bottom edge and its right edge 1 pt inside the
            // left edge: the clamp then leaves a single pixel, which is invisible.
            let p = CGPoint(x: visible.minX - actual.width + 1, y: visible.maxY - 1)
            AX.setPosition(win.el, p)

            if let after = AX.currentFrame(win.el), !isParked(after, visible: visible) {
                log("park failed: \(app) still at \(Int(after.minX)),\(Int(after.minY)) "
                    + "\(Int(after.width))x\(Int(after.height))")
            }
        }
    }

    /// Re-derive every weight in the workspace from the sizes the windows actually have.
    ///
    /// This is what makes a manual resize stick. A tiling WM normally recomputes geometry from
    /// weights on every pass, so a divider drag is undone at the next refresh — which feels like
    /// the app "randomly" resetting the split. By folding the current widths back into the weights
    /// before laying out, the ratio the user chose becomes the ratio the layout reproduces.
    ///
    /// Normalising all windows together (rather than scaling the one that moved) keeps the ratio
    /// exact and prevents drift across repeated drags.
    private func adoptExternalSizes(_ wins: [Win]) {
        guard wins.count > 1 else { return }

        var externallyResized = false
        var widths: [CGFloat] = []
        for win in wins {
            guard let actual = AX.currentFrame(win.el) else { widths.append(win.frame.width); continue }
            let widthDelta = abs(actual.width - win.frame.width)
            let heightSame = abs(actual.height - win.frame.height) < 2
            if heightSame && widthDelta > 4 {
                // A window refusing to shrink to its cell is reporting its minimum, not asking to
                // be bigger; that is recorded separately and must not skew the weights.
                let isKnownClamp = actual.width > win.frame.width
                    && (store.minWidth[win.hash].map { abs(actual.width - $0) < 2 } ?? false)
                if !isKnownClamp { externallyResized = true }
            }
            widths.append(actual.width)
        }
        guard externallyResized else { return }

        let smallest = widths.min() ?? 1
        guard smallest > 1 else { return }
        for (win, width) in zip(wins, widths) {
            win.weight = min(max(width / smallest, 0.2), 12)
        }
        log("adopted manual sizes: " + wins.map { "\(Int($0.weight * 100))" }.joined(separator: "/"))
        saveImmediately()
    }

    // MARK: - following the app you just clicked

    /// Jump to the workspace that holds the activated app's window.
    ///
    /// This is what makes the Dock and Cmd-Tab behave: clicking an app that lives on another
    /// desktop takes you there instead of doing nothing because its window is parked off-screen.
    /// It deliberately does nothing when the app is already on the current workspace, which also
    /// stops it from fighting a workspace switch the user just made with a hotkey.
    private func followActivation(_ app: NSRunningApplication) {
        log("activation: \(app.localizedName ?? "?") enabled=\(enabled) follow=\(followAppAcrossWorkspaces)")
        guard enabled, followAppAcrossWorkspaces else { return }
        guard app.processIdentifier != getpid() else { return }

        let appWindows = store.byHash.values.filter { $0.pid == app.processIdentifier }
        log("  app windows: \(appWindows.map { "\($0.workspace)" }.joined(separator: ",")) current=\(store.current)")
        guard !appWindows.isEmpty else { return }        // freshly launched: nothing to follow yet

        // Prefer the window the user last worked in, so a multi-window app lands where they left it.
        let target: Win?
        if let last = lastFocused, last.pid == app.processIdentifier,
           appWindows.contains(where: { $0 === last }) {
            target = last
        } else {
            target = appWindows.first
        }
        guard let window = target else { return }
        guard window.workspace != store.current else { return }

        switchWorkspace(window.workspace)
        setFocus(window)
    }

    // MARK: - focus follows mouse

    /// A global monitor is only installed while the feature is on: with it off, the app must not
    /// wake for mouse movement at all.
    private func updateMouseMonitor() {
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
        guard focusFollowsMouse else { return }

        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.scheduleHoverFocus()
        }
    }

    /// Coalesce movement: crossing three windows in a flick should cost one focus change, not three.
    private func scheduleHoverFocus() {
        hoverWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hoverFocus() }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10, execute: work)
    }

    private func hoverFocus() {
        guard enabled, focusFollowsMouse else { return }
        guard NSEvent.pressedMouseButtons == 0 else { return }   // never steal focus mid-drag
        _ = focusWindowUnderCursor()
    }

    /// Focus the window under the pointer, if it is on the current workspace.
    ///
    /// The layout is non-overlapping, so the pointer can only be inside one pane — the pick is
    /// deterministic and there is no stacking order to reason about.
    @discardableResult
    private func focusWindowUnderCursor() -> Bool {
        guard let screen = NSScreen.screens.first ?? NSScreen.main else { return false }
        let pointer = NSEvent.mouseLocation
        // NSEvent uses bottom-left origin, Accessibility uses top-left.
        let point = CGPoint(x: pointer.x, y: screen.frame.height - pointer.y)

        let windows = store.windows(store.current)
        guard let hit = windows.first(where: { $0.frame.contains(point) }) else { return false }
        guard hit.hash != lastHoverHash else { return true }
        lastHoverHash = hit.hash

        if AX.bool(hit.el, kAXFocusedAttribute as CFString) != true {
            setFocus(hit)
            log("focus follows mouse: \(hit.title.prefix(28))")
        }
        return true
    }

    // MARK: - persistence

    /// Stable-enough identity for remembering where a window belongs across launches.
    ///
    /// The AXUIElement hash cannot be used: it is only valid for the lifetime of the element. App
    /// bundle id plus window title survives a relaunch, at the cost that renaming a window (a new
    /// browser tab, an unsaved document) makes it look like a new window and it lands on the
    /// current workspace — a safe failure, never a lost window.
    private func windowKey(_ win: Win) -> String {
        (win.app.bundleIdentifier ?? "unknown") + "|" + win.title
    }

    private func appKey(_ win: Win) -> String {
        win.app.bundleIdentifier ?? "unknown"
    }

    /// Where this window belonged last time.
    ///
    /// Window titles drift constantly — a Slack channel, an unread count, a browser tab — so an
    /// exact key misses more often than it hits. The per-app fallback is what actually keeps
    /// placement stable: most apps here have one window per workspace, so "where this app last
    /// lived" is the right answer when the title no longer matches.
    private func savedWorkspace(for win: Win) -> String? {
        guard restoreOnLaunch else { return nil }
        let defaults = UserDefaults.standard
        let byTitle = defaults.dictionary(forKey: "windowWorkspaces") as? [String: String]
        if let hit = byTitle?[windowKey(win)] { return hit }

        let byApp = defaults.dictionary(forKey: "appWorkspaces") as? [String: String]
        return byApp?[appKey(win)]
    }

    /// The size the user last gave this window, if any.
    private func savedWeight(for win: Win) -> CGFloat? {
        guard restoreOnLaunch else { return nil }
        let defaults = UserDefaults.standard
        if let byTitle = defaults.dictionary(forKey: "windowWeights") as? [String: Double],
           let hit = byTitle[windowKey(win)] {
            return CGFloat(hit)
        }
        if let byApp = defaults.dictionary(forKey: "appWeights") as? [String: Double],
           let hit = byApp[appKey(win)] {
            return CGFloat(hit)
        }
        return nil
    }

    private func restoreSavedState() {
        let defaults = UserDefaults.standard
        if let restore = defaults.object(forKey: "restoreOnLaunch") as? Bool {
            restoreOnLaunch = restore
        }
        if restoreOnLaunch {
            if let workspace = defaults.string(forKey: "currentWorkspace"), !workspace.isEmpty {
                store.current = workspace
            }
            if defaults.string(forKey: "orientation") == "v" {
                store.orientation = .vertical
            }
        }
        if let follow = defaults.object(forKey: "followAppAcrossWorkspaces") as? Bool {
            followAppAcrossWorkspaces = follow
        }
        if let hover = defaults.object(forKey: "focusFollowsMouse") as? Bool {
            focusFollowsMouse = hover
        }
    }

    /// Coalesced so a burst of moves writes once, a second later.
    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveState() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    /// Called for changes the user would notice losing: moving a window between workspaces.
    /// Written straight away, because a crash or a stray duplicate instance must not cost placement.
    private func saveImmediately() {
        saveWork?.cancel()
        saveState()
    }

    func saveState() {
        // Until the first refresh has finished, `store` is incomplete and writing it would erase
        // remembered placements — that is exactly how everything ended up back on one workspace.
        guard hasCompletedFirstRefresh else { return }

        var map: [String: String] = [:]
        for (_, win) in store.byHash {
            map[windowKey(win)] = win.workspace
        }
        let defaults = UserDefaults.standard
        defaults.set(map, forKey: "windowWorkspaces")
        // Mirror the same information per app, for when a title no longer matches.
        var byApp: [String: String] = [:]
        for (_, win) in store.byHash { byApp[appKey(win)] = win.workspace }
        defaults.set(byApp, forKey: "appWorkspaces")

        // Sizes are remembered too, or a restart would silently restore the even split.
        var weights: [String: Double] = [:]
        var appWeights: [String: Double] = [:]
        for (_, win) in store.byHash {
            weights[windowKey(win)] = Double(win.weight)
            appWeights[appKey(win)] = Double(win.weight)
        }
        defaults.set(weights, forKey: "windowWeights")
        defaults.set(appWeights, forKey: "appWeights")
        defaults.set(store.current, forKey: "currentWorkspace")
        defaults.set(store.orientation == .horizontal ? "h" : "v", forKey: "orientation")
    }

    // MARK: - minimum sizes that apps impose on themselves

    /// Seed a freshly discovered window with the minimums already learned for its app, so a restart
    /// does not have to re-discover them by briefly squeezing the window below its limit.
    private func seedMinimum(for win: Win) {
        guard let bundleId = win.app.bundleIdentifier else { return }
        let defaults = UserDefaults.standard
        let widths = defaults.dictionary(forKey: "appMinWidths") as? [String: Double] ?? [:]
        let heights = defaults.dictionary(forKey: "appMinHeights") as? [String: Double] ?? [:]
        if let w = widths[bundleId] { store.minWidth[win.hash] = CGFloat(w) }
        if let h = heights[bundleId] { store.minHeight[win.hash] = CGFloat(h) }
    }

    private func persistMinimum(app: NSRunningApplication, width: CGFloat?, height: CGFloat?) {
        guard let bundleId = app.bundleIdentifier else { return }
        let defaults = UserDefaults.standard
        if let width {
            var widths = defaults.dictionary(forKey: "appMinWidths") as? [String: Double] ?? [:]
            widths[bundleId] = Double(width)
            defaults.set(widths, forKey: "appMinWidths")
        }
        if let height {
            var heights = defaults.dictionary(forKey: "appMinHeights") as? [String: Double] ?? [:]
            heights[bundleId] = Double(height)
            defaults.set(heights, forKey: "appMinHeights")
        }
    }

    /// A window counts as parked when it sits entirely below the visible area or fully off to the
    /// left — i.e. at most a pixel of it can be seen.
    private func isParked(_ frame: CGRect, visible: CGRect) -> Bool {
        frame.minY >= visible.maxY - 2 || frame.maxX <= visible.minX + 2
    }

    // MARK: - layout

    /// Push the current workspace's layout to the system.
    ///
    /// Geometry is re-read from the window before every write. The cache is only a hint; treating
    /// it as truth is what allowed stale windows to stay overlapping.
    func apply(attempt: Int = 0) {
        guard enabled else { return }
        let rect = axVisibleFrame
        let current = store.windows(store.current)
        guard !current.isEmpty else { return }

        // 1–2 windows: a plain split (this is how the machine is actually used).
        // 3+: a grid. Slicing one row thin enough for 7 windows drops panes below the minimum
        // width apps accept, and a window that cannot shrink overruns its cell into its neighbour.
        // The grid keeps panes usable and still partitions the screen exactly.
        adoptExternalSizes(current)

        let minWidths = current.map { store.minWidth[$0.hash] ?? 1 }
        let minHeights = current.map { store.minHeight[$0.hash] ?? 1 }

        // 1–2 windows: a plain split (this is how the machine is actually used).
        // 3+: a grid. Slicing one row thin enough for 7 windows drops panes below the minimum
        // width apps accept, and a window that cannot shrink overruns its cell into its neighbour.
        // The grid keeps panes usable and still partitions the screen exactly.
        let frames: [CGRect]
        if current.count <= 2 {
            let mins = store.orientation == .horizontal ? minWidths : minHeights
            frames = Layout.frames(weights: current.map(\.weight),
                                   minimums: mins,
                                   in: rect,
                                   orientation: store.orientation)
        } else {
            // Reduce the column count until every cell is at least as wide as the widest minimum
            // observed among the windows in this workspace.
            let widestKnown = minWidths.max() ?? 1
            var cols = Layout.preferredColumns(for: current.count)
            while cols > 1 && rect.width / CGFloat(cols) < widestKnown {
                cols -= 1
            }
            frames = Layout.grid(weights: current.map(\.weight),
                                 minWidths: minWidths,
                                 minHeights: minHeights,
                                 in: rect,
                                 columns: cols)
        }

        var clamped = 0
        for (win, frame) in zip(current, frames) {
            // Defensive: a window may have gone full-screen between refresh and apply.
            if AX.bool(win.el, "AXFullScreen" as CFString) == true { continue }
            let actual = AX.currentFrame(win.el)
            guard actual != frame else { continue }

            AX.setFrame(win.el, frame)
            win.frame = frame

            guard let after = AX.currentFrame(win.el) else { continue }

            // The app clamped itself to its own minimum: it is bigger than the cell offered.
            // Remember both dimensions so the next pass can allocate around them instead of
            // fighting them — this is what makes the layout conform to apps like Hermes.
            if after.width > frame.width + 2 {
                clamped += 1
                if store.minWidth[win.hash] != after.width {
                    store.minWidth[win.hash] = after.width
                    persistMinimum(app: win.app, width: after.width, height: nil)
                    let app = win.app.localizedName ?? "?"
                    log("min width learned: \(app) = \(Int(after.width)) (cell was \(Int(frame.width)))")
                }
            }
            if after.height > frame.height + 2 {
                clamped += 1
                if store.minHeight[win.hash] != after.height && after.height > 0 {
                    store.minHeight[win.hash] = after.height
                    persistMinimum(app: win.app, width: nil, height: after.height)
                    let app = win.app.localizedName ?? "?"
                    log("min height learned: \(app) = \(Int(after.height)) (cell was \(Int(frame.height)))")
                }
            }
            if after != frame && !refusalsLogged.contains(win.hash) {
                refusalsLogged.insert(win.hash)
                let app = win.app.localizedName ?? "?"
                log("refused geometry: \(app) wanted \(Int(frame.width))x\(Int(frame.height)) "
                    + "at \(Int(frame.minX)),\(Int(frame.minY)) "
                    + "got \(Int(after.width))x\(Int(after.height)) at \(Int(after.minX)),\(Int(after.minY))")
            }
        }

        // Keep weights honest: restate them in terms of the sizes the layout actually produced.
        // A window clamped to its minimum leaves its weight inflated, and then the next shrink
        // command appears to do nothing — the weight moves but the split cannot. Re-deriving from
        // the achieved frames keeps one weight unit equal to one "smallest pane" and makes every
        // subsequent adjustment visible.
        if current.count > 1, store.orientation == .horizontal {
            let widths = frames.map(\.width)
            if let smallest = widths.min(), smallest > 1, widths.count == current.count {
                for (win, width) in zip(current, widths) {
                    win.weight = min(max(width / smallest, 0.2), 12)
                }
            }
        }

        // Re-lay out with what we just learned. Bounded: each retry either reduces the column count
        // or is the last one, so this cannot spin.
        if clamped > 0 && attempt < 2 {
            apply(attempt: attempt + 1)
        }
    }

    // MARK: - commands

    /// Which window a hotkey should act on, in order of trustworthiness.
    ///
    /// 1. a window that reports `AXFocused`;
    /// 2. the frontmost app's `AXFocusedWindow` — covers apps that don't expose per-window focus;
    /// 3. the last window we focused or saw focused, if it is still on this workspace;
    /// 4. the first window, so a hotkey is never a no-op.
    ///
    /// Falling straight to (4) is what makes "move" act on the wrong window: with several apps
    /// open, "the first window in the list" is rarely the one the user is looking at.
    private func focused() -> Win? {
        let list = store.windows(store.current)
        guard !list.isEmpty else { return nil }

        if let hit = list.first(where: { AX.bool($0.el, kAXFocusedAttribute as CFString) == true }) {
            lastFocused = hit
            log("focused via AXFocused: \(hit.title.isEmpty ? "?" : hit.title)")
            return hit
        }
        if let app = NSWorkspace.shared.frontmostApplication {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            if let el = AX.element(axApp, kAXFocusedWindowAttribute as CFString),
               let win = store.byHash[CFHash(el)],
               list.contains(where: { $0 === win }) {
                lastFocused = win
                log("focused via frontmost app AXFocusedWindow: \(win.title)")
                return win
            }
        }
        if let last = lastFocused, list.contains(where: { $0 === last }) {
            log("focused via lastFocused: \(last.title)")
            return last
        }
        log("focused via fallback (first window): \(list[0].title)")
        return list[0]
    }

    func focus(_ direction: Direction) {
        refresh()
        let list = store.windows(store.current)
        guard let win = focused(), let i = list.firstIndex(where: { $0 === win }) else { return }
        guard let j = Layout.neighbour(from: i, count: list.count, direction: direction,
                                       orientation: store.orientation) else { return }
        setFocus(list[j])
    }

    func move(_ direction: Direction) {
        refresh()
        let list = store.windows(store.current)
        guard let win = focused(), let i = list.firstIndex(where: { $0 === win }) else { return }
        guard let j = Layout.neighbour(from: i, count: list.count, direction: direction,
                                       orientation: store.orientation) else { return }
        store.move(win, to: store.current, at: j)
        apply()
        setFocus(win)
        saveImmediately()
    }

    func resize(grow: Bool) {
        guard let win = focused() else { return }
        win.weight = min(max(win.weight * (grow ? 1.25 : 0.8), 0.2), 5)
        apply()
    }

    func toggleOrientation() {
        store.orientation = store.orientation.opposite
        apply()
        scheduleSave()
    }

    func switchWorkspace(_ name: String) {
        guard store.current != name else { return }
        let started = CFAbsoluteTimeGetCurrent()
        defer {
            let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
            log(String(format: "switch %@ took %.1f ms", name, ms))
        }
        store.current = name
        saveImmediately()
        // No rescan: the set of windows did not change, only which ones are visible.
        parkOtherWorkspaces()
        apply()
        if focusFollowsMouse, focusWindowUnderCursor() { return }
        if let first = store.windows(name).first { setFocus(first) }
    }

    func moveToWorkspace(_ name: String) {
        guard let win = focused() else { return }
        store.move(win, to: name)
        saveImmediately()
        apply()
        if let next = store.windows(store.current).first { setFocus(next) }
    }

    private func setFocus(_ win: Win) {
        lastFocused = win
        AX.setBool(win.el, kAXMainAttribute as CFString, true)
        AX.setBool(win.el, kAXFocusedAttribute as CFString, true)
        // activate() is a ~10-20 ms trip through LaunchServices; skip it when the app is already
        // in front, which is the common case when moving focus inside one app.
        if !win.app.isActive { win.app.activate(options: []) }
    }

    // MARK: - menu bar

    var aboutWindow: NSWindow?
    var settingsWindow: NSWindow?
    var helpWindow: NSWindow?
    /// Whether to put windows back where they were on launch.
    var restoreOnLaunch = true

    /// Modifier used by every shortcut, so the whole scheme can be moved off Option.
    var hotkeyModifierName: String {
        UserDefaults.standard.string(forKey: "hotkeyModifier") ?? "option"
    }

    var hotkeyModifier: UInt32 {
        switch hotkeyModifierName {
        case "control": return UInt32(controlKey)
        case "command": return UInt32(cmdKey)
        default:        return UInt32(optionKey)
        }
    }

    private func buildMenuBar() {
        installStatusItem()
    }

    @objc func toggleEnabled(_ sender: NSMenuItem) {
        enabled.toggle()
        sender.state = enabled ? .on : .off
        if enabled { refresh() }
    }

    @objc func reloadNow() {
        refresh()
    }

    @objc func quit() {
        saveWork?.cancel()
        saveState()          // capture the arrangement as it is right now, not a second ago
        NSApp.terminate(nil)
    }

    /// Deep link into the exact pane, so the permission is two clicks away and not a hunt.
    @objc func openAccessibility() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}

/// Log to stderr *and* a file, because a launchd-started app has nowhere to print.
func log(_ message: String) {
    let line = "pulsar: " + message + "\n"
    FileHandle.standardError.write(line.data(using: .utf8)!)

    let url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/Pulsar.log")
    let data = line.data(using: .utf8)!

    // Keep the log bounded; it now records app activations, so it would otherwise grow forever.
    if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
       size > 512 * 1024 {
        try? FileManager.default.removeItem(at: url)
    }
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: url)
    }
}
