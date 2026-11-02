#!/usr/bin/env bash
#
# Automated test suite for caldun.sh, driven entirely by fixtures.
#
#   ./tests/run.sh
#
# Hermetic by construction, so it gives the same result on a CI runner and on a
# machine with real sensors:
#   - every run reads a canned `sensors -j` dump (CALDUN_SENSORS_JSON), never
#     the hardware, so lm-sensors is not even needed — only jq;
#   - /etc/caldun.conf is replaced by a test config (CALDUN_CONF), which also
#     turns clocks off, as those come from the real /sys;
#   - peaks go to a temp file (CALDUN_PEAKS), never the user's state;
#   - notify-send is a stub that logs its arguments, so a test can count
#     notifications and nothing ever pops up on the desktop.
#
# Exit 0 when every test passes, 1 otherwise.
#
# The applet tests next to this file (test-applet-*.sh) are manual: they need
# a MATE panel and sudo. They are not part of this suite.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CALDUN="${CALDUN_UNDER_TEST:-$ROOT/caldun.sh}"   # override to test another copy
FIX="$ROOT/tests/fixtures"

command -v jq >/dev/null 2>&1 || { echo "run.sh: jq is required" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
FAILED=()

# --- per-test sandbox -------------------------------------------------------

# Fresh config, peaks file and notification log for each test, so no test can
# leak state (a peak, a notification) into the next.
sandbox() {
  local dir="$WORK/$1"
  mkdir -p "$dir/bin"
  cat >"$dir/bin/notify-send" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$dir/notify.log"
EOF
  chmod +x "$dir/bin/notify-send"
  : >"$dir/notify.log"
  printf 'SHOW_CLOCKS=0\n' >"$dir/conf"
  export PATH="$dir/bin:$BASE_PATH"
  export CALDUN_CONF="$dir/conf"
  export CALDUN_PEAKS="$dir/peaks"
  export CALDUN_ISSUES=/dev/null
  unset CALDUN_SENSORS_JSON
  SB="$dir"
}
BASE_PATH="$PATH"

# Run caldun; sets OUT (stdout), ERR (stderr) and RC.
run() {
  OUT="$("$CALDUN" "$@" 2>"$SB/stderr")"
  RC=$?
  ERR="$(cat "$SB/stderr")"
}

# --- assertions -------------------------------------------------------------

CURRENT=""
CURRENT_OK=1

fail() {
  printf '    FAIL: %s\n' "$1"
  CURRENT_OK=0
}

expect_rc()       { [ "$RC" = "$1" ] || fail "expected exit $1, got $RC${ERR:+ (stderr: $ERR)}"; }
expect_out()      { [ "$OUT" = "$1" ] || fail "expected stdout '$1', got '$OUT'"; }
expect_empty()    { [ -z "$OUT" ] || fail "expected empty stdout, got '$OUT'"; }
expect_contains() { case "$OUT" in *"$1"*) ;; *) fail "stdout lacks '$1'";; esac; }
expect_lacks()    { case "$OUT" in *"$1"*) fail "stdout should not contain '$1'";; esac; }
expect_jq()       { printf '%s' "$OUT" | jq -e "$1" >/dev/null 2>&1 || fail "jq check failed: $1"; }
notify_count()    { grep -c -F -- "$1" "$SB/notify.log" || true; }
expect_notify()   {
  local n; n="$(notify_count "$1")"
  [ "$n" = "$2" ] || fail "expected $2 notification(s) '$1', got $n"
}

t() {
  CURRENT=$1
  CURRENT_OK=1
  sandbox "$(printf '%s' "$1" | tr -c 'a-zA-Z0-9' '_')"
}

done_t() {
  if [ "$CURRENT_OK" = 1 ]; then
    PASS=$((PASS + 1)); printf 'ok    %s\n' "$CURRENT"
  else
    FAIL=$((FAIL + 1)); FAILED+=("$CURRENT"); printf 'FAIL  %s\n' "$CURRENT"
  fi
}

# --- argument handling ------------------------------------------------------

t "--help exits 0"
export CALDUN_SENSORS_JSON="$FIX/amd-normal.json"
run --help; expect_rc 0
done_t

t "--version matches debian/changelog"
export CALDUN_SENSORS_JSON="$FIX/amd-normal.json"
run --version; expect_rc 0
want="$(sed -n '1s/^caldun (\([^)]*\)).*/\1/p' "$ROOT/debian/changelog")"
expect_contains "$want"
done_t

t "unknown option exits 64"
export CALDUN_SENSORS_JSON="$FIX/amd-normal.json"
run --frobnicate; expect_rc 64; expect_empty
done_t

t "--get without a value exits 64"
export CALDUN_SENSORS_JSON="$FIX/amd-normal.json"
run --get; expect_rc 64; expect_empty
done_t

t "--get with an unknown category exits 64"
export CALDUN_SENSORS_JSON="$FIX/amd-normal.json"
run --get toaster; expect_rc 64; expect_empty
done_t

