#!/usr/bin/env bash
# Diagnose why the caldun MATE panel applet is not running.

echo "=== Step 1: Python / GObject-Introspection dependencies ==="
python3 - <<'PYEOF'
import sys

def check(module, version_args=None):
    try:
        import gi
        if version_args:
            gi.require_version(*version_args)
        from gi.repository import __dict__ as _  # noqa
        exec(f"from gi.repository import {module}")
        print(f"  OK   {module}")
    except Exception as e:
        print(f"  FAIL {module}: {e}")

import importlib
for pkg in ("gi",):
    try:
        importlib.import_module(pkg)
        print(f"  OK   python3-gi")
    except ImportError as e:
        print(f"  FAIL python3-gi: {e}")

import gi
for mod, ver in [("Gtk", "3.0"), ("MatePanelApplet", "4.0")]:
    try:
        gi.require_version(mod, ver)
        exec(f"from gi.repository import {mod}")
        print(f"  OK   {mod} {ver}")
    except Exception as e:
        print(f"  FAIL {mod} {ver}: {e}")
PYEOF

echo ""
echo "=== Step 2: Running the applet directly (Ctrl+C to stop) ==="
echo "    If it prints a traceback, that is the error."
echo "    If it blocks silently, the script itself is fine (D-Bus issue)."
echo ""
/usr/lib/mate-panel/applets/caldun-applet
