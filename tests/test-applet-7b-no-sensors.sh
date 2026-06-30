#!/usr/bin/env bash
#
# Optional TEST.md case 7b — applet error state: no trustworthy sensors.
# Appends IGNORE_SENSORS="*" to /etc/caldun.conf so caldun ignores
# every chip and exits 4. The applet then shows the grey "T: ?" fallback.
#
# Run with sudo. Auto-reverts the config on Enter, Ctrl-C, or any error.
#
#   sudo ./tests/test-applet-7b-no-sensors.sh
#
# Expected while staged:
#   - applet shows GREY "T: ?"
#   - tooltip: "No sensor data. Run: sudo sensors-detect"

set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Please run with sudo." >&2; exit 1; }

CONF=/etc/caldun.conf

if [ -e "$CONF" ]; then
  HAD_CONF=1
  BAK="$(mktemp)"
  cp -a "$CONF" "$BAK"
else
  HAD_CONF=0
  BAK=""
fi

restore() {
  if [ "$HAD_CONF" -eq 1 ]; then
    cp -a "$BAK" "$CONF"
    rm -f "$BAK"
    echo "Reverted: $CONF restored from backup."
  else
    rm -f "$CONF"
    echo "Reverted: removed the temporary $CONF (it did not exist before)."
  fi
}
trap restore EXIT

printf '\n# --- TEST 7b (temporary) ---\nIGNORE_SENSORS="*"\n' >> "$CONF"
echo "STAGED: IGNORE_SENSORS=\"*\" appended to $CONF (caldun now exits 4)."
echo
echo "Sanity check (CLI):"
caldun --check || true        # expected: exit 4, 'no trustworthy sensors'
echo
echo "Now LEFT-CLICK the applet (forces an immediate refresh)."
echo "Expect:  GREY 'T: ?'"
echo "Hover:   tooltip 'No sensor data. Run: sudo sensors-detect'"
echo
read -rp "Press Enter to revert... " _
# trap restore runs on exit
echo "Now LEFT-CLICK the applet again — it should return to normal temperatures."
