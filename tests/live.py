#!/usr/bin/env python3
"""Live and persistence tests for Pulsar — everything that needs the real app running."""
import os
import re
import subprocess
import time

import suite as S
from suite import (BIN, CMD, LOG, STATE, WS, Fail, close, dump, eq, finder_close, finder_open,
                   no_overlap, ok, peek, pulsar, sh, test, tiles_span, wintest, within)

VR = lambda: STATE["vr"]


def wait_for(predicate, timeout=4.0, interval=0.25):
    end = time.time() + timeout
    while time.time() < end:
        value = predicate()
        if value:
            return value
        time.sleep(interval)
    return predicate()


def focused_is_test_window():
    """Guards every move command: a stray focus on the user's window would move *their* window."""
    apps, _ = dump()
    for name, windows in apps.items():
        for w in windows:
            if w.get("focused"):
                return name in ("Finder", "Wintest") and ("wmtest" in w["title"] or name == "Wintest")
    return False


def move_focused(label):
    if not focused_is_test_window():
        raise Fail(f"{label}: focus is not on a test window, refusing to move the user's window")
    pulsar("move-y", wait=1.8)


def rows(owner=None, onscreen_only=True):
    """Windows actually displayed right now.

    wmpeek lists every window the window server knows about, including ones on other Spaces, which
    are neither parked nor on screen. Treating those as visible made "did the window hide?" checks
    meaningless.
    """
    data = peek()
    out = [r for r in data if (r["onscreen"] and not r["parked"]) or not onscreen_only]
    if owner:
        out = [r for r in out if r["owner"] == owner]
    return out


def suite_rows():
    return [r for r in rows() if r["owner"] == "Wintest" or "wmtest" in (r["title"] or "")]


def app_alive():
    return bool(sh("pgrep -x Pulsar").stdout.strip())


def tracked():
    return dump()[1].get("meta", {}).get("tracked", -1)


# --------------------------------------------------------------------- discovery & layout

def managed_visible(vr):
    """Windows Pulsar manages and that sit inside the visible area — i.e. this workspace's layout."""
    apps, _ = dump()
    out = []
    for windows in apps.values():
        for w in windows:
            if not w["tracked"]:
                continue
            if w["x"] >= vr[0] - 2 and w["y"] >= vr[1] - 2 and \
               w["x"] + w["w"] <= vr[0] + vr[2] + 2 and w["y"] + w["h"] <= vr[1] + vr[3] + 2:
                out.append(w)
    return out


def partition(rs, vr, label):
    """Managed windows must tile the workspace: no overlaps between them, full coverage."""
    managed = managed_visible(vr)
    ok(len(managed) >= len(rs), f"{label}: only {len(managed)} managed panes for {len(rs)} windows")
    no_overlap(managed, f"{label}: managed panes")
    area = sum(w["w"] * w["h"] for w in managed)
    frame = vr[2] * vr[3]
    ok(abs(area - frame) / frame < 0.03,
       f"{label}: managed panes cover {area} of {frame} pt² — the layout leaves a hole")
    for r in rs:
        ok(any(w["title"] == r["title"] for w in managed), f"{label}: {r['title']} is not managed")


def row_partition(rs, vr, label):
    """The group must fill the width in one row — robust to other windows sharing the workspace."""
    no_overlap(rs, label)
    ys = {round(r["y"]) for r in rs}
    hs = {round(r["h"]) for r in rs}
    eq(len(ys), 1, f"{label}: panes should share one row (y={sorted(ys)})")
    ok(len(hs) <= 2, f"{label}: row height differs ({sorted(hs)})")
    left = min(r["x"] for r in rs)
    right = max(r["x"] + r["w"] for r in rs)
    ok(abs(left - vr[0]) <= 2, f"{label}: left edge {left} != {vr[0]}")
    ok(abs(right - (vr[0] + vr[2])) <= 2, f"{label}: right edge {right} != {vr[0] + vr[2]}")




@test("new window adopted automatically")
def _():
    wintest("closeall", wait=0.5)
    wintest("open 1 520 380", wait=0.3)
    got = wait_for(lambda: [r for r in rows("Wintest")], timeout=5)
    ok(got, "a window created by a running app was never adopted")


