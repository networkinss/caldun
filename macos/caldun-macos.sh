#!/usr/bin/env bash
#
# caldun-macos — proof-of-concept macOS (Intel) port of caldun.sh.
#
# The Linux original reads `sensors -j` (lm-sensors), which does not exist on
# macOS. macOS temperatures live behind the SMC (System Management Controller).
# This PoC swaps ONLY the sensor backend; the categorise/threshold/report/notify
# logic is the same shape as the Linux script.
#
# Backends tried, in order (first one found wins):
#   1. iStats        — `gem install iStats` (richer: CPU/GPU/disk where exposed)
#   2. osx-cpu-temp  — `brew install osx-cpu-temp` (CPU, plus GPU best-effort)
# Neither needs sudo on Intel Macs. (`powermetrics` would, so it's avoided.)
#
# Limitations of a PoC vs the Linux version:
#   - No per-sensor hardware max/crit from these tools, so every threshold is a
#     category DEFAULT (source is always "default"). Good enough to prove it out.
#   - Sensor coverage depends entirely on what the chosen tool exposes; Apple
#     restricts SMC keys and rarely surfaces NVMe drive temps on Intel Macs.
#
# Exit codes (same contract as the Linux script):
#   0 OK   1 WARN   2 CRITICAL   3 no temp backend installed   4 no usable sensors

set -euo pipefail
set -f

PROG=${0##*/}

# ---------------------------------------------------------------------------
# Defaults (overridden by the config file below). Mirrors the Linux script.
# ---------------------------------------------------------------------------
WARN_MARGIN=10
CPU_WARN=85;   CPU_CRIT=95
GPU_WARN=85;   GPU_CRIT=95
DRIVE_WARN=75; DRIVE_CRIT=83
NOTIFY_DEFAULT=0

# macOS has no /etc convention like Linux; default under Homebrew's prefix.
CONF="${CALDUN_CONF:-/usr/local/etc/caldun.conf}"
# shellcheck source=/dev/null
[ -r "$CONF" ] && . "$CONF"

# ---------------------------------------------------------------------------
# Arguments.
# ---------------------------------------------------------------------------
NOTIFY=$NOTIFY_DEFAULT
CHECK_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --notify) NOTIFY=1 ;;
    --check)  CHECK_ONLY=1 ;;
    -h|--help)
      cat <<EOF
Usage: $PROG [--notify] [--check]
  --notify  send a macOS notification (osascript) on WARN/CRITICAL
  --check   self-test: show backend, discovered sensors and thresholds, exit
Config: $CONF   Exit: 0 OK, 1 WARN, 2 CRIT, 3 no backend, 4 no usable sensors
EOF
      exit 0 ;;
    *) echo "$PROG: unknown argument: $arg" >&2; exit 64 ;;
  esac
done

if [ -t 1 ]; then RED=$'\033[31m'; YEL=$'\033[33m'; GRN=$'\033[32m'; DIM=$'\033[2m'; RST=$'\033[0m'
else RED=; YEL=; GRN=; DIM=; RST=; fi

have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Numeric helpers (same as Linux script — bash can't compare floats).
# ---------------------------------------------------------------------------
fge()  { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0 >= b+0)}'; }
fsub() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.1f", a-b}'; }
fmin() {
  awk -v a="$1" -v b="$2" 'BEGIN{
    if (a=="") {print b} else if (b=="") {print a}
    else {print (a+0 < b+0) ? a : b}
  }'
}

# ---------------------------------------------------------------------------
# Sensor backend: emit raw "label<TAB>tempC" lines from whatever tool exists.
# This is the ONLY part that differs from the Linux script.
# ---------------------------------------------------------------------------
# Decide the backend once, in the parent shell (a $(...) subshell can't export
# BACKEND back up). Empty => no backend installed.
BACKEND=""
if   have istats;       then BACKEND="iStats"
elif have osx-cpu-temp; then BACKEND="osx-cpu-temp"
fi

raw_readings() {
  if [ "$BACKEND" = "iStats" ]; then
    # `istats scan` enumerates all SMC temperature keys; plain `istats`
    # covers the common CPU/GPU rows. Run both, dedupe later via labels.
    { istats scan 2>/dev/null; istats 2>/dev/null; } | extract_temps
  elif [ "$BACKEND" = "osx-cpu-temp" ]; then
    local cpu gpu
    cpu="$(osx-cpu-temp 2>/dev/null || true)"
    [ -n "$cpu" ] && printf 'CPU\t%s\n' "$(num_only "$cpu")"
    gpu="$(osx-cpu-temp -g 2>/dev/null || true)"
    [ -n "$gpu" ] && printf 'GPU\t%s\n' "$(num_only "$gpu")"
  else
    return 1
  fi
}

num_only() { printf '%s' "$1" | tr -cd '0-9.'; }

# Pull "<label>\t<celsius>" from arbitrary tool output: any line that contains a
# number immediately followed by °C (or " C") is treated as a temperature row.
extract_temps() {
  awk '
    {
      if (match($0, /[0-9]+(\.[0-9]+)?[ ]*(\xc2\xb0C|°C|C)([^a-zA-Z]|$)/)) {
        chunk = substr($0, RSTART)
        t = chunk; gsub(/[^0-9.].*$/, "", t)        # leading number = temp
        label = substr($0, 1, RSTART-1)
        gsub(/[\(\):]/, " ", label)                 # drop SMC-key parens / colons
        gsub(/[ \t]+$/, "", label); gsub(/[ \t]+/, " ", label)
        gsub(/^ /, "", label)
        if (label == "") label = "Sensor"
        if (t != "") printf "%s\t%s\n", label, t
      }
    }'
}

