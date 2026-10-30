import AppKit

// Wintest — a controllable app whose only purpose is to give the window manager windows to manage.
//
// It reads a command file (~/Library/Logs/Wintest.cmd) so a test script can open, close, resize,
// retitle, minimise and hide windows at will, and it logs the frame it believes each window has.
// Polling a file is fine here: this is test scaffolding, not the window manager.

final class WintestDelegate: NSObject, NSApplicationDelegate {
    var windows: [NSWindow] = []
    var logHandle: FileHandle?
    let commandURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/Wintest.cmd")
    let logURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/Wintest.log")
    var forcedMin = NSSize(width: 0, height: 0)

    func applicationDidFinishLaunching(_ notification: Notification) {
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        logHandle = try? FileHandle(forWritingTo: logURL)
        try? logHandle?.truncate(atOffset: 0)
        Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            self?.poll()
        }
        log("ready")
    }

    func log(_ s: String) {
        guard let data = (s + "\n").data(using: .utf8) else { return }
        logHandle?.seekToEndOfFile()
        logHandle?.write(data)
    }

    func poll() {
        guard let cmd = try? String(contentsOf: commandURL, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: commandURL)
        for line in cmd.split(separator: "\n") {
            run(String(line).trimmingCharacters(in: .whitespaces))
        }
    }

    @discardableResult
    func makeWindow(width: CGFloat = 640, height: CGFloat = 480, title: String? = nil) -> NSWindow {
        let index = windows.count
        // Cascade the origins: identical frames make the window server stack them exactly, which
        // confuses some Accessibility clients.
        let originX = 80 + CGFloat(index) * 46
        let originY = 80 + CGFloat(index) * 46
        let w = NSWindow(contentRect: NSRect(x: originX, y: originY, width: width, height: height),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = title ?? "wintest-\(index)"
        w.isReleasedWhenClosed = false
        if forcedMin.width > 0 || forcedMin.height > 0 {
            w.contentMinSize = forcedMin
        }
        // orderFrontRegardless is the one that works for an inactive app; plain
        // makeKeyAndOrderFront leaves the window ordered out and Accessibility then does not list it.
        w.orderFrontRegardless()
        windows.append(w)
        log("opened \(index) \(w.title) \(Int(w.frame.width))x\(Int(w.frame.height))")
        return w
    }

    func run(_ command: String) {
        let parts = command.split(separator: " ").map(String.init)
        guard let verb = parts.first else { return }

        switch verb {
        case "focus":
            guard let i = parts.count > 1 ? Int(parts[1]) : 0, i < windows.count else { return }
            NSApp.activate(ignoringOtherApps: true)
            windows[i].makeKeyAndOrderFront(nil)
            log("focused \(i)")

        case "activate":
            NSApp.activate(ignoringOtherApps: true)
            log("activated")

        case "open":
            let n = parts.count > 1 ? (Int(parts[1]) ?? 1) : 1
            let width = parts.count > 3 ? CGFloat(Double(parts[2]) ?? 640) : 640
            let height = parts.count > 3 ? CGFloat(Double(parts[3]) ?? 480) : 480
            for _ in 0..<n { makeWindow(width: width, height: height) }

        case "close":
            guard let i = parts.count > 1 ? Int(parts[1]) : nil, i < windows.count else { return }
            windows[i].close()
            windows.remove(at: i)

        case "closeall":
            for w in windows { w.close() }
            windows.removeAll()
            log("closed all")

        case "title":
            guard parts.count > 2, let i = Int(parts[1]), i < windows.count else { return }
            windows[i].title = parts[2...].joined(separator: " ")
            log("retitled \(i)")

        case "resize":
            guard parts.count > 3, let i = Int(parts[1]), i < windows.count else { return }
            windows[i].setFrame(NSRect(x: windows[i].frame.minX, y: windows[i].frame.minY,
                                       width: Double(parts[2]) ?? 600, height: Double(parts[3]) ?? 400),
                                display: true)
            log("resized \(i)")

        case "min":
            forcedMin = NSSize(width: Double(parts.count > 1 ? parts[1] : "0") ?? 0,
                               height: Double(parts.count > 2 ? parts[2] : "0") ?? 0)
            for w in windows { w.contentMinSize = forcedMin }
            log("min \(Int(forcedMin.width))x\(Int(forcedMin.height))")

        case "minimize":
            guard let i = parts.count > 1 ? Int(parts[1]) : 0, i < windows.count else { return }
            windows[i].miniaturize(nil)
            log("minimized \(i)")

        case "deminimize":
            guard let i = parts.count > 1 ? Int(parts[1]) : 0, i < windows.count else { return }
            windows[i].deminiaturize(nil)
            log("deminimized \(i)")

        case "hide":
            NSApp.hide(nil)
            log("hidden")

        case "unhide":
            NSApp.unhide(nil)
            log("unhidden")

        case "dump":
            let frames = windows.map { w in
                "\(Int(w.frame.minX)) \(Int(w.frame.minY)) \(Int(w.frame.width)) \(Int(w.frame.height)) \(w.title)"
            }
            log("dump " + frames.joined(separator: " | "))

        case "quit":
            NSApp.terminate(nil)

        default:
            log("unknown command: \(command)")
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = WintestDelegate()
app.delegate = delegate
app.run()
