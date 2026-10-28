import AppKit
import ApplicationServices

enum Orientation {
    case horizontal
    case vertical

    var opposite: Orientation { self == .horizontal ? .vertical : .horizontal }
}

/// One managed window.
///
/// Identity is the AXUIElement itself. We never compare titles (they change) and never rely on
/// indexes (they move), both of which are the usual source of "wrong window moved" bugs.
final class Win {
    let el: AXUIElement
    let pid: pid_t
    let app: NSRunningApplication
    var workspace: String
    var weight: CGFloat = 1
    var frame: CGRect = .zero

    init(el: AXUIElement, pid: pid_t, app: NSRunningApplication, workspace: String) {
        self.el = el
        self.pid = pid
        self.app = app
        self.workspace = workspace
    }

    var hash: CFHashCode { CFHash(el) }

    /// Window title for logging, falling back to the app name.
    var title: String {
        let t = AX.string(el, kAXTitleAttribute as CFString) ?? ""
        return t.isEmpty ? (app.localizedName ?? "untitled") : t
    }

    func currentFrame() -> CGRect? {
        guard let p = AX.point(el, kAXPositionAttribute as CFString),
              let s = AX.size(el, kAXSizeAttribute as CFString) else { return nil }
        return CGRect(origin: p, size: s)
    }
}

/// Window bookkeeping per workspace, plus the tiny bit of state a tiling WM needs.
final class Store {
    /// ordered windows per workspace name ("1"…"8", "a"…"z")
    private(set) var workspaces: [String: [Win]] = [:]
    var current: String = "1"
    var orientation: Orientation = .horizontal

    /// Smallest width each window has been observed to accept. Apps clamp their own size, and a
    /// window that cannot fit its cell overruns it into its neighbour. Remembering the clamps lets
    /// the layout pick a column count that fits instead of re-learning it on every pass.
    var minWidth: [CFHashCode: CGFloat] = [:]
    var minHeight: [CFHashCode: CGFloat] = [:]

    /// All windows, keyed for O(1) lookup during refresh.
    private(set) var byHash: [CFHashCode: Win] = [:]

    func windows(_ name: String) -> [Win] { workspaces[name] ?? [] }

    func add(_ win: Win, to name: String) {
        workspaces[name, default: []].append(win)
        byHash[win.hash] = win
    }

    func remove(_ win: Win) {
        byHash.removeValue(forKey: win.hash)
        for key in workspaces.keys {
            workspaces[key]?.removeAll { $0 === win }
        }
    }

    func move(_ win: Win, to name: String, at index: Int? = nil) {
        for key in workspaces.keys {
            workspaces[key]?.removeAll { $0 === win }
        }
        win.workspace = name
        var list = workspaces[name, default: []]
        let i = min(max(index ?? list.count, 0), list.count)
        list.insert(win, at: i)
        workspaces[name] = list
    }

    func index(of win: Win) -> Int? {
        windows(win.workspace).firstIndex { $0 === win }
    }

    /// Drop one app's windows that no longer exist, leaving every other app untouched.
    /// Used when the app itself is still running but a single window was closed.
    func prune(pid: pid_t, live: Set<CFHashCode>) {
        for (hash, win) in byHash where win.pid == pid && !live.contains(hash) {
            byHash.removeValue(forKey: hash)
            workspaces[win.workspace]?.removeAll { $0.hash == hash }
        }
    }

    /// Drop windows whose process is gone, and keep `current` sane.
    func prune(live: Set<CFHashCode>) {
        for (hash, win) in byHash where !live.contains(hash) {
            _ = win
            byHash.removeValue(forKey: hash)
            workspaces[win.workspace]?.removeAll { $0.hash == hash }
        }
    }
}
