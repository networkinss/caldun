#!/usr/bin/env bash
#
# Optional TEST.md case 18 — live high-temp alert (watch the panel turn amber).
# Lowers CPU_WARN to 50 in /etc/caldun.conf, then loads all CPU cores so
# the real temperature crosses the (lowered) threshold and the applet/notify
# path reacts with REAL readings instead of forced thresholds.
#
# Run with sudo. Auto-reverts the config on Ctrl-C or any error.
#
#   sudo ./tests/test-applet-18-high-temp.sh
#
# Expected during the load window:
#   - applet CPU number climbs; LEFT-CLICK it to refresh and watch it turn AMBER
#     once it crosses 50 C
#   - the 2-min systemd timer (--notify) may also fire an amber notification

set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Please run with sudo." >&2; exit 1; }

DURATION="${1:-60}"        # seconds of CPU load (default 60); pass an arg to change
WARN_TEST=50               # lowered WARN threshold for the test
CONF=/etc/caldun.conf

# --- ensure a load generator is available ---
if command -v stress-ng >/dev/null 2>&1; then
  LOAD=(stress-ng --cpu 0 --timeout "${DURATION}s")
elif command -v stress >/dev/null 2>&1; then
  NPROC="$(nproc)"
  LOAD=(stress --cpu "$NPROC" --timeout "${DURATION}s")
else
  echo "No load generator found (stress-ng / stress)." >&2
  read -rp "Install stress-ng now via apt? [y/N] " ans
  case "$ans" in
    y|Y) apt-get update && apt-get install -y stress-ng
         LOAD=(stress-ng --cpu 0 --timeout "${DURATION}s") ;;
    *)   echo "Install one, then re-run:  sudo apt install stress-ng" >&2; exit 1 ;;
  esac
fi

# --- back up and stage config ---
if [ -e "$CONF" ]; then
  HAD_CONF=1; BAK="$(mktemp)"; cp -a "$CONF" "$BAK"
else
  HAD_CONF=0; BAK=""
fi

restore() {
  if [ "$HAD_CONF" -eq 1 ]; then
    cp -a "$BAK" "$CONF"; rm -f "$BAK"
    echo "Reverted: $CONF restored from backup."
  else
    rm -f "$CONF"
    echo "Reverted: removed the temporary $CONF (it did not exist before)."
  fi
}
trap restore EXIT

printf '\n# --- TEST 18 (temporary) ---\nCPU_WARN=%s\n' "$WARN_TEST" >> "$CONF"
echo "STAGED: CPU_WARN=$WARN_TEST appended to $CONF."
echo "Baseline reading:"
caldun --check || true
echo
echo ">>> Loading all CPU cores for ${DURATION}s. LEFT-CLICK the applet during"
echo ">>> the load to refresh it and watch the CPU value climb and turn AMBER."
echo
"${LOAD[@]}" || true
echo
echo "Load finished. Reading after load:"
caldun || true
echo
read -rp "Press Enter to revert the threshold... " _
# trap restore runs on exit
echo "Now LEFT-CLICK the applet again — colour should return to green/OK."
