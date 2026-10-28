# Pulsar

A tiling window manager for macOS, in the spirit of Hyprland: windows are arranged automatically,
workspaces are switched from the keyboard, and you rarely touch a mouse.

![icon](docs/icon.png)

## Similar to Hyprland

If you have used Hyprland on Linux, the model is the same:

| | Hyprland | Pulsar |
|---|---|---|
| Platform | Linux (Wayland) | macOS (Accessibility APIs) |
| Tiling | dynamic, dwindle / master | split for two windows, grid for three or more |
| Workspaces | numbered, per monitor | `1`–`9` plus `a`–`z`, single display |
| Focus / move keys | `Super` + `h j k l` | `alt` + `h j k l` |
| Directional move | `Super` + `Shift` + arrow keys | `alt` + `Shift` + `h j k l` |
| Resize | `Super` + right-drag or binds | `alt-minus` / `alt-equal` |
| Config file | `hyprland.conf` | none — the keys are fixed |
| Gaps and borders | configurable | none, panes sit edge to edge |

The differences are mostly macOS's: windows keep their native title bars and traffic lights, there
are no rounded corners or gaps, and the whole application is a single menu-bar agent rather than a
compositor. Everything that makes Hyprland feel the way it does — dynamic tiling, workspaces that
move with you, keyboard-first control — is here.

## Requirements

- macOS 13 or later, Apple silicon (the build script targets `arm64-apple-macos13.0`)
- Accessibility permission, granted once
- No dependencies: no Swift Package Manager step, no third-party libraries

## Install

```bash
git clone https://github.com/Wizard242008/pulsar.git
cd pulsar
./build.sh
```

`build.sh` compiles with `swiftc`, generates the icon, signs the app, copies it to
`/Applications/Pulsar.app` and kills any running copy. It leaves exactly one bundle on disk.

To start it:

```bash
open /Applications/Pulsar.app
```

It also starts at login through `~/Library/LaunchAgents/com.devansh.pulsar.plist`.

## Permission

On first launch macOS asks for Accessibility. If it doesn't, or you dismissed it:

