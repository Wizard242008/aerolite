#!/usr/bin/env python3
"""Pulsar failure-mode suite: 100 tests, run against the live app plus the pure layout code.

Design notes
------------
* Layout tests read geometry from build/layouttest (no window server involved), so they are exact.
* Live tests run on an empty workspace ("z") and only assert about windows the suite created
  (Finder windows pointed at /tmp/wmtest*, and the Wintest app), so the user's own windows can be
  present without making results meaningless.
* Every test is independent: cleanup closes the suite's windows and returns to the test workspace.
* The user's workspace map is snapshotted before the run and restored afterwards.
"""
import json
import os
import re
import subprocess
import sys
import time

PULSAR = os.path.expanduser("~/pulsar")
BIN = f"{PULSAR}/build"
LOG = os.path.expanduser("~/Library/Logs/Pulsar.log")
CMD = os.path.expanduser("~/Library/Logs/Pulsar.cmd")
WCMD = os.path.expanduser("~/Library/Logs/Wintest.cmd")
WS = "z"

results = []
STATE = {"vr": None}


# ----------------------------------------------------------------------------- plumbing

def sh(cmd, timeout=30):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)


def pulsar(command, wait=0.9, retries=3):
    """Send a command and wait until the app has consumed it.

    The app deletes the command file after reading it, so a second write that lands before the
    first is consumed is lost. Waiting for the file to disappear makes the channel reliable.
    """
    for _attempt in range(retries):
        with open(CMD, "w") as f:
            f.write(command)
        sh("notifyutil -p com.devansh.pulsar.cmd")
        deadline = time.time() + max(wait, 1.2)
        while time.time() < deadline:
            if not os.path.exists(CMD):
                break
            time.sleep(0.05)
        if not os.path.exists(CMD):
            time.sleep(min(wait, 0.4))
            return
        time.sleep(0.2)
    time.sleep(wait)


def wintest(command, wait=0.8):
    with open(WCMD, "a") as f:
        f.write(command + "\n")
    time.sleep(wait)


def peek():
    out = sh(f"{BIN}/wmpeek --json").stdout.strip()
    return json.loads(out) if out.startswith("[") else []


def check_summary():
    out = sh(f"{BIN}/wmpeek --check").stdout
    m = re.search(r"overlaps among tiled panes: (\d+)", out)
    return int(m.group(1)) if m else -1


def dump():
    """Parse the last DUMP block: {app: [(title, x, y, w, h, tracked, focused)]}."""
    pulsar("dump", wait=1.1)
    text = open(LOG, errors="ignore").read()
    idx = text.rfind("=== DUMP")
    if idx < 0:
        return {}, {}
    block = text[idx:]
    apps, flat = {}, []
    current = None
    head = re.search(r"=== DUMP ws=(\S+) orientation=(\S+) tracked=(\d+)", block)
    meta = {"ws": head.group(1), "orientation": head.group(2), "tracked": int(head.group(3))} if head else {}
    for line in block.splitlines():
        m = re.match(r"pulsar:\s+app (\S+) pid=(\d+) axWindows=(\d+)", line)
        if m:
            current = m.group(1)
            apps[current] = []
            continue
        m = re.match(r'pulsar:\s+\[AX\w+\] "(.*)" (-?\d+),(-?\d+) (\d+)x(\d+) tracked=(true|false)(.*)', line)
        if m and current:
            rec = dict(app=current, title=m.group(1), x=int(m.group(2)), y=int(m.group(3)),
                       w=int(m.group(4)), h=int(m.group(5)), tracked=m.group(6) == "true",
                       focused="FOCUSED" in m.group(7))
            apps[current].append(rec)
            flat.append(rec)
    return apps, {"meta": meta, "flat": flat}


def visible_rect():
    """The usable screen area, straight from AppKit — never inferred from a window that may be
    sharing the workspace with others."""
    out = sh(f"{BIN}/wmpeek --visible").stdout.strip()
    data = json.loads(out)
    return (int(data["x"]), int(data["y"]), int(data["w"]), int(data["h"]))


def wmtest_count():
    return len([r for r in peek() if "wmtest" in (r["title"] or "")])


