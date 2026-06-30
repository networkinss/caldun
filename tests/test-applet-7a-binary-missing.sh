#!/usr/bin/env bash
#
# Optional TEST.md case 7a — applet error state: binary missing.
# Temporarily moves /usr/bin/caldun aside so the applet's _run() hits
# FileNotFoundError (exit 3) and must show the red "T: N/A" fallback.
#
# Run with sudo. Auto-reverts on Enter, Ctrl-C, or any error.
#
#   sudo ./tests/test-applet-7a-binary-missing.sh
#
# Expected while staged:
#   - applet shows RED  "T: N/A"
#   - tooltip: "caldun not found. Install: sudo apt install lm-sensors jq"

set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Please run with sudo." >&2; exit 1; }

BIN=/usr/bin/caldun
BAK=/usr/bin/caldun.testbak-7a

[ -e "$BIN" ] || { echo "ERROR: $BIN not found — is the package installed?" >&2; exit 1; }
[ -e "$BAK" ] && { echo "ERROR: $BAK already exists; aborting so we don't clobber it." >&2; exit 1; }

restore() {
  if [ -e "$BAK" ]; then
    mv -f "$BAK" "$BIN"
    echo "Reverted: $BIN restored."
  fi
}
trap restore EXIT

mv "$BIN" "$BAK"
echo "STAGED: $BIN moved aside."
echo
echo "Now LEFT-CLICK the applet (forces an immediate refresh)."
echo "Expect:  RED  'T: N/A'"
echo "Hover:   tooltip 'caldun not found. Install: sudo apt install lm-sensors jq'"
echo
read -rp "Press Enter to revert... " _
# trap restore runs on exit
echo "Now LEFT-CLICK the applet again — it should return to normal temperatures."
