# AeroLite

A minimal tiling window manager for macOS, built to replace AeroSpace on an 8 GB Mac where
AeroSpace's cost was noticeable. Same idea and almost the same keys — a fraction of the machinery.

| | AeroSpace | AeroLite |
|---|---|---|
| Bundle size | 19.9 MB | **0.2 MB** |
| Idle CPU | — | **0.01 s per 30 s (~0.03%)** |
| Physical footprint | — | **22.8 MB** |
| Polling / timers | yes | **none after startup** |
| Refresh on mouse-up | yes | **never** |
| Geometry writes | every layout pass | **only when the frame actually differs** |

![AeroLite icon](docs/icon.png)

## UI

AeroLite lives in the menu bar as a mono­chrome template glyph — one tall pane, two stacked — so it
inherits the system tint in light mode, dark mode and when the menu is open.

Opening it shows a live panel rather than a static menu:

- **Header** — current workspace, windows on it, and how many are managed in total
- **Workspaces** submenu — every workspace with its window count and a checkmark on the active one
- **Layout** — horizontal/vertical, reflecting the current state
- **Enabled**, **Re-tile Now**, **Grant Accessibility…** (only when permission is missing), **About**

The app icon is drawn in code (`Tools/makeicon`) rather than committed as a binary asset, so it can
be regenerated at any size: a squircle with three panes and one accent pane for the focused window.

## Install

```bash
./build.sh                       # compiles and signs into build/AeroLite.app
cp -R build/AeroLite.app /Applications/
open /Applications/AeroLite.app
```

Login startup is handled by `~/Library/LaunchAgents/com.devansh.aerolite.plist`.
The app runs as a menu-bar agent (`LSUIElement`): no Dock icon, no app-switcher entry.

## Permission

The first thing to check, always:

```bash
/Applications/AeroLite.app/Contents/MacOS/AeroLite --diagnose
```

It reports `trusted: YES/NO` from the app's own TCC identity. If `NO`, enable AeroLite in
**System Settings → Privacy & Security → Accessibility** (the menu-bar item "Grant Accessibility…"
opens that exact pane). Until then every AX call silently fails and the app manages nothing —
windows keep their old positions, which looks like "overlapping", but is really "untouched".

The menu-bar icon is a status light: **◧** working, **◧⚠** unpermitted.

## Keys

| Keys | Action |
|---|---|
| `alt-h` `alt-j` `alt-k` `alt-l` | focus left / down / up / right |
| `alt-shift-h/j/k/l` | move window in that direction |
| `alt-minus` / `alt-equal` | shrink / grow the focused window |
| `alt-slash` | toggle horizontal ↔ vertical tiling |
| `alt-1…9` / `alt-shift-1…9` | switch workspace / send window to workspace |
| `alt-a…z` (except `hjkl`) / `alt-shift-<letter>` | switch workspace / send window to workspace |

Registered with Carbon `RegisterEventHotKey`, not a `CGEventTap` — an event tap runs on every
keystroke system-wide, which is the usual reason a window manager burns idle CPU.

## Behaviour

- **Non-overlapping by construction.** `Layout.frames` partitions the visible screen; each pane's
  origin is the previous pane's edge, and the last pane takes the remainder. Equal thirds sum to
  exactly the screen width (unit-tested), so there is no seam to leak through.
- **One window fills the screen; two split it.** The layout is built for 1–2 windows per workspace,
  which is how this machine is actually used.
- **Full-screen is out of scope.** A window reporting `AXFullScreen` is removed from management
  entirely — never tiled, never parked. Parking full-screen windows is what leaves a user on a
  black screen with no way back. Geometry is used only as a safety check before moving a window
  off-screen, never to decide whether to manage it.
- **Clicking an app follows it.** Activating an app from the Dock or Cmd-Tab jumps to the workspace
  holding its window instead of doing nothing because the window is parked off-screen. It uses the
  window you last worked in when the app has several. Toggle it from the menu.
  *Known gap:* macOS sends no activation event when the app is already frontmost, so if you hotkey
  to an empty desktop while an app stays active and then click that same app, nothing happens.
- **Placement survives restarts.** Each window is remembered by app bundle id + window title, so
  after a relaunch or login it returns to the workspace it was on — the workspace itself, the
  orientation and the current workspace all persist. A renamed window (a new browser tab, an
  unsaved document) looks like a new window and lands on the current workspace: a safe fallback,
  never a lost window.
- **Other workspaces are hidden by parking** windows off-screen at x = −30000, re-verified on every
  refresh (apps restore their own frames on reactivation, so a one-shot park leaks).

## Why it is fast

1. **No idle work.** No timers, no polling, no mouse monitors. It wakes for hotkeys and for a
   handful of `NSWorkspace` notifications the system already broadcasts.
2. **Bursts are coalesced.** One app activation emits several notifications; they collapse into a
   single refresh 25 ms later.
3. **Writes are diffed.** Geometry is read from the window and compared before setting; if the
   window is already correct, nothing is sent.
4. **Truth over cache.** Frames are re-read from AX before every write. Diffing against a cached
   "last frame we wrote" is how windows stay overlapped forever once something else moves them.
5. **Single pass per event.** No per-window retry storms; a failed set is retried once in the
   opposite order (position→size vs size→position) because some apps accept only one.

## Layout of the source

| File | Role |
|---|---|
| `Sources/AeroLite/main.swift` | entry point, `--diagnose` |
| `Sources/AeroLite/AX.swift` | AX wrappers: windows, frames, attributes, full-screen detection |
| `Sources/AeroLite/Model.swift` | `Win` (identity = the `AXUIElement`'s `CFHash`), `Orientation`, `Store` |
| `Sources/AeroLite/Layout.swift` | pure geometry, no AX — unit-testable |
| `Sources/AeroLite/Hotkeys.swift` | Carbon hotkey registration |
| `Sources/AeroLite/Controller.swift` | event handling, refresh, tiling, workspaces, menu |
| `Tools/wmpeek` | reads window geometry with no TCC permission (`--check` detects overlap) |

Window identity is the `AXUIElement`'s `CFHash`, never the title or index — titles change and
indices shift, which is the classic "wrong window moved" bug.

## Build note

`swift build` fails on this machine: the CommandLineTools install has a broken XCBuild
(`Unknown error parsing property list`). `build.sh` therefore invokes `swiftc` directly and skips
SwiftPM entirely; the same sources compile cleanly that way.

## Verify without permission

```bash
./build/wmpeek --check     # tiling summary, overlap count, pane positions
./build/wmpeek --parked    # windows hidden on other workspaces
```