def finder_close(timeout=8):
    """Close only the suite's Finder windows, then wait until they are really gone."""
    script = ('tell application "Finder"\n'
              '  set targets to (every window whose name contains "wmtest")\n'
              '  repeat with w in targets\n'
              '    try\n'
              '      close w\n'
              '    end try\n'
              '  end repeat\n'
              'end tell')
    deadline = time.time() + timeout
    while time.time() < deadline:
        if wmtest_count() == 0:
            return
        sh(f"osascript -e '{script}'")
        time.sleep(0.5)


def finder_open(n, timeout=12):
    """Ensure exactly n suite-owned Finder windows exist and are visible."""
    # Unique titles per opening: placement is remembered per "app|title", so reusing a name would
    # drag the window back to wherever that name last lived instead of the current workspace.
    stamp = str(int(time.time() * 1000) % 1000000)
    names = [f"wmtest{stamp}{i}" for i in range(n)]
    for name in names:
        sh(f"mkdir -p /tmp/{name}")
    for _attempt in range(3):
        finder_close()
        if wmtest_count() == 0:
            break
    for name in names:
        sh(f"osascript -e 'tell application \"Finder\" to make new Finder window to (POSIX file \"/tmp/{name}\")'")
        time.sleep(0.3)
    deadline = time.time() + timeout
    while time.time() < deadline:
        if wmtest_count() >= n:
            visible = [r for r in peek() if "wmtest" in (r["title"] or "") and not r["parked"]]
            if len(visible) >= n:
                return
        time.sleep(0.3)
    visible = [r for r in peek() if "wmtest" in (r["title"] or "") and not r["parked"]]
    raise Fail(f"only {len(visible)} of {n} Finder windows are visible on the workspace")


def current_workspace():
    return sh("defaults read com.devansh.pulsar currentWorkspace").stdout.strip()


def ensure_workspace(timeout=8):
    """Every test starts on the test workspace; a leftover from the previous test parks new windows."""
    if current_workspace() == WS:
        return
    deadline = time.time() + timeout
    while time.time() < deadline:
        pulsar(f"ws-{WS}", wait=0.7)
        if current_workspace() == WS:
            return
    raise Fail(f"could not switch to workspace {WS} (at {current_workspace()})")


def cleanup():
    finder_close()
    wintest("closeall", wait=0.5)
    pulsar(f"ws-{WS}", wait=0.5)


# ----------------------------------------------------------------------------- assertions

class Fail(Exception):
    pass


def ok(cond, msg):
    if not cond:
        raise Fail(msg)


def eq(got, want, msg):
    if got != want:
        raise Fail(f"{msg}: got {got!r}, wanted {want!r}")


def close(a, b, msg, tol=1.0):
    if abs(a - b) > tol:
        raise Fail(f"{msg}: {a} vs {b} (tol {tol})")


def overlaps(rects, tol=2):
    bad = []
    for i in range(len(rects)):
        for j in range(i + 1, len(rects)):
            a, b = rects[i], rects[j]
            sx = min(a["x"] + a["w"], b["x"] + b["w"]) - max(a["x"], b["x"])
            sy = min(a["y"] + a["h"], b["y"] + b["h"]) - max(a["y"], b["y"])
            if sx > tol and sy > tol:
                bad.append((a.get("title", "?"), b.get("title", "?"), sx, sy))
    return bad


def no_overlap(rects, label):
    bad = overlaps(rects)
    if bad:
        raise Fail(f"{label}: {len(bad)} overlapping pairs, e.g. {bad[0]}")


def within(rects, vr, label, tol=2):
    x, y, w, h = vr
    for r in rects:
        if r["x"] < x - tol or r["y"] < y - tol or r["x"] + r["w"] > x + w + tol or r["y"] + r["h"] > y + h + tol:
            raise Fail(f"{label}: {r['title'][:24]} at ({r['x']},{r['y']},{r['w']},{r['h']}) outside {vr}")


def tiles_span(rects, vr, label, tol=2):
    """The panes together must cover the visible frame edge to edge on the axis they tile."""
    x, y, w, h = vr
    if not rects:
        raise Fail(f"{label}: no panes")
    left = min(r["x"] for r in rects)
    right = max(r["x"] + r["w"] for r in rects)
    top = min(r["y"] for r in rects)
    bottom = max(r["y"] + r["h"] for r in rects)
    ok(abs(left - x) <= tol, f"{label}: left edge {left} != {x}")
    ok(abs(right - (x + w)) <= tol, f"{label}: right edge {right} != {x + w}")
    ok(abs(top - y) <= tol, f"{label}: top edge {top} != {y}")
    ok(abs(bottom - (y + h)) <= tol, f"{label}: bottom edge {bottom} != {y + h}")


