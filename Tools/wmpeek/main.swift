import AppKit
import CoreGraphics

// wmpeek — observe window geometry without Accessibility permission.
//
// CGWindowListCopyWindowInfo needs no TCC approval, which makes it the honest way to check what a
// window manager actually did to windows, as opposed to what it intended to do.
//
//   wmpeek            list managed-looking windows
//   wmpeek --parked   windows parked off-screen (Pulsar hides other workspaces this way)
//   wmpeek --check    tiling summary + overlap detection

let args = CommandLine.arguments

// --ids <owner>: print CGWindowIDs for an owner, so a specific window can be screenshotted with
// `screencapture -l <id>` even when it is not frontmost.
if let flag = args.firstIndex(of: "--ids"), args.count > flag + 1 {
    let owner = args[flag + 1]
    let list = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
    for w in list {
        guard let name = w[kCGWindowOwnerName as String] as? String, name == owner,
              let number = w[kCGWindowNumber as String] as? Int,
              let bounds = w[kCGWindowBounds as String] as? [String: Any],
              let width = bounds["Width"] as? CGFloat, width > 100 else { continue }
        let title = w[kCGWindowName as String] as? String ?? ""
        print("\(number)\t\(title)\t\(Int(width))")
    }
    exit(0)
}
// --visible: the usable screen area in the same top-left origin coordinates Accessibility uses.
if args.contains("--visible") {
    let vf = NSScreen.screens.first?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    let screenHeight = NSScreen.screens.first?.frame.height ?? vf.maxY
    let obj: [String: Double] = ["x": Double(vf.minX), "y": Double(screenHeight - vf.maxY),
                                 "w": Double(vf.width), "h": Double(vf.height)]
    if let data = try? JSONSerialization.data(withJSONObject: obj),
       let text = String(data: data, encoding: .utf8) { print(text) }
    exit(0)
}

let parkedMode = args.contains("--parked")
let checkMode = args.contains("--check")

guard let raw = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
    print("could not read window list")
    exit(1)
}

struct Row {
    let owner: String
    let pid: pid_t
    let name: String
    let frame: CGRect
    let onscreen: Bool
}

var rows: [Row] = []
for w in raw {
    guard let owner = w[kCGWindowOwnerName as String] as? String,
          let pid = w[kCGWindowOwnerPID as String] as? pid_t,
          let bounds = w[kCGWindowBounds as String] as? [String: Any],
          let layer = w[kCGWindowLayer as String] as? Int, layer == 0 else { continue }

    // Only real apps — skips CursorUIViewService, Siri, panels, menu extras.
    guard let app = NSRunningApplication(processIdentifier: pid),
          app.activationPolicy == .regular, pid != getpid() else { continue }

    let x = bounds["X"] as? CGFloat ?? 0
    let y = bounds["Y"] as? CGFloat ?? 0
    let width = bounds["Width"] as? CGFloat ?? 0
    let height = bounds["Height"] as? CGFloat ?? 0
    guard width > 120, height > 120 else { continue }

    let name = w[kCGWindowName as String] as? String ?? ""
    let onscreen = w[kCGWindowIsOnscreen as String] as? Bool ?? false
    rows.append(Row(owner: owner, pid: pid, name: name,
                    frame: CGRect(x: x, y: y, width: width, height: height), onscreen: onscreen))
}

// Pulsar parks windows at the bottom-left corner so only ~1 px remains. Detect that shape
// rather than looking for a far-off coordinate, which the window server clamps anyway.
let vis = NSScreen.screens.first?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
func parkedFrame(_ f: CGRect) -> Bool {
    f.minX <= -20000 || f.minY >= vis.maxY - 2 || f.maxX <= vis.minX + 2
}
let parked = rows.filter { parkedFrame($0.frame) }
// Only windows the window server says are actually displayed can overlap in front of the user.
let onscreen = rows.filter { !parkedFrame($0.frame) && $0.onscreen }

if args.contains("--json") {
    let objects = rows.map { r -> [String: Any] in
        ["owner": r.owner, "pid": Int(r.pid), "title": r.name,
         "x": Int(r.frame.minX), "y": Int(r.frame.minY),
         "w": Int(r.frame.width), "h": Int(r.frame.height),
         "onscreen": r.onscreen, "parked": parkedFrame(r.frame)]
    }
    if let data = try? JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys]),
       let text = String(data: data, encoding: .utf8) {
        print(text)
    }
    exit(0)
}

if parkedMode {
    print("parked windows: \(parked.count)")
    for r in parked { print("  \(r.owner) — \(r.name.isEmpty ? "(untitled)" : r.name) x=\(Int(r.frame.minX)) y=\(Int(r.frame.minY))") }
    exit(0)
}

if checkMode {
    let visible = NSScreen.screens.first?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    print("visible frame: \(Int(visible.width))×\(Int(visible.height))")
    print("app windows on screen: \(onscreen.count)")
    print("parked (other workspaces): \(parked.count)")

    // A tiling WM makes panes share the same y/height and butt up against each other.
    let fullHeight = onscreen.filter { abs($0.frame.height - visible.height) <= 2 }
    print("panes at full visible height: \(fullHeight.count)")

    // Overlap detection across every visible window.
    var overlaps: [(String, String, CGFloat)] = []
    let sorted = onscreen.sorted { $0.frame.minX < $1.frame.minX }
    for i in 0..<sorted.count {
        for j in (i+1)..<sorted.count {
            let a = sorted[i].frame, b = sorted[j].frame
            let sharedX = min(a.maxX, b.maxX) - max(a.minX, b.minX)
            let sharedY = min(a.maxY, b.maxY) - max(a.minY, b.minY)
            if sharedX > 2 && sharedY > 2 {
                overlaps.append((sorted[i].owner, sorted[j].owner, sharedX))
            }
        }
    }
    print("overlaps among tiled panes: \(overlaps.count)")
    for o in overlaps.prefix(6) {
        print("  ⚠ \(o.0) ↔ \(o.1) share \(Int(o.2)) pt horizontally")
    }

    print("\npanes left→right:")
    for r in sorted {
        print(String(format: "  x=%4d w=%4d h=%4d  %@", Int(r.frame.minX), Int(r.frame.width),
                     Int(r.frame.height), r.owner))
    }
    // coverage check: do the panes tile the width exactly?
    if let first = sorted.first, let last = sorted.last {
        print("\nspan: \(Int(first.frame.minX)) → \(Int(last.frame.maxX))  (visible width \(Int(visible.width)))")
    }
    exit(0)
}

print("owner                     x      y      w      h")
for r in onscreen.sorted(by: { $0.frame.minX < $1.frame.minX }) {
    let owner = r.owner.padding(toLength: 24, withPad: " ", startingAt: 0)
    print("\(owner) "
          + "\(Int(r.frame.minX))".padding(toLength: 7, withPad: " ", startingAt: 0)
          + "\(Int(r.frame.minY))".padding(toLength: 7, withPad: " ", startingAt: 0)
          + "\(Int(r.frame.width))".padding(toLength: 7, withPad: " ", startingAt: 0)
          + "\(Int(r.frame.height))")
}