t "--check with --json is a mode conflict (64)"
export CALDUN_SENSORS_JSON="$FIX/amd-normal.json"
run --check --json; expect_rc 64; expect_empty
done_t

t "--watch rejects a non-numeric interval (64)"
export CALDUN_SENSORS_JSON="$FIX/amd-normal.json"
run --watch abc; expect_rc 64; expect_empty
done_t

# --- no trusted sensors -----------------------------------------------------

for mode in "" "--json" "--get cpu" "--check" "--watch 1"; do
  t "no trusted chips: '${mode:-<report>}' exits 4, empty stdout"
  export CALDUN_SENSORS_JSON="$FIX/no-trusted-chips.json"
  # shellcheck disable=SC2086  # $mode is deliberately word-split
  run $mode; expect_rc 4; expect_empty
  done_t
done

# --- normal machine ---------------------------------------------------------

t "normal: text report, exit 0, untrusted nct6798 ignored"
export CALDUN_SENSORS_JSON="$FIX/amd-normal.json"
run; expect_rc 0
expect_contains "All sensors within normal range"
expect_contains "Composite"
expect_lacks "CPUTIN"
expect_lacks "nct6798"
done_t

t "normal: --json schema 1 with cpu, gpu and drive"
export CALDUN_SENSORS_JSON="$FIX/amd-normal.json"
run --json; expect_rc 0
expect_jq '.schema == 1 and .status == "ok" and .exit_code == 0'
expect_jq '[.sensors[].category] | sort == ["cpu","drive","gpu"]'
expect_jq 'all(.sensors[]; .chip | startswith("nct") | not)'
done_t

t "normal: voltage/power channels are not temperature siblings"
# The 1.7 fix: amdgpu's vddgfx (0.674 V) must never become siblings_min.
export CALDUN_SENSORS_JSON="$FIX/amd-normal.json"
run --json
expect_jq '.sensors[] | select(.category == "gpu") | .siblings_min == null'
done_t

t "normal: --get prints one bare number per category"
export CALDUN_SENSORS_JSON="$FIX/amd-normal.json"
run --get cpu;   expect_rc 0; expect_out "57.25"
run --get gpu;   expect_rc 0; expect_out "42"
run --get drive; expect_rc 0; expect_out "65.85"
done_t

t "normal: --notify sends nothing while all is OK"
export CALDUN_SENSORS_JSON="$FIX/amd-normal.json"
run --notify; expect_rc 0
expect_notify "" 0
done_t

# --- suspect path (synthetic phantom spike) -----------------------------------

t "suspect: phantom spike is [SUSPECT], does not escalate (exit 0)"
export CALDUN_SENSORS_JSON="$FIX/nvme-phantom-spike.json"
run; expect_rc 0
expect_contains "[SUSPECT]"
expect_contains "Suspected sensor / firmware issues"
expect_contains "All sensors within normal range"
done_t

t "suspect: --json marks the drive suspect, siblings_min is the coolest channel"
export CALDUN_SENSORS_JSON="$FIX/nvme-phantom-spike.json"
run --json; expect_rc 0
expect_jq '.status == "ok" and .exit_code == 0'
expect_jq '.sensors[] | select(.category == "drive") | .status == "suspect" and .siblings_min == 65.85'
done_t

t "suspect: one 'faulty sensor' notification, no 'running hot'"
export CALDUN_SENSORS_JSON="$FIX/nvme-phantom-spike.json"
run --notify; expect_rc 0
expect_notify "Sensor reading looks faulty" 1
expect_notify "Machine running hot" 0
done_t

t "suspect: NOTIFY_SUSPECT=0 silences the suspect notification"
export CALDUN_SENSORS_JSON="$FIX/nvme-phantom-spike.json"
printf 'NOTIFY_SUSPECT=0\n' >>"$CALDUN_CONF"
run; expect_rc 0
expect_notify "Sensor reading looks faulty" 0
done_t

t "suspect: reading kept out of the sensor's peak"
export CALDUN_SENSORS_JSON="$FIX/nvme-phantom-spike.json"
run; expect_rc 0
grep -q '^suspect\.nvme-pci-0300	84\.85	' "$CALDUN_PEAKS" \
  || fail "suspect.nvme-pci-0300 not recorded as 84.85"
if grep -q '^temp\.nvme-pci-0300	84\.85	' "$CALDUN_PEAKS"; then
  fail "phantom 84.85 became the drive's temperature peak"
fi
done_t

t "suspect: ANOMALY_DETECT=0 trusts the reading (critical, exit 2)"
export CALDUN_SENSORS_JSON="$FIX/nvme-phantom-spike.json"
printf 'ANOMALY_DETECT=0\n' >>"$CALDUN_CONF"
run; expect_rc 2
expect_contains "[CRITICAL]"
expect_lacks "[SUSPECT]"
done_t

