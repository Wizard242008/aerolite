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

    func rebuildMenu() {
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
        layoutItem.keyEquivalentModifierMask = [hotkeyModifierName == "control" ? .control
                                                : hotkeyModifierName == "command" ? .command : .option]
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

        // Hotkeys: enabled items that also work when clicked, so the menu is an accurate mirror of
        // the current binding set (it is rebuilt every time the menu opens).
        let hotkeysItem = NSMenuItem(title: "Hotkeys", action: nil, keyEquivalent: "")
        hotkeysItem.image = symbol("keyboard")
        let hotkeysMenu = NSMenu()
        let modMask: NSEvent.ModifierFlags = {
            switch hotkeyModifierName {
            case "control": return .control
            case "command": return .command
            default:        return .option
            }
        }()

        func binding(_ title: String, key: String, shift: Bool, action: Selector,
                     represented: Any? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            item.keyEquivalentModifierMask = shift ? [modMask, .shift] : [modMask]
            item.representedObject = represented
            return item
        }

        hotkeysMenu.addItem(binding("Focus Left", key: "h", shift: false, action: #selector(menuFocusLeft)))
        hotkeysMenu.addItem(binding("Focus Down", key: "j", shift: false, action: #selector(menuFocusDown)))
        hotkeysMenu.addItem(binding("Focus Up", key: "k", shift: false, action: #selector(menuFocusUp)))
        hotkeysMenu.addItem(binding("Focus Right", key: "l", shift: false, action: #selector(menuFocusRight)))
        hotkeysMenu.addItem(.separator())
        hotkeysMenu.addItem(binding("Move Left", key: "h", shift: true, action: #selector(menuMoveLeft)))
        hotkeysMenu.addItem(binding("Move Down", key: "j", shift: true, action: #selector(menuMoveDown)))
        hotkeysMenu.addItem(binding("Move Up", key: "k", shift: true, action: #selector(menuMoveUp)))
        hotkeysMenu.addItem(binding("Move Right", key: "l", shift: true, action: #selector(menuMoveRight)))
        hotkeysMenu.addItem(.separator())
        hotkeysMenu.addItem(binding("Shrink Window", key: "-", shift: false, action: #selector(menuShrink)))
        hotkeysMenu.addItem(binding("Grow Window", key: "=", shift: false, action: #selector(menuGrow)))
        hotkeysMenu.addItem(binding("Toggle Layout", key: "/", shift: false, action: #selector(menuToggleLayout)))
        hotkeysMenu.addItem(.separator())

        let hotkeyWorkspaces = NSMenuItem(title: "Switch Workspace", action: nil, keyEquivalent: "")
        let hotkeyWorkspaceMenu = NSMenu()
        for n in 1...9 {
            hotkeyWorkspaceMenu.addItem(binding("\(n)", key: "\(n)", shift: false,
                                                action: #selector(menuSwitchWorkspace), represented: "\(n)"))
        }
        for letter in "abcdefghijklmnopqrstuvwxyz" where !"hjkl".contains(letter) {
            hotkeyWorkspaceMenu.addItem(binding(String(letter), key: String(letter), shift: false,
                                                action: #selector(menuSwitchWorkspace),
                                                represented: String(letter)))
        }
        hotkeyWorkspaces.submenu = hotkeyWorkspaceMenu
        hotkeysMenu.addItem(hotkeyWorkspaces)

        let sendItem = NSMenuItem(title: "Send Window to Workspace", action: nil, keyEquivalent: "")
        let sendMenu = NSMenu()
        for n in 1...9 {
            sendMenu.addItem(binding("\(n)", key: "\(n)", shift: true,
                                     action: #selector(menuSendToWorkspace), represented: "\(n)"))
        }
        sendItem.submenu = sendMenu
        hotkeysMenu.addItem(sendItem)

        hotkeysItem.submenu = hotkeysMenu
        menu.addItem(hotkeysItem)

        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        settings.image = symbol("gearshape")
        menu.addItem(settings)

        let updates = NSMenuItem(title: "Check for Updates…", action: #selector(settingsCheckForUpdates),
                                 keyEquivalent: "")
        updates.target = self
        updates.image = symbol("arrow.down.circle")
        menu.addItem(updates)

        let help = NSMenuItem(title: "Pulsar Help", action: #selector(showHelp), keyEquivalent: "?")
        help.target = self
        help.image = symbol("questionmark.circle")
        menu.addItem(help)

        menu.addItem(.separator())

        let about = NSMenuItem(title: "About Pulsar", action: #selector(showAboutPanel), keyEquivalent: "")
        about.target = self
        about.image = symbol("info.circle")
        menu.addItem(about)

        menu.addItem(.separator())

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

    // Menu mirrors of the keyboard commands. The Carbon hotkey fires first for the same
    // combination, so these exist for clicking and for showing the current bindings.
    @objc func menuFocusLeft()  { focus(.left) }
    @objc func menuFocusRight() { focus(.right) }
    @objc func menuFocusUp()    { focus(.up) }
    @objc func menuFocusDown()  { focus(.down) }
    @objc func menuMoveLeft()   { move(.left) }
    @objc func menuMoveRight()  { move(.right) }
    @objc func menuMoveUp()     { move(.up) }
    @objc func menuMoveDown()   { move(.down) }
    @objc func menuShrink()     { resize(grow: false) }
    @objc func menuGrow()       { resize(grow: true) }
    @objc func menuToggleLayout() { toggleOrientation() }

    @objc func menuSwitchWorkspace(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        switchWorkspace(name)
    }

    @objc func menuSendToWorkspace(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        moveToWorkspace(name)
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

        let width: CGFloat = 340
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 22, bottom: 18, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 96),
            icon.heightAnchor.constraint(equalToConstant: 96),
        ])

        let name = NSTextField(labelWithString: "Pulsar")
        name.font = .systemFont(ofSize: 22, weight: .semibold)
        name.alignment = .center

        let version = NSTextField(labelWithString: "Version \(Updater.currentVersion)")
        version.font = .systemFont(ofSize: 11)
        version.textColor = .secondaryLabelColor
        version.alignment = .center

        let tagline = NSTextField(labelWithString: "A tiling window manager for macOS.")
        tagline.font = .systemFont(ofSize: 12)
        tagline.textColor = .secondaryLabelColor
        tagline.alignment = .center
        tagline.preferredMaxLayoutWidth = width - 44

        stack.addArrangedSubview(icon)
        stack.setCustomSpacing(16, after: icon)
        stack.addArrangedSubview(name)
        stack.setCustomSpacing(2, after: name)
        stack.addArrangedSubview(version)
        stack.setCustomSpacing(14, after: version)
        stack.addArrangedSubview(tagline)


        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 260),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "About Pulsar"
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.contentView = NSView()
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor),
        ])
        window.setContentSize(NSSize(width: width, height: stack.fittingSize.height))
        window.center()

        aboutWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

}
