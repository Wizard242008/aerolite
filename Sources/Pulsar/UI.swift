import AppKit

// The visible surface of Pulsar: menu-bar glyph, menu, and About panel.
//
// Kept separate from Controller so the window-management logic stays readable. Everything here is
// built with native AppKit so it inherits the system look (vibrancy, dark mode, accessibility
// labels) instead of approximating it with custom drawing.

extension Controller: NSMenuDelegate {

    /// Monochrome template glyph: one tall pane, two stacked. Template images are tinted by the
    /// system, so this stays correct in light mode, dark mode, and when the menu bar is highlighted.
    static func statusGlyph() -> NSImage {
        let size = NSSize(width: 18, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            let centre = NSPoint(x: rect.midX, y: rect.midY)
            let outer = min(rect.width, rect.height) / 2
            let inner = outer * 0.30

            // Four-point star: alternating long and short radii read as a pulsar's beams and stay
            // legible at 16 px, where circles and gradients turn to mush.
            let star = NSBezierPath()
            for step in 0..<8 {
                let angle = CGFloat(step) * .pi / 4 + .pi / 2
                let r = step.isMultiple(of: 2) ? outer : inner
                let point = NSPoint(x: centre.x + cos(angle) * r, y: centre.y + sin(angle) * r)
                step == 0 ? star.move(to: point) : star.line(to: point)
            }
            star.close()
            star.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Pulsar"
        return image
    }

    private func symbol(_ name: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Controller.statusGlyph()
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = "Pulsar — tiling window manager"

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu

        statusItem = item
        rebuildMenu()
    }

    /// Rebuilt every time the menu opens, so counts and states are always live.
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()

        let trusted = AXIsProcessTrusted()
        let total = store.byHash.count
        let here = store.windows(store.current).count

        // Header: name + a live one-line status, like Apple's own menu-bar utilities.
        let header = NSMenuItem()
        let title = NSMutableAttributedString(
            string: "Pulsar\n",
            attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]
        )
        let statusText = trusted
            ? "Workspace \(store.current) · \(here) window\(here == 1 ? "" : "s") · \(total) managed"
            : "Accessibility permission needed"
        title.append(NSMutableAttributedString(
            string: statusText,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: trusted ? NSColor.secondaryLabelColor : NSColor.systemOrange,
            ]
        ))
        header.attributedTitle = title
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        // Workspaces, with a checkmark on the current one and live window counts.
        let workspaceItem = NSMenuItem(title: "Workspaces", action: nil, keyEquivalent: "")
        workspaceItem.image = symbol("rectangle.split.3x1")
        let workspaceMenu = NSMenu()
        for name in orderedWorkspaceNames() {
            let count = store.windows(name).count
            let item = NSMenuItem(title: "\(name)  —  \(count) window\(count == 1 ? "" : "s")",
                                  action: #selector(selectWorkspace(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
            item.state = (name == store.current) ? NSControl.StateValue.on : NSControl.StateValue.off
            workspaceMenu.addItem(item)
        }
        workspaceItem.submenu = workspaceMenu
        menu.addItem(workspaceItem)

        let layoutItem = NSMenuItem(
            title: "Layout: \(store.orientation == .horizontal ? "Horizontal" : "Vertical")",
            action: #selector(toggleOrientationFromMenu), keyEquivalent: "/"
        )
        layoutItem.target = self
        layoutItem.image = symbol(store.orientation == .horizontal
                                  ? "rectangle.split.2x1"
                                  : "rectangle.split.1x2")
        menu.addItem(layoutItem)

        let enabledItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        enabledItem.target = self
        enabledItem.state = enabled ? NSControl.StateValue.on : NSControl.StateValue.off
        enabledItem.image = symbol(enabled ? "checkmark.circle" : "pause.circle")
        menu.addItem(enabledItem)

        let follow = NSMenuItem(title: "Follow App to Its Workspace",
                                action: #selector(toggleFollow), keyEquivalent: "")
        follow.target = self
        follow.state = followAppAcrossWorkspaces ? NSControl.StateValue.on : NSControl.StateValue.off
        follow.image = symbol("arrow.turn.up.right.diamond")
        menu.addItem(follow)

        let hover = NSMenuItem(title: "Focus Follows Mouse",
                               action: #selector(toggleFocusFollowsMouse), keyEquivalent: "")
        hover.target = self
        hover.state = focusFollowsMouse ? NSControl.StateValue.on : NSControl.StateValue.off
        hover.image = symbol("cursorarrow")
        menu.addItem(hover)

        let retile = NSMenuItem(title: "Re-tile Now", action: #selector(reloadNow), keyEquivalent: "r")
        retile.target = self
        retile.image = symbol("arrow.triangle.2.circlepath")
        menu.addItem(retile)

        menu.addItem(.separator())

        if !trusted {
            let grant = NSMenuItem(title: "Grant Accessibility…", action: #selector(openAccessibility),
                                   keyEquivalent: "")
            grant.target = self
            grant.image = symbol("exclamationmark.triangle")
            menu.addItem(grant)
            menu.addItem(.separator())
        }

        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        settings.image = symbol("gearshape")
        menu.addItem(settings)

        let help = NSMenuItem(title: "Pulsar Help", action: #selector(showHelp), keyEquivalent: "?")
        help.target = self
        help.image = symbol("questionmark.circle")
        menu.addItem(help)

        menu.addItem(.separator())

        let about = NSMenuItem(title: "About Pulsar", action: #selector(showAboutPanel), keyEquivalent: "")
        about.target = self
        about.image = symbol("info.circle")
        menu.addItem(about)

        let quit = NSMenuItem(title: "Quit Pulsar", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// Numbers first, then letters — a stable, predictable order for the submenu.
    private func orderedWorkspaceNames() -> [String] {
        var names = Set(store.workspaces.keys)
        names.insert(store.current)
        let numbers = names.filter { $0.count == 1 && $0.first!.isNumber }.sorted()
        let letters = names.filter { $0.count == 1 && $0.first!.isLetter }.sorted()
        return numbers + letters
    }

    @objc func selectWorkspace(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        switchWorkspace(name)
    }

    @objc func toggleFocusFollowsMouse() {
        focusFollowsMouse.toggle()
        UserDefaults.standard.set(focusFollowsMouse, forKey: "focusFollowsMouse")
        rebuildMenu()
    }

    @objc func toggleFollow() {
        followAppAcrossWorkspaces.toggle()
        UserDefaults.standard.set(followAppAcrossWorkspaces, forKey: "followAppAcrossWorkspaces")
        rebuildMenu()
    }

    @objc func toggleOrientationFromMenu() {
        toggleOrientation()
    }

    // MARK: - About

    @objc func showAboutPanel() {
        if let existing = aboutWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 300),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "About Pulsar"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.center()

        let content = NSView(frame: window.contentLayoutRect)

        let iconView = NSImageView(frame: NSRect(x: 0, y: 0, width: 96, height: 96))
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown

        func label(_ text: String, size: CGFloat, weight: NSFont.Weight,
                   color: NSColor, width: CGFloat) -> NSTextField {
            let field = NSTextField(wrappingLabelWithString: text)
            field.font = NSFont.systemFont(ofSize: size, weight: weight)
            field.textColor = color
            field.alignment = .center
            field.frame.size.width = width
            field.isSelectable = false
            return field
        }

        let name = label("Pulsar", size: 20, weight: .semibold, color: .labelColor, width: 320)
        let version = label("Version 1.1  ·  \(store.byHash.count) windows managed",
                            size: 11, weight: .regular, color: .secondaryLabelColor, width: 320)
        let tagline = label("A tiling window manager built for speed:\nno polling, no timers, no work when idle.",
                            size: 12, weight: .regular, color: .secondaryLabelColor, width: 300)

        var y: CGFloat = 250
        iconView.frame.origin = NSPoint(x: (360 - 96) / 2, y: y - 96)
        y -= 96 + 14
        name.frame.origin = NSPoint(x: 20, y: y - 26); y -= 26 + 4
        version.frame.origin = NSPoint(x: 20, y: y - 16); y -= 16 + 14
        tagline.frame.origin = NSPoint(x: 30, y: y - 34)

        content.addSubview(iconView)
        content.addSubview(name)
        content.addSubview(version)
        content.addSubview(tagline)
        window.contentView = content

        aboutWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
