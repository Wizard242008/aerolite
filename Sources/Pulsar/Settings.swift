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

        let width: CGFloat = 460
        let margin: CGFloat = 20
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 0, bottom: 18, right: 0)

        // Every row is pinned to the same left and right margins by hand. Relying on the stack's
        // alignment to do it produced rows at three different left edges.
        @discardableResult
        func add(_ view: NSView, spacingAfter: CGFloat) -> NSView {
            stack.addArrangedSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: margin),
                view.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -margin),
            ])
            stack.setCustomSpacing(spacingAfter, after: view)
            return view
        }
        stack.translatesAutoresizingMaskIntoConstraints = false

        func heading(_ text: String) -> NSView {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            return label
        }

        /// A checkbox with its explanation indented to the label, not to the checkbox box.
        func option(_ title: String, on: Bool, action: Selector, note: String) -> NSView {
            let container = NSView()
            let box = NSButton(checkboxWithTitle: title, target: self, action: action)
            box.state = on ? .on : .off
            let detail = NSTextField(wrappingLabelWithString: note)
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = .secondaryLabelColor
            detail.preferredMaxLayoutWidth = width - margin * 2 - 20

            for view in [box, detail] as [NSView] {
                view.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(view)
            }
            NSLayoutConstraint.activate([
                box.topAnchor.constraint(equalTo: container.topAnchor),
                box.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                box.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
                detail.topAnchor.constraint(equalTo: box.bottomAnchor, constant: 2),
                detail.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
                detail.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                detail.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
            return container
        }

        add(heading("BEHAVIOUR"), spacingAfter: 6)

        let follow = option("Follow an app to its workspace", on: followAppAcrossWorkspaces,
                            action: #selector(settingsToggleFollow),
                            note: "Clicking an app in the Dock, or reaching it with Cmd-Tab, jumps to the workspace holding its window.")
        add(follow, spacingAfter: 10)

        let hover = option("Focus follows mouse", on: focusFollowsMouse,
                           action: #selector(settingsToggleHover),
                           note: "Moving the pointer over a window focuses it. Costs nothing while the mouse is still; each focus change costs about 10 ms.")
        add(hover, spacingAfter: 10)

        let restore = option("Restore my layout at launch", on: restoreOnLaunch,
                             action: #selector(settingsToggleRestore),
                             note: "Puts windows back on their workspaces and reopens the workspace you were using.")
        add(restore, spacingAfter: 20)

        add(heading("KEYS"), spacingAfter: 8)

        let modifierRow = NSView()
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
        for view in [modifierLabel, popup] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            modifierRow.addSubview(view)
        }
        NSLayoutConstraint.activate([
            modifierLabel.leadingAnchor.constraint(equalTo: modifierRow.leadingAnchor),
            modifierLabel.centerYAnchor.constraint(equalTo: modifierRow.centerYAnchor),
            popup.trailingAnchor.constraint(equalTo: modifierRow.trailingAnchor),
            popup.topAnchor.constraint(equalTo: modifierRow.topAnchor),
            popup.bottomAnchor.constraint(equalTo: modifierRow.bottomAnchor),
            popup.leadingAnchor.constraint(greaterThanOrEqualTo: modifierLabel.trailingAnchor, constant: 12),
        ])
        add(modifierRow, spacingAfter: 4)

        let modifierNote = NSTextField(wrappingLabelWithString:
            "Applies to focus, move, resize, layout and workspace shortcuts. Shift is added for the “move” variants.")
        modifierNote.font = .systemFont(ofSize: 11)
        modifierNote.textColor = .secondaryLabelColor
        modifierNote.preferredMaxLayoutWidth = width - margin * 2 - 20
        add(modifierNote, spacingAfter: 20)

        add(heading("ACTIONS"), spacingAfter: 8)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.alignment = .centerY
        // The Accessibility button only belongs here when the permission is actually missing; four
        // buttons do not fit the window and the first one was being truncated to an ellipsis.
        var actions: [(String, Selector)] = [("Re-tile Now", #selector(settingsRetile))]
        if !AXIsProcessTrusted() {
            actions.append(("Grant Accessibility…", #selector(openAccessibility)))
        }
        actions.append(("Check for Updates…", #selector(settingsCheckForUpdates)))
        actions.append(("Show Log", #selector(settingsShowLog)))

        for (title, action) in actions {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .rounded
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            buttons.addArrangedSubview(button)
        }
        add(buttons, spacingAfter: 14)

        let footer = NSTextField(wrappingLabelWithString:
            "Changes apply immediately and are stored in com.devansh.pulsar.plist.")
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .tertiaryLabelColor
        footer.preferredMaxLayoutWidth = width - margin * 2
        add(footer, spacingAfter: 0)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 420),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Pulsar Settings"
        window.contentView = NSView()
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
        ])
        // Fix the width rather than letting the widest row decide it.
        stack.widthAnchor.constraint(equalToConstant: width).isActive = true
        window.setContentSize(NSSize(width: width, height: stack.fittingSize.height))
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

    // MARK: - Updates

    func checkForUpdates(userInitiated: Bool) {
        Updater.check { [weak self] result in
            guard let self else { return }
            switch result {
            case .upToDate(let current):
                if userInitiated {
                    self.alert("You’re up to date", "Pulsar \(current) is the latest version.")
                }
            case .available(let release):
                self.present(release)
            case .failed(let message):
                if userInitiated { self.alert("Couldn’t check for updates", message) }
            }
        }
    }

    /// Checked once a day in the background; never blocks launch.
    func autoCheckForUpdates() {
        let defaults = UserDefaults.standard
        let last = defaults.double(forKey: "lastUpdateCheck")
        guard Date().timeIntervalSince1970 - last > 86_400 else { return }
        defaults.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
        Updater.check { [weak self] result in
            if case .available(let release) = result { self?.present(release) }
        }
    }

    private func alert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func present(_ release: Updater.Release) {
        let alert = NSAlert()
        alert.messageText = "Pulsar \(release.version) is available"
        alert.informativeText = release.notes.isEmpty
            ? "You’re running \(Updater.currentVersion)."
            : String(release.notes.prefix(700))
        alert.addButton(withTitle: "Install Update")
        alert.addButton(withTitle: "Release Notes")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Updater.install(release) { [weak self] error in
                if let error { self?.alert("Update failed", error) }
            }
        case .alertSecondButtonReturn:
            if let url = release.pageURL { NSWorkspace.shared.open(url) }
        default:
            break
        }
    }

    @objc func settingsCheckForUpdates() { checkForUpdates(userInitiated: true) }

    // MARK: - Help

    @objc func showHelp() {
        if let existing = helpWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 660),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Pulsar Help"
        window.center()

        // Built explicitly: storage → layout manager → container → view. The convenience
        // initialisers are convenient right up until one of them lays out against a nil manager.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 680, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 680, height: 620),
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

    /// Renders the bundled README for display.
    ///
    /// A small, purpose-built Markdown renderer: headings, bullets, fenced code, aligned tables and
    /// inline bold / code / links. Deliberately not `NSAttributedString(markdown:)` — the document
    /// is ours, so a predictable subset beats a general parser that can fail at runtime.
    static func render(_ markdown: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let bodyFont = NSFont.systemFont(ofSize: 13)
        let codeFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let boldBody = NSFont.systemFont(ofSize: 13, weight: .semibold)

        func style(before: CGFloat, after: CGFloat, indent: CGFloat = 0) -> NSParagraphStyle {
            let p = NSMutableParagraphStyle()
            p.paragraphSpacingBefore = before
            p.paragraphSpacing = after
            p.headIndent = indent
            p.firstLineHeadIndent = indent
            p.lineSpacing = 1.5
            return p
        }

        /// Handles **bold**, `code` and [label](url) inside a line.
        func inline(_ text: String, font: NSFont, color: NSColor = .labelColor) -> NSAttributedString {
            let result = NSMutableAttributedString()
            let pattern = try! NSRegularExpression(pattern: #"(\*\*[^*]+\*\*)|(`[^`]+`)|(\[[^\]]+\]\([^)]+\))"#)
            let ns = text as NSString
            var cursor = 0
            let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]

            for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                if match.range.location > cursor {
                    result.append(NSAttributedString(string: ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)), attributes: base))
                }
                let token = ns.substring(with: match.range)
                if token.hasPrefix("**") {
                    let inner = token.dropFirst(2).dropLast(2)
                    result.append(NSAttributedString(string: String(inner), attributes: [
                        .font: NSFont.systemFont(ofSize: font.pointSize, weight: .semibold),
                        .foregroundColor: color,
                    ]))
                } else if token.hasPrefix("`") {
                    let inner = token.dropFirst().dropLast()
                    result.append(NSAttributedString(string: String(inner), attributes: [
                        .font: codeFont,
                        .foregroundColor: NSColor.labelColor,
                        .backgroundColor: NSColor.labelColor.withAlphaComponent(0.07),
                    ]))
                } else if let open = token.firstIndex(of: "["),
                          let close = token.firstIndex(of: "]"),
                          let urlStart = token.firstIndex(of: "(") {
                    let label = String(token[token.index(after: open)..<close])
                    let url = String(token[token.index(after: urlStart)..<token.index(before: token.endIndex)])
                    var attributes = base
                    attributes[.foregroundColor] = NSColor.linkColor
                    if let link = URL(string: url) { attributes[.link] = link }
                    result.append(NSAttributedString(string: label, attributes: attributes))
                } else {
                    result.append(NSAttributedString(string: token, attributes: base))
                }
                cursor = match.range.location + match.range.length
            }
            if cursor < ns.length {
                result.append(NSAttributedString(string: ns.substring(from: cursor), attributes: base))
            }
            return result
        }

        /// Visible length of a cell, ignoring markdown punctuation.
        func visibleLength(_ text: String) -> Int {
            text.replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "`", with: "")
                .count
        }

        func append(_ string: NSAttributedString, spacing: NSParagraphStyle) {
            let mutable = NSMutableAttributedString(attributedString: string)
            mutable.addAttribute(.paragraphStyle, value: spacing,
                                 range: NSRange(location: 0, length: mutable.length))
            out.append(mutable)
            out.append(NSAttributedString(string: "\n"))
        }

        // Collect lines first: tables need a pass to size their columns.
        // The README carries a little HTML for its GitHub header; strip the tags, keep the text.
        var prepared = markdown
        for (pattern, replacement) in [("<h1[^>]*>", "# "), ("</h1>", ""),
                                       ("<h2[^>]*>", "## "), ("</h2>", ""),
                                       ("<br\\s*/?>", "\n")] {
            prepared = prepared.replacingOccurrences(of: pattern, with: replacement,
                                                     options: .regularExpression)
        }
        let sanitised = prepared.replacingOccurrences(of: "<[^>]+>", with: "",
                                                      options: .regularExpression)
        let lines = sanitised.components(separatedBy: .newlines)
        var index = 0
        var inCode = false
        var lastWasBlank = false

        while index < lines.count {
            let line = inCode ? lines[index] : lines[index].trimmingCharacters(in: .whitespaces)

            // The README uses a little HTML for its header (centred title, badges, <details>).
            // In the Help window those tags are noise, so they are skipped and their markdown
            // contents render normally.
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.hasPrefix("<") { index += 1; continue }
            if line.hasPrefix("![") { index += 1; continue }      // images have nothing to show here
            if line.hasPrefix("```") { inCode.toggle(); index += 1; continue }

            if inCode {
                append(inline(line.isEmpty ? " " : line, font: codeFont), spacing: style(before: 0, after: 0))
                index += 1
                continue
            }

            // Table block: consecutive lines starting with |
            if line.hasPrefix("|") {
                var rows: [[String]] = []
                while index < lines.count, lines[index].hasPrefix("|") {
                    var cells = lines[index].split(separator: "|", omittingEmptySubsequences: false)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                    // The leading and trailing entries are the delimiters; interior empties are
                    // real cells (an unlabelled first column), so they must be kept.
                    if cells.first?.isEmpty == true { cells.removeFirst() }
                    if cells.last?.isEmpty == true { cells.removeLast() }
                    if !cells.allSatisfy({ $0.allSatisfy { $0 == "-" || $0 == ":" } }) {
                        rows.append(cells)
                    }
                    index += 1
                }
                let columnCount = rows.map(\.count).max() ?? 0
                var widths = [Int](repeating: 0, count: columnCount)
                for row in rows {
                    for (column, cell) in row.enumerated() where column < columnCount {
                        widths[column] = max(widths[column], visibleLength(cell))
                    }
                }
                for (rowIndex, row) in rows.enumerated() {
                    let font = rowIndex == 0
                        ? NSFont.monospacedSystemFont(ofSize: 10.5, weight: .semibold)
                        : NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
                    let color: NSColor = rowIndex == 0 ? .labelColor : .secondaryLabelColor

                    let line = NSMutableAttributedString()
                    for column in 0..<columnCount {
                        let cell = column < row.count ? row[column] : ""
                        line.append(inline(cell, font: font, color: color))
                        let padding = max(0, widths[column] - visibleLength(cell)) + (column < columnCount - 1 ? 2 : 0)
                        line.append(NSAttributedString(string: String(repeating: " ", count: padding),
                                                       attributes: [.font: font]))
                    }
                    append(line, spacing: style(before: 0, after: rowIndex == rows.count - 1 ? 8 : 0))
                }
                continue
            }

            if line.hasPrefix("# ") {
                append(inline(String(line.dropFirst(2)), font: .systemFont(ofSize: 24, weight: .bold)),
                       spacing: style(before: 4, after: 10))
            } else if line.hasPrefix("## ") {
                append(inline(String(line.dropFirst(3)), font: .systemFont(ofSize: 15, weight: .bold)),
                       spacing: style(before: 16, after: 4))
            } else if line.hasPrefix("### ") {
                append(inline(String(line.dropFirst(4)), font: boldBody), spacing: style(before: 12, after: 2))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                append(inline("•  " + String(line.dropFirst(2)), font: bodyFont),
                       spacing: style(before: 1, after: 1, indent: 12))
            } else if line.hasPrefix("> ") {
                append(inline(String(line.dropFirst(2)), font: bodyFont, color: .secondaryLabelColor),
                       spacing: style(before: 2, after: 6, indent: 12))
            } else if line == "---" {
                append(NSAttributedString(string: String(repeating: "─", count: 56),
                                          attributes: [.font: codeFont, .foregroundColor: NSColor.tertiaryLabelColor]),
                       spacing: style(before: 6, after: 6))
            } else if line.isEmpty {
                if !lastWasBlank { out.append(NSAttributedString(string: "\n")) }
                lastWasBlank = true
                index += 1
                continue
            } else {
                append(inline(line, font: bodyFont), spacing: style(before: 0, after: 3))
            }
            if !line.isEmpty { lastWasBlank = false }
            index += 1
        }
        while out.string.hasPrefix("\n") {
            out.deleteCharacters(in: NSRange(location: 0, length: 1))
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