1. Open **System Settings → Privacy & Security → Accessibility**
2. Enable **Pulsar** (use **+** and choose `/Applications/Pulsar.app` if it isn't listed)

Until this is granted the app cannot read or move windows, so nothing happens. The menu shows
"Accessibility permission needed" while it is missing.

## Usage

Click the star in the menu bar to see the current workspace, how many windows are on it, and to
switch workspaces. Everything else is keyboard:

| Keys | Action |
|---|---|
| `alt-h` `alt-j` `alt-k` `alt-l` | focus left / down / up / right |
| `alt-shift-h/j/k/l` | move the focused window in that direction |
| `alt-minus` / `alt-equal` | shrink / grow the focused window |
| `alt-slash` | toggle horizontal / vertical split |
| `alt-1…9` | switch to workspace 1–9 |
| `alt-shift-1…9` | send the focused window to workspace 1–9 |
| `alt-a…z` (except `h j k l`) | switch to that lettered workspace |
| `alt-shift-<letter>` | send the focused window to that workspace |

Clicking an app in the Dock, or switching to it with Cmd-Tab, jumps to the workspace holding its
window. Turn that off with **Follow App to Its Workspace** in the menu.

**Focus Follows Mouse** in the menu gives Hyprland-style hover focus: moving the pointer over a
window focuses it, and entering a workspace focuses the pane under the pointer. It costs nothing
while the mouse is still (0 wakeups/s); it only does work when the pointer actually moves. Turn it
off if you prefer focus to stay where the keyboard put it.

## Behaviour

- **One window fills the screen, two split it, three or more form a grid.** Designed for a small
  number of windows per workspace.
- **Window minimum sizes are respected.** macOS provides no way to ask an app for its minimum size,
  so it is measured: if a window refuses a size and stays larger, that size is recorded per app and
  the layout allocates around it. If the minimums cannot all fit, panes run past the screen edge
  rather than overlapping.
- **A size you set stays set.** Dragging a divider is folded back into the layout ratio, and sizes
  are saved per window, so they survive refreshes and restarts.
- **Full-screen windows are left alone.** A window reporting `AXFullScreen` is removed from
  management entirely: never tiled, never moved off-screen.
- **Placement survives restarts.** Each window is remembered by app bundle id plus window title,
  with a per-app fallback for when the title has changed. After a restart or logout, windows return
  to the workspace they were on.

## Why it is efficient

Everything is driven by events rather than by checking the state of the system on a schedule.

1. **Nothing runs while you are idle.** There are no timers, no polling loop, no mouse monitors and
   no keyboard event tap. The process sleeps until one of its hotkeys fires or an app launches,
   activates, hides or quits.
2. **Nothing happens on mouse click.** Clicking a window does not trigger a layout pass, because the
   layout cannot have changed.
3. **Notifications are coalesced.** Launching an app emits several notifications; they collapse into
   a single refresh 25 ms later instead of several passes.
4. **Geometry is written only when it differs.** Every Accessibility call is synchronous IPC, so the
   current frame is read first and the write is skipped when it already matches.
5. **Hotkeys cost nothing when idle.** Carbon hotkeys live in the window server's hotkey table; a
   `CGEventTap` would run code on every keystroke system-wide.
6. **Layout is arithmetic.** Positions come from dividing a rectangle. There is no scene graph, no
   animation and no re-entrant layout pass.

Measured on an 8 GB M2 MacBook Pro, 1680×1050 display: 0.0 wakeups/s and ~0.03% CPU while idle,
~23 MB physical footprint, ~250 KB on disk.

## Workspaces

Workspaces are named `1`–`9` and `a`–`z`, excluding `h`, `j`, `k`, `l` because those are focus keys.
Windows on other workspaces are moved to the bottom-left corner of the screen, one pixel past the
edges, where they cannot be seen or clicked; switching back moves them into place.

The current workspace, the layout orientation, each window's size and which workspace each window
belongs to are stored in `~/Library/Preferences/com.devansh.pulsar.plist`.

## Troubleshooting

The app logs to `~/Library/Logs/Pulsar.log`. The most useful line is:

```
pulsar: refresh ws=b tracked=5 onScreen=5 trusted=true
```

`trusted=false` means the Accessibility permission is missing or was reset.

`build/wmpeek` reads window geometry without needing Accessibility:

```bash
./build/wmpeek --check     # overlap count, pane positions, total span
./build/wmpeek --parked    # windows hidden on other workspaces
```

Force a refresh, or dump the app's own view of every window:

```bash
notifyutil -p com.devansh.pulsar.retile
notifyutil -p com.devansh.pulsar.dump     # then read ~/Library/Logs/Pulsar.log
```

If the Accessibility permission appears to reset after a rebuild, that is a signing problem: an
ad-hoc signature's identity is the binary hash, so a new build looks like a new app to macOS.
`build.sh` signs with a certificate instead, which keeps the grant across rebuilds.

## Building

`swift build` does not work on this machine: the CommandLineTools install has a broken XCBuild
(`Unknown error parsing property list`). `build.sh` calls `swiftc` directly:

```bash
swiftc -O -swift-version 5 -target arm64-apple-macos13.0 Sources/Pulsar/*.swift -o build/Pulsar
```

| File | Purpose |
|---|---|
| `Sources/Pulsar/main.swift` | entry point, `--diagnose`, `--render-glyph` |
| `Sources/Pulsar/Controller.swift` | refresh, layout application, workspaces, persistence |
| `Sources/Pulsar/AX.swift` | Accessibility wrappers: windows, frames, attributes |
| `Sources/Pulsar/Layout.swift` | pure geometry, no AX: splits, grid, minimum-size allocation |
| `Sources/Pulsar/Model.swift` | `Win`, `Orientation`, `Store` |
| `Sources/Pulsar/Hotkeys.swift` | Carbon hotkey registration |
| `Sources/Pulsar/UI.swift` | menu bar item, menu, About panel |
| `Tools/makeicon` | draws the app icon and writes every iconset size |
| `Tools/wmpeek` | reads window geometry without Accessibility |

## License

MIT — see `LICENSE`.
