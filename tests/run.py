#!/usr/bin/env python3
"""Run the Pulsar failure-mode suite."""
import json
import os
import signal
import subprocess
import sys
import time
import traceback

import suite as S
import live  # noqa: F401  — registers the live tests on import

BIN = S.BIN
LOG = S.LOG


def snapshot():
    out = S.sh("defaults export com.devansh.pulsar -").stdout
    path = os.path.expanduser("~/.hermes/cache/scratch/pulsar-defaults-backup.plist")
    with open(path, "w") as f:
        f.write(out)
    return path


def restore(path):
    S.sh(f"pkill -TERM -x Pulsar; sleep 2; defaults import com.devansh.pulsar '{path}'; "
         f"launchctl kickstart -k gui/$(id -u)/com.devansh.pulsar; sleep 3")


def main():
    only = sys.argv[1] if len(sys.argv) > 1 else None
    backup = snapshot()
    print(f"defaults backed up to {backup}")

    # Point the test app at the test workspace, with the app stopped so its own save cannot
    # overwrite the change.
    S.sh("pkill -TERM -x Pulsar; sleep 2")
    import plistlib, subprocess
    dump = subprocess.run(["defaults", "export", "com.devansh.pulsar", "-"],
                          capture_output=True).stdout
    prefs = plistlib.loads(dump)
    apps = prefs.setdefault("appWorkspaces", {})
    apps["com.devansh.wintest"] = S.WS
    apps["com.apple.finder"] = S.WS
    # Title-keyed entries win over the per-app map, so stale ones would drag the test windows back
    # to whichever workspace they were last seen on.
    windows = prefs.get("windowWorkspaces", {})
    for key in [k for k in windows if k.startswith("com.devansh.wintest")
                or k.startswith("com.apple.finder|wmtest")]:
        windows.pop(key)
    prefs["windowWorkspaces"] = windows
    prefs["currentWorkspace"] = S.WS
    subprocess.run(["defaults", "import", "com.devansh.pulsar", "-"],
                   input=plistlib.dumps(prefs), check=True)
    S.sh("launchctl kickstart -k gui/$(id -u)/com.devansh.pulsar; sleep 4")

    S.pulsar(f"ws-{S.WS}", wait=0.8)
    S.STATE["vr"] = S.visible_rect()
    print(f"visible frame: {S.STATE['vr']}")

    # Teach the manager that the test app lives on the test workspace; otherwise its saved home is
    # some other workspace and windows are correctly parked instead of tiled there.
    S.wintest("closeall", wait=0.5)

    selected = [(n, t, f) for n, t, f in S.TESTS if not only or only in t or only in n]
    print(f"running {len(selected)} of {len(S.TESTS)} tests\n")

    passed, failed, skipped = 0, [], 0
    for name, tier, fn in selected:
        started = time.time()
        mark = "FAIL"
        try:
            S.ensure_workspace()
            fn()
            passed += 1
            mark = "PASS"
        except S.Fail as e:
            failed.append((name, str(e)))
            mark = "FAIL"
        except Exception as e:  # noqa: BLE001 — a crash in a test is a finding, not a runner error
            failed.append((name, f"{type(e).__name__}: {e}"))
            mark = "FAIL"
        finally:
            elapsed = time.time() - started
            print(f"  [{mark}] {name}  ({elapsed:.1f}s)")
            try:
                S.cleanup()
            except Exception:
                pass

    print(f"\n{passed} passed, {len(failed)} failed, {len(S.TESTS)} total")
    for name, why in failed:
        print(f"  FAILED: {name}\n          {why}")

    out = {"passed": passed, "failed": failed, "total": len(S.TESTS),
           "visible": S.STATE["vr"]}
    with open(os.path.expanduser("~/.hermes/cache/scratch/pulsar-suite-results.json"), "w") as f:
        json.dump(out, f, indent=2)

    restore(backup)
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
