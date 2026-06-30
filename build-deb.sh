#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/_build"

# Run from a subdirectory so dpkg-buildpackage places output in $SCRIPT_DIR
# (it always writes to the parent of the build dir).
rm -rf "$BUILD_DIR"
mkdir "$BUILD_DIR"
for f in caldun.sh caldun.conf caldun-known-issues.conf debian \
          man applet icons; do
    ln -s "$SCRIPT_DIR/$f" "$BUILD_DIR/$f"
done

cd "$BUILD_DIR"
dpkg-buildpackage -us -uc -b
cd "$SCRIPT_DIR"
rm -rf "$BUILD_DIR"

DEB=$(ls -t "$SCRIPT_DIR/"caldun_*.deb 2>/dev/null | head -1)
if [[ -n "$DEB" ]]; then
    echo "Built: $DEB"
else
    echo "Build succeeded (no .deb found in $SCRIPT_DIR)"
fi
