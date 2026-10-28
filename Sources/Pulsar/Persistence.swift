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