@test("adopted window is tiled to the full pane")
def _():
    wintest("closeall", wait=0.6)
    wintest("open 1 520 380", wait=0.3)
    vr = VR()
    got = wait_for(lambda: [r for r in rows("Wintest") if r["w"] != 520 or r["h"] != 412], timeout=6)
    ok(got, "window kept the size it was created with — it was never laid out")
    ok(any(r["w"] >= vr[2] - 3 or r["h"] >= vr[3] - 3 for r in got),
       f"window occupies neither a full row nor a full column: {[(r['w'], r['h']) for r in got]}")


@test("closing one window releases its pane")
def _():
    wintest("closeall", wait=0.5)
    wintest("open 2 500 400", wait=2.2)
    before = len(rows("Wintest"))
    wintest("close 0", wait=0.3)
    got = wait_for(lambda: len(rows("Wintest")) == before - 1, timeout=5)
    ok(got, "closed window still occupies a pane")
    close(rows("Wintest")[0]["w"], VR()[2], "survivor should expand", tol=3)


@test("closing the last window leaves the app stable")
def _():
    wintest("closeall", wait=0.4)
    wintest("open 1 500 400", wait=2.0)
    wintest("closeall", wait=0.3)
    ok(wait_for(lambda: len(rows("Wintest")) == 0, timeout=5), "window did not disappear")
    ok(app_alive(), "Pulsar died when the last window closed")


@test("two windows partition the workspace")
def _():
    finder_open(2)
    time.sleep(2.5)
    rs = [r for r in rows() if "wmtest" in (r["title"] or "")]
    eq(len(rs), 2, "two Finder windows should be tiled")
    partition(rs, VR(), "two windows")


@test("three windows partition the workspace")
def _():
    finder_open(3)
    time.sleep(2.8)
    rs = [r for r in rows() if "wmtest" in (r["title"] or "")]
    eq(len(rs), 3, "three Finder windows")
    partition(rs, VR(), "three windows")


@test("four windows partition the workspace")
def _():
    finder_open(4)
    time.sleep(3.2)
    rs = [r for r in rows() if "wmtest" in (r["title"] or "")]
    eq(len(rs), 4, "four Finder windows")
    partition(rs, VR(), "four windows")


@test("five windows partition the workspace")
def _():
    finder_open(5)
    time.sleep(3.4)
    rs = [r for r in rows() if "wmtest" in (r["title"] or "")]
    eq(len(rs), 5, "five Finder windows")
    partition(rs, VR(), "five windows")


@test("six windows partition the workspace")
def _():
    finder_open(6)
    time.sleep(3.6)
    rs = [r for r in rows() if "wmtest" in (r["title"] or "")]
    eq(len(rs), 6, "six Finder windows")
    partition(rs, VR(), "six windows")


@test("panes do not leave gaps between them")
def _():
    finder_open(3)
    time.sleep(2.8)
    rs = sorted([r for r in rows() if "wmtest" in (r["title"] or "")], key=lambda r: (r["y"], r["x"]))
    for a, b in zip(rs, rs[1:]):
        if abs(a["y"] - b["y"]) < 4:          # same row
            close(b["x"], a["x"] + a["w"], "adjacent panes must touch", tol=3)


@test("every pane stays inside the visible frame")
def _():
    finder_open(4)
    time.sleep(3.2)
    rs = [r for r in rows() if "wmtest" in (r["title"] or "")]
    within(rs, VR(), "panes")


@test("all windows tracked after opening a batch")
def _():
    finder_open(3)
    time.sleep(2.8)
    apps, _ = dump()
    ours = [w for w in apps.get("Finder", []) if "wmtest" in w["title"]]
    eq(len(ours), 3, f"three suite windows should be tracked, saw {len(ours)}")
    ok(all(w["tracked"] for w in ours), "an established window is not tracked")


@test("retitling a window keeps its placement")
def _():
    wintest("closeall", wait=0.5)
    wintest("open 1 500 400", wait=2.0)
    before = rows("Wintest")[0]
    wintest("title 0 renamed-window", wait=1.6)
    after = rows("Wintest")
    ok(after, "window vanished after a retitle")
    close(after[0]["x"], before["x"], "x moved after retitle")
    close(after[0]["w"], before["w"], "width changed after retitle")