# ----------------------------------------------------------------------------- layout tier

LAYOUT = json.loads(sh(f"{BIN}/layouttest").stdout)


def case(name):
    return LAYOUT["cases"][name]


def check_frames(name, expect_count, w, h, mins=None, vertical=False):
    frames = [dict(x=round(f["x"], 2), y=round(f["y"], 2), w=round(f["w"], 2), h=round(f["h"], 2))
              for f in case(name)]
    eq(len(frames), expect_count, f"{name}: frame count")
    no_overlap(frames, f"{name}: overlap")
    for f in frames:
        ok(f["w"] > 0 and f["h"] > 0, f"{name}: non-positive size {f}")
    total = sum(f["w"] for f in frames) if not vertical else sum(f["h"] for f in frames)
    span = w if not vertical else h
    ok(total <= span + 1.5, f"{name}: panes exceed the frame ({total} > {span})")
    ok(total >= span - 1.5, f"{name}: panes do not fill the frame ({total} < {span})")
    if mins:
        for f, m in zip(frames, mins):
            length = f["w"] if not vertical else f["h"]
            ok(length >= m - 1.5, f"{name}: pane {length} below minimum {m}")
    return frames


TESTS = []


def test(name, tier="live"):
    def register(fn):
        TESTS.append((name, tier, fn))
        return fn
    return register


# ---- layout: splits
@test("layout_equal_split_two", "layout")
def _():
    f = check_frames("eq2h", 2, 1000, 500)
    close(f[0]["w"], 500, "first half")
    close(f[1]["x"], 500, "second origin")


@test("layout_equal_split_three", "layout")
def _():
    f = check_frames("eq3h", 3, 1000, 500)
    for r in f:
        close(r["w"], 333.33, "third", tol=1.5)


@test("layout_weighted_two_to_one", "layout")
def _():
    f = check_frames("w21h", 2, 1000, 500)
    close(f[0]["w"], 666.67, "weight 2 of 3", tol=1.5)
    close(f[1]["w"], 333.33, "weight 1 of 3", tol=1.5)


@test("layout_weighted_vertical", "layout")
def _():
    f = check_frames("w13v", 2, 800, 600, vertical=True)
    close(f[0]["h"], 150, "quarter")
    close(f[1]["h"], 450, "three quarters")


@test("layout_four_equal", "layout")
def _():
    check_frames("eq4h", 4, 1000, 500)


@test("layout_single_fills_frame", "layout")
def _():
    f = check_frames("single", 1, 1000, 500)
    close(f[0]["w"], 1000, "fills width")
    close(f[0]["h"], 500, "fills height")


@test("layout_zero_windows_empty", "layout")
def _():
    eq(len(case("none")), 0, "no windows means no frames")


@test("layout_respects_rect_origin", "layout")
def _():
    f = check_frames("offset", 2, 1000, 500)
    close(f[0]["x"], 120, "origin x honoured")
    close(f[0]["y"], 40, "origin y honoured")


@test("layout_fractional_total_closes", "layout")
def _():
    check_frames("frac", 3, 1000.5, 500)


# ---- layout: degenerate weights
@test("layout_zero_weight_no_crash", "layout")
def _():
    check_frames("zeroW", 2, 1000, 500)


@test("layout_negative_weight_sanitised", "layout")
def _():
    f = check_frames("negW", 2, 1000, 500)
    ok(f[0]["w"] > 0, "negative weight must not produce a zero-width pane")


@test("layout_huge_weight_ratio", "layout")
def _():
    f = check_frames("hugeW", 2, 1000, 500)
    ok(f[0]["w"] > f[1]["w"], "the heavy pane should be wider")


@test("layout_tiny_weights_still_fill", "layout")
def _():
    check_frames("tinyW", 3, 1000, 500)


# ---- layout: minimum sizes
@test("layout_minimum_respected", "layout")
def _():
    f = check_frames("minFits", 2, 1000, 500, mins=[660, 100])
    ok(f[0]["w"] >= 659, f"first pane {f[0]['w']} below the 660 minimum")


@test("layout_minimums_equal_split", "layout")
def _():
    check_frames("minTight", 2, 1000, 500, mins=[400, 400])


