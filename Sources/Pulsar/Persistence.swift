import AppKit

// Remembering where things were: window identity, workspace placement, sizes, and the minimum
// sizes apps impose on themselves.

extension Controller {

    // MARK: - persistence

    /// Stable-enough identity for remembering where a window belongs across launches.
    ///
    /// The AXUIElement hash cannot be used: it is only valid for the lifetime of the element. App
    /// bundle id plus window title survives a relaunch, at the cost that renaming a window (a new
    /// browser tab, an unsaved document) makes it look like a new window and it lands on the
    /// current workspace — a safe failure, never a lost window.
    func windowKey(_ win: Win) -> String {
        (win.app.bundleIdentifier ?? "unknown") + "|" + win.title
    }

    func appKey(_ win: Win) -> String {
        win.app.bundleIdentifier ?? "unknown"
    }

    /// Where this window belonged last time, by its exact key only.
    ///
    /// Used for windows discovered in the settling window after launch. It deliberately does *not*
    /// fall back to the app's workspace: a brand-new window opened during that window should stay
    /// where the user is, and only a window we have actually seen before has a real home.
    func savedWindowWorkspace(for win: Win) -> String? {
        guard restoreOnLaunch else { return nil }
        let byTitle = UserDefaults.standard.dictionary(forKey: "windowWorkspaces") as? [String: String]
        return byTitle?[windowKey(win)]
    }

    /// Where this window belonged last time.
    ///
    /// Window titles drift constantly — a Slack channel, an unread count, a browser tab — so an
    /// exact key misses more often than it hits. The per-app fallback is what actually keeps
    /// placement stable: most apps here have one window per workspace, so "where this app last
    /// lived" is the right answer when the title no longer matches.
    func savedWorkspace(for win: Win) -> String? {
        guard restoreOnLaunch else { return nil }
        let defaults = UserDefaults.standard
        let byTitle = defaults.dictionary(forKey: "windowWorkspaces") as? [String: String]
        if let hit = byTitle?[windowKey(win)] { return hit }

        let byApp = defaults.dictionary(forKey: "appWorkspaces") as? [String: String]
        return byApp?[appKey(win)]
    }

    /// The size the user last gave this window, if any.
    func savedWeight(for win: Win) -> CGFloat? {
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

    func restoreSavedState() {
        recoverMapIfEmpty()
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
    func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveState() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    /// Called for changes the user would notice losing: moving a window between workspaces.
    /// Written straight away, because a crash or a stray duplicate instance must not cost placement.
    func saveImmediately() {
        saveWork?.cancel()
        saveState()
    }

    func saveState() {
        // Until the first refresh has finished, `store` is incomplete and writing it would erase
        // remembered placements.
        guard hasCompletedFirstRefresh else { return }

        // An empty snapshot means the scan failed (a Space transition, a busy app), not that every
        // window closed. Writing it would wipe the map — which is exactly how every window ended up
        // adopted onto one workspace after a restart.
        guard !store.byHash.isEmpty else {
            log("save: skipped — no windows tracked, keeping the saved map")
            return
        }

        let defaults = UserDefaults.standard

        // MERGE, never replace. Entries for windows that are merely absent from this snapshot —
        // another workspace's window, a scan that missed an app — must survive, because they are the
        // only record of where those windows belong.
        var windows = defaults.dictionary(forKey: "windowWorkspaces") as? [String: String] ?? [:]
        var apps = defaults.dictionary(forKey: "appWorkspaces") as? [String: String] ?? [:]
        var weights = defaults.dictionary(forKey: "windowWeights") as? [String: Double] ?? [:]
        var appWeights = defaults.dictionary(forKey: "appWeights") as? [String: Double] ?? [:]

        // Keep the previous generation, so a bad save can be undone at the next launch.
        defaults.set(apps, forKey: "appWorkspaces.previous")
        defaults.set(windows, forKey: "windowWorkspaces.previous")

        for (_, win) in store.byHash {
            let key = windowKey(win)
            windows[key] = win.workspace
            apps[appKey(win)] = win.workspace
            weights[key] = Double(win.weight)
            appWeights[appKey(win)] = Double(win.weight)
        }

        // Titles drift forever; cap the history so the file cannot grow without bound.
        if windows.count > 400 { windows = windows.filter { weights[$0.key] != nil || $0.value == store.current } }

        defaults.set(windows, forKey: "windowWorkspaces")
        defaults.set(apps, forKey: "appWorkspaces")
        defaults.set(weights, forKey: "windowWeights")
        defaults.set(appWeights, forKey: "appWeights")
        defaults.set(store.current, forKey: "currentWorkspace")
        defaults.set(store.orientation == .horizontal ? "h" : "v", forKey: "orientation")
    }

    /// If the map was erased by an earlier build, put the last good generation back.
    func recoverMapIfEmpty() {
        let defaults = UserDefaults.standard
        let apps = defaults.dictionary(forKey: "appWorkspaces") as? [String: String] ?? [:]
        guard apps.isEmpty else { return }
        if let previous = defaults.dictionary(forKey: "appWorkspaces.previous") as? [String: String],
           !previous.isEmpty {
            defaults.set(previous, forKey: "appWorkspaces")
            log("recovered appWorkspaces from the previous generation (\(previous.count) apps)")
        }
    }

    // MARK: - minimum sizes that apps impose on themselves

    /// Seed a freshly discovered window with the minimums already learned for its app, so a restart
    /// does not have to re-discover them by briefly squeezing the window below its limit.
    func seedMinimum(for win: Win) {
        guard let bundleId = win.app.bundleIdentifier else { return }
        let defaults = UserDefaults.standard
        let widths = defaults.dictionary(forKey: "appMinWidths") as? [String: Double] ?? [:]
        let heights = defaults.dictionary(forKey: "appMinHeights") as? [String: Double] ?? [:]
        if let w = widths[bundleId] { store.minWidth[win.hash] = CGFloat(w) }
        if let h = heights[bundleId] { store.minHeight[win.hash] = CGFloat(h) }
    }

    func persistMinimum(app: NSRunningApplication, width: CGFloat?, height: CGFloat?) {
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
}