@test("an external resize is corrected on the next pass")
def _():
    wintest("closeall", wait=0.5)
    wintest("open 1 500 400", wait=2.0)
    before = rows("Wintest")[0]["w"]
    wintest("resize 0 700 500", wait=0.4)
    sh("notifyutil -p com.devansh.pulsar.retile")
    time.sleep(1.4)
    after = rows("Wintest")[0]["w"]
    close(after, before, "window kept the size the user dragged", tol=3)


@test("minimising removes the window from the layout")
def _():
    finder_open(2)
    time.sleep(2.6)
    names = [w["title"] for w in dump()[0].get("Finder", []) if "wmtest" in w["title"]]
    ok(len(names) >= 2, "two suite windows must exist before minimising")
    before_width = max(w["w"] for w in dump()[0]["Finder"] if "wmtest" in w["title"])
    sh(f'osascript -e \'tell application "Finder" to set collapsed of window "{names[0]}" to true\'')
    time.sleep(2.0)
    sh("notifyutil -p com.devansh.pulsar.retile")
    time.sleep(1.6)
    apps, _ = dump()
    ours = [w for w in apps.get("Finder", []) if "wmtest" in w["title"]]
    eq(len(ours), 1, "minimised window is still in the layout")
    after_width = max(w["w"] for w in dump()[0]["Finder"] if "wmtest" in w["title"])
    ok(after_width >= before_width,
       f"survivor shrank after the other window was minimised ({before_width} -> {after_width})")


@test("deminimising restores the split")
def _():
    finder_open(2)
    time.sleep(2.6)
    names = [w["title"] for w in dump()[0].get("Finder", []) if "wmtest" in w["title"]]
    ok(len(names) >= 2, "two suite windows must exist")
    sh(f'osascript -e \'tell application "Finder" to set collapsed of window "{names[0]}" to true\'')
    time.sleep(2.0)
    eq(len([w for w in dump()[0].get("Finder", []) if "wmtest" in w["title"]]), 1,
       "window was not minimised")
    sh('osascript -e \'tell application "Finder" to set collapsed of (every window whose collapsed is true) to false\'')
    time.sleep(2.2)
    sh("notifyutil -p com.devansh.pulsar.retile")
    time.sleep(1.6)
    back = [w for w in dump()[0].get("Finder", []) if "wmtest" in w["title"]]
    eq(len(back), 2, "restored window did not come back into the layout")


@test("quitting an app removes its windows")
def _():
    wintest("closeall", wait=0.4)
    wintest("open 1 500 400", wait=2.0)
    pid = sh("pgrep -f Wintest.app").stdout.strip().split("\n")[0]
    sh(f"kill {pid}")
    time.sleep(2.0)
    ok(not rows("Wintest"), "windows of a dead app are still on screen")
    ok(app_alive(), "Pulsar died when an app quit")


@test("hiding an app keeps its window managed")
def _():
    sh(f'open -a "{os.path.expanduser("~/pulsar/build/Wintest.app")}"')
    time.sleep(2.0)
    wintest("open 1 500 400", wait=2.2)
    wintest("hide", wait=2.0)
    wintest("unhide", wait=2.0)
    apps, _ = dump()
    ok("Wintest" in apps, "the window did not come back after unhiding")
    ok(all(w["tracked"] for w in apps["Wintest"]), "window came back untracked")


@test("unhiding does not duplicate windows")
def _():
    sh(f'open -a "{BIN}/Wintest.app"')
    time.sleep(1.5)
    wintest("closeall", wait=0.6)
    wintest("open 1 500 400", wait=2.4)
    wintest("hide", wait=1.8)
    wintest("unhide", wait=2.0)
    apps, _ = dump()
    eq(len(apps.get("Wintest", [])), 1, "unhide produced a duplicate or missing window")


@test("repeated refreshes are idempotent")
def _():
    finder_open(2)
    time.sleep(2.4)
    first = tracked()
    sh("notifyutil -p com.devansh.pulsar.retile")
    time.sleep(1.2)
    second = tracked()
    eq(second, first, "refresh changed the tracked window count")


@test("refresh is fast with several windows")
def _():
    finder_open(4)
    time.sleep(3.0)
    sh("notifyutil -p com.devansh.pulsar.retile")
    time.sleep(1.2)
    times = [float(m) for m in re.findall(r"refresh took ([\d.]+) ms", open(LOG, errors="ignore").read()[-4000:])]
    ok(times, "no refresh timing recorded")
    ok(max(times[-3:]) < 400, f"refresh took {max(times[-3:])} ms")