# Map a free-text sensor label to a trusted category, or "" to skip it.
categorize() {
  local l; l="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
  case "$l" in
    *cpu*|*core*|*proc*)             echo CPU ;;
    *gpu*|*graphic*)                 echo GPU ;;
    *ssd*|*nvme*|*disk*|*drive*|*hdd*) echo DRIVE ;;
    *)                               echo "" ;;     # battery/ambient/etc. ignored
  esac
}

friendly_name() {
  case "$1" in CPU) echo "Processor";; GPU) echo "Graphics chip";;
    DRIVE) echo "Drive";; *) echo "Sensor";; esac
}

# ---------------------------------------------------------------------------
# Build records: friendly \t technical \t input \t eff_warn \t eff_crit \t source
# One record per category (highest reading wins, like picking a primary sensor).
# ---------------------------------------------------------------------------
readings="$(raw_readings || true)"
if [ -z "$readings" ] && [ -z "$BACKEND" ]; then
  echo "$PROG: no temperature backend found." >&2
  echo "$PROG: install one of:  gem install iStats   |   brew install osx-cpu-temp" >&2
  exit 3
fi

records=""
for cat in CPU GPU DRIVE; do
  # highest reading + its label for this category
  best="$(printf '%s\n' "$readings" | while IFS=$'\t' read -r label temp; do
            [ -n "$temp" ] || continue
            [ "$(categorize "$label")" = "$cat" ] || continue
            printf '%s\t%s\n' "$temp" "$label"
          done | sort -t$'\t' -k1 -gr | head -n1)"
  [ -n "$best" ] || continue
  IFS=$'\t' read -r input label <<EOF
$best
EOF

  case "$cat" in
    CPU)   def_warn=$CPU_WARN;   def_crit=$CPU_CRIT ;;
    GPU)   def_warn=$GPU_WARN;   def_crit=$GPU_CRIT ;;
    DRIVE) def_warn=$DRIVE_WARN; def_crit=$DRIVE_CRIT ;;
  esac
  eff_crit="$def_crit"
  eff_warn="$(fmin "$(fsub "$eff_crit" "$WARN_MARGIN")" "$def_warn")"

  records+="$(friendly_name "$cat")"$'\t'"$label"$'\t'"$input"$'\t'"$eff_warn"$'\t'"$eff_crit"$'\t'"default"$'\n'
done

if [ -z "${records//[$'\n\t ']/}" ]; then
  echo "${YEL}$PROG: backend '$BACKEND' returned no CPU/GPU/drive temperatures.${RST}" >&2
  echo "$PROG: try 'istats scan' to see what your Mac exposes." >&2
  exit 4
fi

# ---------------------------------------------------------------------------
# --check
# ---------------------------------------------------------------------------
if [ "$CHECK_ONLY" = 1 ]; then
  echo "Sensor self-check ($PROG) — backend: $BACKEND, config: $CONF"
  echo "-----------------------------------------------------------------------"
  printf "  %-22s %-20s %8s %8s   %s\n" "ROLE" "SENSOR" "WARN" "CRIT" "SOURCE"
  while IFS=$'\t' read -r friendly tech input warn crit src; do
    [ -n "$friendly" ] || continue
    printf "  %-22s %-20s %8s %8s   %s\n" "$friendly" "$tech" "${warn:-—}" "${crit:-—}" "$src"
  done <<EOF
$records
EOF
  echo "-----------------------------------------------------------------------"
  echo "${GRN}OK:${RST} $(printf '%s' "$records" | grep -c $'\t') sensor(s) will be monitored."
  exit 0
fi

# ---------------------------------------------------------------------------
# Normal report.
# ---------------------------------------------------------------------------
status=0
HOT_MSG=""
echo "Machine temperatures ($(date '+%Y-%m-%d %H:%M:%S')) — via $BACKEND"
echo "-----------------------------------------------------------"
while IFS=$'\t' read -r friendly tech input warn crit src; do
  [ -n "$friendly" ] || continue
  label="$friendly ($tech)"
  color=$GRN; tag="OK"
  if   [ -n "$crit" ] && fge "$input" "$crit"; then
    color=$RED; tag="CRITICAL"; [ "$status" -lt 2 ] && status=2
    HOT_MSG="${HOT_MSG}${friendly} very hot: ${input}C. "
  elif [ -n "$warn" ] && fge "$input" "$warn"; then
    color=$YEL; tag="WARN"; [ "$status" -lt 1 ] && status=1
    HOT_MSG="${HOT_MSG}${friendly} warm: ${input}C. "
  fi
  printf "  %-34s %s%6s°C  [%s]%s\n" "$label" "$color" "$input" "$tag" "$RST"
done <<EOF
$records
EOF
echo "-----------------------------------------------------------"

case $status in
  0) echo "${GRN}All sensors within normal range.${RST}" ;;
  1) echo "${YEL}Warning: one or more sensors are running warm.${RST}" ;;
  2) echo "${RED}Critical: one or more sensors at/above critical threshold.${RST}" ;;
esac

# macOS desktop notification (the notify-send equivalent).
if [ "$NOTIFY" = 1 ] && [ "$status" -gt 0 ] && have osascript; then
  osascript -e "display notification \"${HOT_MSG//\"/\'}\" with title \"Machine running hot\"" >/dev/null 2>&1 || true
fi

exit $status
