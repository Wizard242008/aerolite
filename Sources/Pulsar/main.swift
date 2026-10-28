import AppKit

// Pulsar — a minimal, event-driven tiling window manager for macOS.
//
// Design notes live at the top of Controller.swift; the short version is: no polling, coalesced
// refreshes, diffed geometry writes, single-display tiling with virtual workspaces, and
// full-screen windows left strictly alone.
//
// Modes:
//   (none)        run the window manager as a menu-bar agent
//   --diagnose    print permission + AX reachability from this binary's own identity, then exit

if CommandLine.arguments.contains("--diagnose") {
    // Running inside the bundle means TCC attributes this to com.devansh.pulsar, so the answer
    // here is the same answer the real agent gets.
    let trusted = AXIsProcessTrusted()
    print("bundle id:    com.devansh.pulsar")
    print("trusted:      \(trusted ? "YES" : "NO")")

    if !trusted {
        print("windows:      unreadable (Accessibility not granted)")
        print("verdict:      enable Pulsar in System Settings → Privacy & Security → Accessibility")
        exit(2)
    }

    var total = 0
    var apps = 0
    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
        let n = AX.windows(of: app.processIdentifier).count
        if n > 0 { apps += 1; total += n }
    }
    print("windows:      \(total) across \(apps) apps")
    print("verdict:      working")
    exit(0)
}

// Dump the rendered help text, so the Markdown renderer can be inspected without a window server.
if CommandLine.arguments.contains("--render-help") {
    let url = Bundle.main.url(forResource: "README", withExtension: "md")
    let markdown = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? Controller.fallbackHelp
    print(Controller.render(markdown).string)
    exit(0)
}

// Render the menu-bar glyph to a PNG so its design can be inspected without screen-recording
// permission (screencapture cannot read the display from a sandboxed shell).
if let flag = CommandLine.arguments.firstIndex(of: "--render-glyph"),
   CommandLine.arguments.count > flag + 1 {
    let path = CommandLine.arguments[flag + 1]
    let scale = 12
    let glyph = Controller.statusGlyph()
    let width = Int(glyph.size.width) * scale
    let height = Int(glyph.size.height) * scale

    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .none
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    glyph.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.restoreGraphicsState()

    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    print("wrote \(path) (\(width)x\(height))")
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // menu-bar app: no Dock icon, no app switcher entry

// Single instance only — but tolerate a race with an instance that is on its way out.
//
// `kill` followed immediately by a launch starts the replacement before the old process has
// finished dying. Exiting straight away in that window leaves the launchd job dead while an
// orphan keeps tiling, which is exactly how "it restarted and lost my layout" happens.
let current = NSRunningApplication.current
func duplicates() -> [NSRunningApplication] {
    NSRunningApplication.runningApplications(withBundleIdentifier: "com.devansh.pulsar")
        .filter { $0 != current && !$0.isTerminated }
}

if !duplicates().isEmpty {
    // Nudge the live instance to re-tile, then give a dying one up to two seconds to disappear.
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFNotificationName("com.devansh.pulsar.retile" as CFString),
                                         nil, nil, true)
    let deadline = Date().addingTimeInterval(2.0)
    while Date() < deadline && !duplicates().isEmpty {
        usleep(100_000)
    }
    if !duplicates().isEmpty {
        log("another instance is already running — exiting")
        exit(0)
    }
    log("previous instance was still exiting — taking over")
}

let controller = Controller()
controller.start()

// A SIGTERM (logout, launchctl, `kill`) must not cost the arrangement. DispatchSource keeps the
// handler off the signal context so it is safe to touch UserDefaults here.
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT, SIGHUP] {
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        controller.saveState()
        exit(0)
    }
    source.resume()
    signal(sig, SIG_IGN)
    signalSources.append(source)
}

app.run()