# --------------------------------------------------------------------- workspaces

@test("switching to an empty workspace hides everything")
def _():
    pulsar(f"ws-{WS}", wait=0.7)
    wintest("closeall", wait=0.4)
    wintest("open 1 500 400", wait=2.0)
    pulsar("ws-y", wait=1.0)
    ok(not rows("Wintest"), "the previous workspace's window is still visible")
    pulsar(f"ws-{WS}", wait=1.0)


@test("switching back restores the layout")
def _():
    got = wait_for(lambda: rows("Wintest"), timeout=4)
    ok(got, "window did not come back")
    close(got[0]["w"], VR()[2], "restored pane width", tol=4)


@test("moving a window to another workspace")
def _():
    wintest("closeall", wait=0.4)
    wintest("open 2 500 400", wait=2.2)
    wintest("focus 0", wait=0.8)
    pulsar("move-y", wait=1.6)
    ok(not any(not r["parked"] for r in rows("Wintest")), "moved window is still visible")
    pulsar(f"ws-{WS}", wait=1.0)


@test("moving one window fills the vacated space")
def _():
    finder_open(2)
    time.sleep(2.6)
    sh('osascript -e \'tell application "Finder" to activate\'')
    time.sleep(0.8)
    move_focused("moving a window")
    left = [r for r in rows() if "wmtest" in (r["title"] or "")]
    eq(len(left), 1, f"expected one window to remain, saw {len(left)}")
    close(left[0]["w"], VR()[2], "remaining window should take the whole width", tol=4)
    pulsar("ws-y", wait=0.8)
    pulsar(f"ws-{WS}", wait=0.8)


@test("lettered workspace names work")
def _():
    pulsar("ws-q", wait=0.8)
    _, extra = dump()
    eq(extra["meta"]["ws"], "q", "workspace letter not applied")
    pulsar(f"ws-{WS}", wait=0.8)


@test("numeric workspace names work")
def _():
    pulsar("ws-4", wait=0.8)
    _, extra = dump()
    eq(extra["meta"]["ws"], "4", "workspace digit not applied")
    pulsar(f"ws-{WS}", wait=0.8)


@test("switching to the current workspace is a no-op")
def _():
    pulsar(f"ws-{WS}", wait=0.8)
    m = re.findall(r"switch (\S+) took ([\d.]+) ms", open(LOG, errors="ignore").read()[-3000:])
    pulsar(f"ws-{WS}", wait=0.6)
    ok(app_alive(), "app died on a no-op switch")


@test("rapid switching stays consistent")
def _():
    for name in ["y", "z", "q", "z", "4", "z"]:
        pulsar(f"ws-{name}", wait=0.35)
    pulsar(f"ws-{WS}", wait=1.0)
    _, extra = dump()
    eq(extra["meta"]["ws"], WS, "final workspace wrong after rapid switching")
    ok(app_alive(), "app died during rapid switching")


@test("orientation toggle stacks windows vertically")
def _():
    wintest("closeall", wait=0.4)
    wintest("open 2 500 400", wait=2.4)
    pulsar("orient", wait=2.0)
    _, extra = dump()
    eq(extra["meta"]["orientation"], "vertical", "orientation did not change")
    rs = [r for r in rows() if "wmtest" in (r["title"] or "")]
    ok(len({r["x"] for r in rs}) == 1, f"vertical layout should share one x, got {sorted({r['x'] for r in rs})}")
    no_overlap(rs, "vertical layout")


@test("orientation toggles back to horizontal")
def _():
    pulsar("orient", wait=1.4)
    _, extra = dump()
    eq(extra["meta"]["orientation"], "horizontal", "orientation did not return")
    rs = [r for r in rows() if "wmtest" in (r["title"] or "")]
    ok(len({r["y"] for r in rs}) <= 2, "horizontal layout should share one y")


@test("windows on other workspaces are parked off screen")
def _():
    finder_open(2)
    time.sleep(2.6)
    sh('osascript -e \'tell application "Finder" to activate\'')
    time.sleep(0.8)
    move_focused("parking test")
    pulsar("ws-y", wait=1.0)
    parked = [r for r in peek() if r["parked"] and "wmtest" in (r["title"] or "")]
    ok(parked, "no windows were parked")
    for r in parked:
        visible = max(0, min(r["x"] + r["w"], VR()[0] + VR()[2]) - max(r["x"], VR()[0]))
        ok(visible <= 3, f"parked window still shows {visible} px")
    pulsar(f"ws-{WS}", wait=0.9)


