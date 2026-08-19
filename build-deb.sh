#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/_build"

# Run from a subdirectory so dpkg-buildpackage places output in $SCRIPT_DIR
# (it always writes to the parent of the build dir).
rm -rf "$BUILD_DIR"
mkdir "$BUILD_DIR"
# Copy rather than symlink: dh_installdocs preserves a symlink instead of
# following it, so a symlinked README.md shipped in the .deb as a dangling
# absolute link into the build tree (/home/runner/work/... on CI).
for f in caldun.sh caldun.conf caldun-known-issues.conf README.md debian \
          man applet icons; do
    cp -RL "$SCRIPT_DIR/$f" "$BUILD_DIR/$f"
done

cd "$BUILD_DIR"
dpkg-buildpackage -us -uc -b
cd "$SCRIPT_DIR"
rm -rf "$BUILD_DIR"

# shellcheck disable=SC2012  # names are ours (caldun_<ver>_all.deb); ls -t is fine
DEB=$(ls -t "$SCRIPT_DIR/"caldun_*.deb 2>/dev/null | head -1)
if [[ -n "$DEB" ]]; then
    echo "Built: $DEB"
else
    echo "Build succeeded (no .deb found in $SCRIPT_DIR)"
fi