t "overheat: every channel hot is real heat, never masked (exit 2)"
# Same Composite reading as the phantom spike, but the coolest sibling (80.85)
# is above WARN, so this must escalate.
export CALDUN_SENSORS_JSON="$FIX/nvme-overheat.json"
run; expect_rc 2
expect_contains "[CRITICAL]"
expect_lacks "[SUSPECT]"
run --json; expect_rc 2
expect_jq '.status == "critical" and .exit_code == 2'
done_t

t "overheat: --notify sends one critical 'running hot' popup"
export CALDUN_SENSORS_JSON="$FIX/nvme-overheat.json"
run --notify; expect_rc 2
expect_notify "Machine running hot" 1
expect_notify "-u critical" 1
done_t

# --- multi-drive --get ------------------------------------------------------

t "two drives: --get drive returns the hottest, not the first"
# The hotter drive (0400) sorts second, so "first found" would return 65.85.
export CALDUN_SENSORS_JSON="$FIX/two-drives.json"
run --get drive; expect_rc 0; expect_out "70.85"
done_t

t "two drives: --get drive:<chip> selects exactly"
export CALDUN_SENSORS_JSON="$FIX/two-drives.json"
run --get drive:nvme-pci-0400; expect_rc 0; expect_out "70.85"
run --get drive:nvme-pci-0300; expect_rc 0; expect_out "65.85"
done_t

t "two drives: --get drive:<unknown chip> exits 4, empty stdout"
export CALDUN_SENSORS_JSON="$FIX/two-drives.json"
run --get drive:nvme-pci-9999; expect_rc 4; expect_empty
done_t

# --- watch mode ---------------------------------------------------------------

# Drive caldun --watch 1 sample by sample. The fixture is a copy the test may
# rewrite between samples: watch mode re-reads it on every sample, and only after
# sleeping, so swapping it right after a line is printed is race-free.
# Usage: watch_run <samples> <fixture for sample 1> [<fixture for sample 2> ...]
#   (the last fixture given is kept for the remaining samples)
# Sets LINES_OUT (the watch lines) and RC (caldun's exit code after SIGINT).
watch_run() {
  local samples=$1; shift
  local fixtures=("$@") live="$SB/live.json" line n=0 pid
  cp "${fixtures[0]}" "$live"
  export CALDUN_SENSORS_JSON="$live"
  LINES_OUT=""
  coproc WATCH { exec "$CALDUN" --watch 1 "${WATCH_ARGS[@]}" 2>"$SB/stderr"; }
  pid=$WATCH_PID
  while IFS= read -r -t 15 line <&"${WATCH[0]}"; do
    n=$((n + 1))
    LINES_OUT+="$line"$'\n'
    if [ "$n" -ge "$samples" ]; then
      kill -INT "$pid"
      break
    fi
    if [ "$n" -lt "${#fixtures[@]}" ]; then
      cp "${fixtures[$n]}" "$live"
    fi
  done
  wait "$pid"; RC=$?
  ERR="$(cat "$SB/stderr")"
  [ "$n" = "$samples" ] || fail "watch printed $n line(s), expected $samples"
}

t "watch: one compact line per sample, drive2 for a second drive"
WATCH_ARGS=()
watch_run 2 "$FIX/two-drives.json"
expect_rc 0
OUT="$LINES_OUT"
expect_contains " gpu=42 cpu=57.25 drive=65.85 drive2=70.85 OK"
[ "$(printf '%s' "$LINES_OUT" | grep -c ' OK$')" = 2 ] || fail "expected 2 OK lines"
done_t

t "watch: suspect marked !suspect, line stays OK"
WATCH_ARGS=()
watch_run 1 "$FIX/nvme-phantom-spike.json"
expect_rc 0
OUT="$LINES_OUT"
expect_contains "drive=84.85!suspect OK"
done_t

t "watch: exits 0 on SIGINT even while critical"
WATCH_ARGS=()
watch_run 1 "$FIX/nvme-overheat.json"
expect_rc 0
OUT="$LINES_OUT"
expect_contains "drive=84.85 CRITICAL"
done_t

t "watch --json: one JSON object per line (JSONL)"
WATCH_ARGS=(--json)
watch_run 2 "$FIX/amd-normal.json"
expect_rc 0
while IFS= read -r line; do
  printf '%s' "$line" | jq -e '.schema == 1' >/dev/null 2>&1 || fail "not a schema-1 JSON line: $line"
done <<<"${LINES_OUT%$'\n'}"
done_t

t "watch: notifies once per state change, not per sample"
# hot, hot, hot -> one popup; cool -> nothing (state changed, but OK is not
# notified); hot again -> a second popup.
WATCH_ARGS=(--notify)
watch_run 5 "$FIX/nvme-overheat.json" "$FIX/nvme-overheat.json" "$FIX/nvme-overheat.json" \
            "$FIX/amd-normal.json" "$FIX/nvme-overheat.json"
expect_rc 0
expect_notify "Machine running hot" 2
done_t

# --- summary ------------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '  - %s\n' "${FAILED[@]}"
  exit 1
fi
exit 0