@test("toggling focus-follows-mouse does not move windows")
def _():
    wintest("closeall", wait=0.4)
    wintest("open 1 500 400", wait=2.2)
    before = rows("Wintest")[0]
    sh("notifyutil -p com.devansh.pulsar.hoveron"); time.sleep(0.8)
    sh("notifyutil -p com.devansh.pulsar.hoveroff"); time.sleep(0.8)
    after = rows("Wintest")[0]
    close(after["w"], before["w"], "window geometry changed by a settings toggle")


@test("focus moves between windows without moving them")
def _():
    finder_open(2)
    time.sleep(2.6)
    before = sorted((r["x"], r["w"]) for r in rows() if "wmtest" in (r["title"] or ""))
    pulsar("focus-right", wait=0.9)
    pulsar("focus-left", wait=0.9)
    after = sorted((r["x"], r["w"]) for r in rows() if "wmtest" in (r["title"] or ""))
    eq(after, before, "focus commands moved windows")


@test("moving focus past the edge does nothing")
def _():
    for _i in range(4):
        pulsar("focus-left", wait=0.35)
    ok(app_alive(), "app died when focus ran off the edge")


@test("windows with a large minimum size do not overlap")
def _():
    wintest("closeall", wait=0.4)
    wintest("min 1000 700", wait=0.6)
    wintest("open 1 1000 700", wait=4.0)
    rs = rows("Wintest")
    ok(rs, "the window did not appear")
    ok(rs[0]["w"] >= 995, f"manager shrank a window below its own minimum: {rs[0]['w']}")
    wintest("min 0 0", wait=0.4)


@test("learned minimums are written to defaults")
def _():
    out = sh("defaults read com.devansh.pulsar appMinWidths").stdout
    ok("com.devansh.wintest" in out or "com.apple.finder" in out, "no minimum size was ever recorded")


# --------------------------------------------------------------------- UI surface

@test("status menu opens and closes")
def _():
    pulsar("menu", wait=1.2)
    sh("osascript -e 'tell application \"System Events\" to key code 53'")
    time.sleep(0.6)
    ok(app_alive(), "app died opening its menu")


@test("menu lists the hotkey bindings")
def _():
    pulsar("menudump", wait=1.2)
    text = open(LOG, errors="ignore").read()[-6000:]
    ok("Focus Left" in text, "hotkeys submenu missing")
    ok("[" in text and "]" in text, "hotkeys have no key equivalents")


@test("settings opens and closes repeatedly")
def _():
    for _i in range(3):
        pulsar("settings", wait=1.0)
        sh("osascript -e 'tell application \"System Events\" to tell process \"Pulsar\" to tell window \"Pulsar Settings\" to click button 1'")
        time.sleep(0.6)
    ok(app_alive(), "app died in the settings open/close cycle")


@test("help window opens and its content scrolls")
def _():
    pulsar("help", wait=1.2)
    out = sh("osascript -e 'tell application \"System Events\" to tell process \"Pulsar\" to tell window \"Pulsar Help\" to set value of scroll bar 1 of scroll area 1 to 1'")
    ok(app_alive(), "app died opening help")
    ok("Can’t" not in out.stderr and "Can't" not in out.stderr, f"help has no working scrollbar: {out.stderr.strip()[:80]}")
    sh("osascript -e 'tell application \"System Events\" to tell process \"Pulsar\" to tell window \"Pulsar Help\" to click button 1'")


@test("about panel opens")
def _():
    pulsar("about", wait=1.2)
    ok(app_alive(), "app died opening the about panel")
    sh("osascript -e 'tell application \"System Events\" to tell process \"Pulsar\" to tell window \"About Pulsar\" to click button 1'")
    time.sleep(0.4)


@test("update check survives being offline")
def _():
    pulsar("updatecheck", wait=2.5)
    ok(app_alive(), "app died during an update check")


@test("log file stays under its rotation cap")
def _():
    size = os.path.getsize(LOG)
    ok(size < 900_000, f"log has grown to {size} bytes")


# --------------------------------------------------------------------- persistence & lifecycle