@test("layout_minimums_overflow_without_overlap", "layout")
def _():
    f = [dict(x=c["x"], y=c["y"], w=c["w"], h=c["h"]) for c in case("minOverflow")]
    eq(len(f), 2, "two panes")
    no_overlap(f, "overflow")
    ok(f[1]["x"] >= f[0]["x"] + f[0]["w"] - 1, "second pane must start after the first")
    ok(f[-1]["x"] + f[-1]["w"] > 1000, "overflow is expected: panes run past the edge")


@test("layout_vertical_minimum_respected", "layout")
def _():
    check_frames("minVertical", 2, 800, 1019, mins=[400, 620], vertical=True)


@test("layout_partial_minimum_list_padded", "layout")
def _():
    check_frames("minMismatch", 3, 900, 500)


@test("layout_zero_minimums", "layout")
def _():
    check_frames("minZero", 2, 1000, 500)


# ---- layout: grids
def grid_check(n, w=1680, h=1019):
    frames = [dict(x=c["x"], y=c["y"], w=c["w"], h=c["h"]) for c in case(f"grid{n}")]
    eq(len(frames), n, f"grid{n}: frame count")
    no_overlap(frames, f"grid{n}")
    for f in frames:
        ok(f["w"] > 1 and f["h"] > 1, f"grid{n}: degenerate pane {f}")
    return frames


@test("grid_two_windows", "layout")
def _(): grid_check(2)


@test("grid_three_windows", "layout")
def _(): grid_check(3)


@test("grid_four_windows", "layout")
def _(): grid_check(4)


@test("grid_five_windows", "layout")
def _(): grid_check(5)


@test("grid_six_windows", "layout")
def _(): grid_check(6)


@test("grid_seven_windows", "layout")
def _():
    f = grid_check(7)
    rows = {}
    for r in f:
        rows.setdefault(r["y"], []).append(r)
    ok(len(rows) >= 2, "seven windows should wrap onto at least two rows")


@test("grid_eight_windows", "layout")
def _(): grid_check(8)


@test("grid_nine_windows", "layout")
def _(): grid_check(9)


@test("grid_ten_windows", "layout")
def _(): grid_check(10)


@test("grid_forced_single_column", "layout")
def _():
    frames = [dict(x=c["x"], y=c["y"], w=c["w"], h=c["h"]) for c in case("gridForced1")]
    eq(len(frames), 5, "five rows")
    eq(len({round(r["x"]) for r in frames}), 1, "all panes share one column")
    no_overlap(frames, "single column")


@test("grid_forced_two_columns", "layout")
def _():
    frames = [dict(x=c["x"], y=c["y"], w=c["w"], h=c["h"]) for c in case("gridForced2")]
    eq(len({round(r["x"]) for r in frames}), 2, "two columns")
    no_overlap(frames, "two columns")


@test("grid_minimums_respected", "layout")
def _():
    frames = [dict(x=c["x"], y=c["y"], w=c["w"], h=c["h"]) for c in case("grid3min")]
    no_overlap(frames, "grid with minimums")
    widest_min = 660
    ok(any(r["w"] >= widest_min - 1 for r in frames), "the 660-wide pane must get its minimum")


@test("grid_mixed_minimums", "layout")
def _():
    frames = [dict(x=c["x"], y=c["y"], w=c["w"], h=c["h"]) for c in case("grid4min")]
    no_overlap(frames, "grid with mixed minimums")


@test("grid_tiny_screen", "layout")
def _():
    frames = [dict(x=c["x"], y=c["y"], w=c["w"], h=c["h"]) for c in case("gridTiny")]
    no_overlap(frames, "tiny screen grid")
    for r in frames:
        ok(r["w"] > 0 and r["h"] > 0, "tiny panes must stay positive")


@test("layout_column_preference", "layout")
def _():
    cols = LAYOUT["columns"]
    eq(cols["2"], 2, "two windows side by side")
    ok(cols["7"] >= 3, "seven windows need at least three columns")
    ok(cols["12"] <= 4, "twelve windows should not exceed four columns")


@test("layout_neighbour_bounds", "layout")
def _():
    nb = LAYOUT["neighbours"]
    eq(nb["left"]["0"], None, "no neighbour to the left of the first")
    eq(nb["right"]["2"], None, "no neighbour to the right of the last")
    eq(nb["right"]["0"], 1, "right of the first is the second")
