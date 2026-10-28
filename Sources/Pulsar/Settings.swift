import AppKit

// Pulsar's Settings and Help windows.
//
// Kept in AppKit rather than SwiftUI: the rest of the app is AppKit, the windows are small, and a
// plain stack view of native controls inherits the system look without a second UI framework.

extension Controller {

    // MARK: - Settings

    @objc func showSettings() {
        if let existing = settingsWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let width: CGFloat = 440
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 20, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false

        func heading(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            return label
        }

        func checkbox(_ title: String, on: Bool, action: Selector) -> NSButton {
            let button = NSButton(checkboxWithTitle: title, target: self, action: action)
            button.state = on ? .on : .off
            return button
        }

        func note(_ text: String) -> NSTextField {
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = NSFont.systemFont(ofSize: 11)
            label.textColor = .tertiaryLabelColor
            label.preferredMaxLayoutWidth = width - 44
            return label
        }

        stack.addArrangedSubview(heading("BEHAVIOUR"))
        stack.addArrangedSubview(checkbox("Follow an app to its workspace", on: followAppAcrossWorkspaces,
                                          action: #selector(settingsToggleFollow)))
        stack.addArrangedSubview(note("Clicking an app in the Dock or via Cmd-Tab jumps to the workspace holding its window."))
        stack.addArrangedSubview(checkbox("Focus follows mouse", on: focusFollowsMouse,
                                          action: #selector(settingsToggleHover)))
        stack.addArrangedSubview(note("Moving the pointer over a window focuses it. Costs nothing while the mouse is still; every focus change costs about 10 ms."))
        stack.addArrangedSubview(checkbox("Restore my layout at launch", on: restoreOnLaunch,
                                          action: #selector(settingsToggleRestore)))
        stack.addArrangedSubview(note("Puts windows back on the workspaces they were on, and reopens the workspace you were using."))

        stack.setCustomSpacing(18, after: stack.arrangedSubviews.last!)

        stack.addArrangedSubview(heading("KEYS"))
        let modifierRow = NSStackView()
        modifierRow.orientation = .horizontal
        modifierRow.spacing = 8
        let modifierLabel = NSTextField(labelWithString: "Modifier for all shortcuts")
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: ["Option ⌥", "Control ⌃", "Command ⌘"])
        switch hotkeyModifierName {
        case "control": popup.selectItem(at: 1)
        case "command": popup.selectItem(at: 2)
        default: popup.selectItem(at: 0)
        }
        popup.target = self
        popup.action = #selector(settingsModifierChanged(_:))
        modifierRow.addArrangedSubview(modifierLabel)
        modifierRow.addArrangedSubview(popup)
        stack.addArrangedSubview(modifierRow)
        stack.addArrangedSubview(note("Applies to focus, move, resize, layout and workspace shortcuts. Shift is added for the “move” variants."))

        stack.setCustomSpacing(18, after: stack.arrangedSubviews.last!)

        stack.addArrangedSubview(heading("ACTIONS"))
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        for (title, action) in [("Re-tile Now", #selector(settingsRetile)),
                                ("Grant Accessibility…", #selector(openAccessibility)),
                                ("Show Log", #selector(settingsShowLog))] {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .rounded
            buttons.addArrangedSubview(button)
        }
        stack.addArrangedSubview(buttons)

        let footer = note("Changes apply immediately and are stored in ~/Library/Preferences/com.devansh.pulsar.plist.")
        stack.addArrangedSubview(footer)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 460),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Pulsar Settings"
        window.contentView = NSView()
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
        ])
        window.setContentSize(stack.fittingSize)
        window.center()

        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func settingsToggleFollow(_ sender: NSButton) {
        followAppAcrossWorkspaces = (sender.state == .on)
        UserDefaults.standard.set(followAppAcrossWorkspaces, forKey: "followAppAcrossWorkspaces")
    }

    @objc func settingsToggleHover(_ sender: NSButton) {
        focusFollowsMouse = (sender.state == .on)
        UserDefaults.standard.set(focusFollowsMouse, forKey: "focusFollowsMouse")
    }

    @objc func settingsToggleRestore(_ sender: NSButton) {
        restoreOnLaunch = (sender.state == .on)
        UserDefaults.standard.set(restoreOnLaunch, forKey: "restoreOnLaunch")
    }

    @objc func settingsModifierChanged(_ sender: NSPopUpButton) {
        let names = ["option", "control", "command"]
        let name = names[max(0, min(sender.indexOfSelectedItem, names.count - 1))]
        UserDefaults.standard.set(name, forKey: "hotkeyModifier")
        reRegisterHotkeys()
    }

    @objc func settingsRetile() { refresh() }

    @objc func settingsShowLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/Pulsar.log"))
    }

    // MARK: - Help

    @objc func showHelp() {
        if let existing = helpWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 640),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Pulsar Help"
        window.center()

        // Built explicitly: storage → layout manager → container → view. The convenience
        // initialisers are convenient right up until one of them lays out against a nil manager.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 620, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 620, height: 600),
                                  textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 18, height: 18)
        textView.autoresizingMask = NSView.AutoresizingMask.width

        let markdown = (Bundle.main.url(forResource: "README", withExtension: "md")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) })
            ?? Self.fallbackHelp

        storage.setAttributedString(Self.render(markdown))

        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(scroll)

        helpWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// A deliberately small Markdown renderer: headings, bullets, code blocks and table rows.
    /// No attributed-markdown parsing — the help text is documentation, not user content.
    static func render(_ markdown: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: 13)
        let mono = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)

        func append(_ text: String, font: NSFont, color: NSColor = .labelColor, spacing: CGFloat = 2) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacing = spacing
            out.append(NSAttributedString(string: text + "\n", attributes: [
                .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
            ]))
        }

        var inCode = false
        for line in markdown.components(separatedBy: .newlines) {
            if line.hasPrefix("```") { inCode.toggle(); continue }
            if inCode {
                append(line, font: mono)
            } else if line.hasPrefix("# ") {
                append(String(line.dropFirst(2)), font: .systemFont(ofSize: 22, weight: .bold), spacing: 8)
            } else if line.hasPrefix("## ") {
                append(String(line.dropFirst(3)), font: .systemFont(ofSize: 15, weight: .semibold), spacing: 6)
            } else if line.hasPrefix("|") {
                append(line, font: mono, spacing: 0)
            } else if line.hasPrefix("- ") {
                append("  •  " + line.dropFirst(2), font: body)
            } else if line.isEmpty {
                out.append(NSAttributedString(string: "\n"))
            } else {
                append(line, font: body)
            }
        }
        return out
    }

    static let fallbackHelp = """
    # Pulsar

    A tiling window manager for macOS.

    ## Keys
    alt + h / j / k / l      focus left / down / up / right
    alt + shift + h j k l    move the focused window
    alt + -  /  alt + =      shrink / grow
    alt + /                  toggle horizontal / vertical
    alt + 1…9                switch workspace
    alt + shift + 1…9        send window to workspace
    alt + a…z                lettered workspaces

    Settings are in the menu bar under “Settings…”.
    """

}