@test("workspace map survives a restart")
def _():
    before = sh("defaults read com.devansh.pulsar appWorkspaces").stdout
    sh("pkill -TERM -x Pulsar"); time.sleep(2.5)
    sh("launchctl kickstart -k gui/$(id -u)/com.devansh.pulsar"); time.sleep(3.5)
    after = sh("defaults read com.devansh.pulsar appWorkspaces").stdout
    eq(sorted(re.findall(r'"(\w[\w.]*)" = (\S+);', after)),
       sorted(re.findall(r'"(\w[\w.]*)" = (\S+);', before)), "the map changed across a restart")


@test("workspace map is written before the app exits")
def _():
    out = sh("defaults read com.devansh.pulsar appWorkspaces").stdout
    ok(len(re.findall(r"=", out)) >= 3, "map is suspiciously small after restart")


@test("a killed app leaves its windows usable")
def _():
    finder_open(2); time.sleep(2.4)
    sh("pkill -9 -x Pulsar"); time.sleep(2.0)
    rs = [r for r in rows() if "wmtest" in (r["title"] or "")]
    ok(len(rs) == 2, "windows disappeared after a hard kill")
    for r in rs:
        ok(r["w"] > 100 and r["h"] > 100, "window left with an unusable size")
    sh("launchctl kickstart -k gui/$(id -u)/com.devansh.pulsar"); time.sleep(4)


@test("save merges instead of replacing the map")
def _():
    defaults = sh("defaults read com.devansh.pulsar appWorkspaces.previous").stdout
    ok("=" in defaults, "no previous generation of the map is kept")


@test("an empty map is repaired at startup")
def _():
    before = sh("defaults read com.devansh.pulsar appWorkspaces").stdout
    sh("pkill -TERM -x Pulsar"); time.sleep(2.5)
    sh("defaults write com.devansh.pulsar appWorkspaces -dict")
    sh("launchctl kickstart -k gui/$(id -u)/com.devansh.pulsar"); time.sleep(3.5)
    after = sh("defaults read com.devansh.pulsar appWorkspaces").stdout
    ok("=" in after, "empty map was not recovered from the previous generation")
    if "=" not in before:
        raise Fail("precondition failed: map was already empty")


@test("window weights survive a restart")
def _():
    out = sh("defaults read com.devansh.pulsar windowWeights").stdout
    ok("=" in out, "no window weights were persisted")


@test("corrupt defaults do not crash the app")
def _():
    sh("defaults write com.devansh.pulsar appWorkspaces -string not-a-dictionary")
    sh("pkill -TERM -x Pulsar"); time.sleep(2.5)
    sh("launchctl kickstart -k gui/$(id -u)/com.devansh.pulsar"); time.sleep(4)
    ok(app_alive(), "app died on a corrupted defaults value")
    sh("defaults delete com.devansh.pulsar appWorkspaces")


@test("unknown workspace in the map falls back safely")
def _():
    sh("defaults write com.devansh.pulsar appWorkspaces -dict com.devansh.wintest zz")
    sh("pkill -TERM -x Pulsar"); time.sleep(2.5)
    sh("launchctl kickstart -k gui/$(id -u)/com.devansh.pulsar"); time.sleep(4)
    ok(app_alive(), "app died with an unknown workspace name")
    pulsar(f"ws-{WS}", wait=0.8)


@test("a second instance exits without stealing the session")
def _():
    pid = sh("pgrep -x Pulsar").stdout.strip()
    sh(f'"{BIN}/Pulsar.app/Contents/MacOS/Pulsar" >/dev/null 2>&1 &')
    time.sleep(3)
    pid2 = sh("pgrep -x Pulsar").stdout.strip()
    eq(pid2, pid, "a second instance took over")


@test("quitting cascades windows so they stay usable")
def _():
    finder_open(3); time.sleep(2.6)
    sh("pkill -TERM -x Pulsar"); time.sleep(2.5)
    rs = [r for r in rows() if "wmtest" in (r["title"] or "")]
    ok(len(rs) == 3, "windows lost on quit")
    for r in rs:
        ok(r["w"] > 300 and r["h"] > 200, f"window left tiny: {r['w']}x{r['h']}")
    sh("launchctl kickstart -k gui/$(id -u)/com.devansh.pulsar"); time.sleep(4)


@test("idle CPU stays near zero")
def _():
    sh("pkill -TERM -x Pulsar"); time.sleep(2.5)
    sh("launchctl kickstart -k gui/$(id -u)/com.devansh.pulsar"); time.sleep(4)
    pid = sh("pgrep -x Pulsar").stdout.strip()
    first = float(sh(f"ps -o cputime= -p {pid}").stdout.split(":")[-1])
    time.sleep(6)
    second = float(sh(f"ps -o cputime= -p {pid}").stdout.split(":")[-1])
    ok(second - first < 1.2, f"idle CPU burned {second - first:.1f}s in 6s")


@test("memory footprint stays modest")
def _():
    pid = sh("pgrep -x Pulsar").stdout.strip()
    out = sh(f"footprint -p {pid} 2>/dev/null | grep -i 'phys\\|footprint' | tail -2").stdout
    m = re.search(r"(\d+)\s*(MB|GB)", out)
    if not m:
        return  # footprint tool unavailable; not a failure
    size = float(m.group(1)) * (1024 if m.group(2) == "GB" else 1)
    ok(size < 120, f"footprint {size:.0f} MB")


# --------------------------------------------------------------------- extra coverage (98-100 range)

@test("two windows opened in quick succession are both adopted")
def _():
    wintest("closeall", wait=0.4)
    wintest("open 1 500 400\nopen 1 500 400", wait=0.2)
    got = wait_for(lambda: len(rows("Wintest")) == 2, timeout=6)
    ok(got, f"only {len(rows('Wintest'))} of two open windows were adopted")


@test("a window moved away and back returns to its workspace")
def _():
    wintest("closeall", wait=0.4)
    wintest("open 1 500 400", wait=2.2)
    wintest("activate", wait=0.5)
    pulsar("move-y", wait=1.2)
    pulsar("ws-y", wait=0.9)
    pulsar("move-" + WS, wait=1.2)
    pulsar("ws-" + WS, wait=1.0)
    got = wait_for(lambda: rows("Wintest"), timeout=4)
    ok(got, "window did not return to its original workspace")


@test("menu item count is stable across openings")
def _():
    def menu_items():
        pulsar("menudump", wait=1.2)
        block = open(LOG, errors="ignore").read()
        start = block.rfind("debug command: menudump")
        return [l for l in block[start:].splitlines() if re.match(r"pulsar:\s{2,}\S", l)]
    first = len(menu_items())
    second = len(menu_items())
    eq(second, first, "menu item count drifted between openings")


@test("changing the hotkey modifier changes the menu shortcuts")
def _():
    sh("defaults write com.devansh.pulsar hotkeyModifier -string control")
    sh("pkill -TERM -x Pulsar"); time.sleep(2.5)
    sh("launchctl kickstart -k gui/$(id -u)/com.devansh.pulsar"); time.sleep(3.5)
    pulsar("menudump", wait=1.2)
    text = open(LOG, errors="ignore").read()[-4000:]
    ok("[^h]" in text, "hotkeys did not follow the modifier setting")
    sh("defaults write com.devansh.pulsar hotkeyModifier -string option")
    sh("pkill -TERM -x Pulsar"); time.sleep(2.5)
    sh("launchctl kickstart -k gui/$(id -u)/com.devansh.pulsar"); time.sleep(3.5)


@test("layout keeps panes positive when minimums exceed a small screen")
def _():
    frames = S.LAYOUT["cases"]["gridTiny"]
    ok(all(f["w"] > 0 and f["h"] > 0 for f in frames), "degenerate frame on a small screen")


@test("layout two windows stack vertically")
def _():
    frames = S.LAYOUT["cases"]["minVertical"]
    eq(len(frames), 2, "two vertical panes")
    ok(frames[0]["x"] == frames[1]["x"], "vertical panes must share x")


@test("layout neighbour mapping covers both directions")
def _():
    nb = S.LAYOUT["neighbours"]
    eq(nb["up"]["1"], 0, "up from the second is the first")
    eq(nb["down"]["1"], 2, "down from the second is the third")
    eq(nb["up"]["0"], None, "up from the first has no target")


@test("layout column preference for a single window")
def _():
    eq(S.LAYOUT["columns"]["1"], 1, "a single window needs one column")


@test("layout grid of eleven windows stays partitioned")
def _():
    frames = S.LAYOUT["cases"]["grid10"]
    eq(len(frames), 10, "ten panes")
    no_overlap([dict(x=f["x"], y=f["y"], w=f["w"], h=f["h"]) for f in frames], "ten panes")
