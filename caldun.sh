#!/usr/bin/env bash
#
# caldun — report the trustworthy machine temperatures, portably.
#
# Auto-discovers temperature sensors from `sensors -j` and reports only the
# trustworthy ones. "Trustworthy" means a known-good kernel driver class:
# CPU (k10temp/coretemp/zenpower/...), GPU (amdgpu/i915/nouveau/...), and
# drives (nvme/drivetemp). ISA Super-I/O chips (e.g. nct6798) are ignored by
# default because their CPUTIN/AUXTIN*/SYSTIN channels are mislabeled on many
# (especially AMD) boards and report bogus values like +127 C.
#
# Thresholds are hybrid: when a sensor reports a hardware limit (temp*_max /
# temp*_crit) we use it; otherwise we fall back to a per-category default. When
# both exist we take the *more conservative* (lower) value, so the hardware
# "damage" limit can only tighten an alert, never loosen one below the default.
# Everything is overridable from /etc/caldun.conf.
#
# Output modes:
#   (default)   human-readable report
#   --check     self-test: discovered sensors and effective thresholds
#   --json      machine-readable report (schema 1); --watch --json emits JSONL
#   --get CAT   a bare number, for scripts
#   --watch [N] one compact timestamped line per sample
#
# Exit codes:
#   0  all OK            2  one or more sensors at/above CRITICAL
#   1  one or more WARN  3  `sensors` not installed (install lm-sensors)
#                        4  no trustworthy sensors found (run: sudo sensors-detect)
#  64  usage error
#
# Watch mode is the one exception to the status exit codes: it exits 0 on a
# clean interrupt, because its code reports "the run ended", not the last
# sample's temperature.

set -euo pipefail
set -f          # no pathname expansion: EXTRA_SENSORS/IGNORE_SENSORS hold case
                # globs (e.g. "*"), matched via `case`, never against the cwd.

PROG=${0##*/}
# Kept in lockstep with debian/changelog: debian/rules refuses to build when the
# two disagree, so the installed script can never report a version the package
# does not have.
VERSION=1.7.1
SCHEMA=1        # --json schema version; bump only on an incompatible change

# Internal field separator for the record TSVs. Deliberately US (0x1f), not TAB:
# tab is IFS *whitespace*, so `IFS="$US" read` collapses runs of tabs and an empty
# field (a sensor with no sibling channel, a chip with no hardware limit) silently
# shifts every later column left. US is not IFS whitespace, so empty fields survive.
US=$'\x1f'

# ---------------------------------------------------------------------------
# Defaults (overridden by the config file below).
# ---------------------------------------------------------------------------
WARN_MARGIN=10               # WARN this many C below the effective CRITICAL
CPU_WARN=85;   CPU_CRIT=95
GPU_WARN=85;   GPU_CRIT=95
DRIVE_WARN=75; DRIVE_CRIT=83 # conservative on purpose; see README (NVMe incident)
DEFAULT_WARN=""; DEFAULT_CRIT=""   # for uncategorised ("Other") sensors: hw-only
EXTRA_SENSORS=""             # force-include: "chip-glob[=CATEGORY] ..."
IGNORE_SENSORS=""            # force-exclude: "chip-glob ..."
NOTIFY_DEFAULT=0             # 1 => behave as if --notify was always passed

# Faulty-sensor detection. A real overheat heats every channel on a chip; a
# buggy sensor (e.g. the NVMe Composite firmware bug on some Samsung 980s, which
# reports phantom ~84 C spikes while the drive's other channels stay ~62 C) makes
# ONE channel disagree with its siblings. When an alarming channel is hotter than
# every other channel on the same chip by more than ANOMALY_MARGIN AND those
# siblings are all below their WARN threshold, the reading is treated as a
# SUSPECTED sensor fault: it does NOT raise a thermal alarm, but is reported
# separately, annotated with any matching entry from the known-issues database.
ANOMALY_DETECT=1             # 0 => disable; trust every reading at face value
ANOMALY_MARGIN=15            # C a channel must exceed all (sub-WARN) siblings by
KNOWN_ISSUES_DB="${CALDUN_ISSUES:-/etc/caldun-known-issues.conf}"
NOTIFY_SUSPECT=1             # 1 => send a desktop notification whenever a suspect
                             #      sensor reading is detected, even without --notify/
                             #      --popup, so random spikes don't go unannounced.

# Clocks and fans (see the CPU-frequency notes above freq_ceiling()).
SHOW_CLOCKS=1                # 0 => never report CPU frequency
SHOW_FANS=1                  # 0 => never report fan speeds
MIN_FREQ_SAMPLES=20          # observations before an observed ceiling is trusted

# Peak (high-water mark) tracking. State lives under the user's XDG state dir
# because the packaged timer runs as a *user* service and must not need root.
PEAK_TRACK=1                 # 0 => never read or write the peak file
PEAK_STATE="${CALDUN_PEAKS:-${XDG_STATE_HOME:-$HOME/.local/state}/caldun/peaks}"

WATCH_DEFAULT_INTERVAL=30

CONF="${CALDUN_CONF:-/etc/caldun.conf}"
# shellcheck source=/dev/null
[ -r "$CONF" ] && . "$CONF"

# ---------------------------------------------------------------------------
# Arguments.
#
# Hand-rolled on purpose. `getopts` cannot do long options; enhanced getopt(1)
# could, but is GNU-only and would break the macOS port, which carries a copy of
# this parser. At this flag count a while/case loop is smaller than either.
# ---------------------------------------------------------------------------
NOTIFY=$NOTIFY_DEFAULT
POPUP=0
CHECK_ONLY=0
JSON_OUT=0
GET_TARGET=""
WATCH=0
WATCH_INTERVAL=$WATCH_DEFAULT_INTERVAL
PEAK_SHOW=0

usage() {
  cat <<EOF
$PROG $VERSION — report the trustworthy machine temperatures

Usage: $PROG [OPTION]...

Output modes (mutually exclusive):
  (none)          human-readable temperature report
  --check         self-test: list discovered sensors and effective thresholds,
                  then exit (exit 0 if sensors found, exit 4 if none)
  --json          machine-readable report, schema $SCHEMA (implies no colour)
  --get CATEGORY  print one bare number and nothing else, for scripts.
                  CATEGORY is cpu|gpu|drive|other, optionally CATEGORY:CHIP
                  (e.g. drive:nvme-pci-0300). Without a chip the hottest
                  sensor in the category wins.
  --watch [N]     sample every N seconds (default $WATCH_DEFAULT_INTERVAL) until
                  interrupted, one compact line per sample. With --json, one
                  JSON object per line (JSONL).

Modifiers:
  --notify        send a desktop notification on WARN or CRITICAL only
                  (used by the systemd timer; silent when all sensors are OK)
  --popup         always send a desktop notification with the full reading
                  (for on-demand use: keyboard shortcut, panel launcher, etc.)
  --peak          report the high-water mark for each sensor since boot
  -V, --version   print the version and exit
  -h, --help      show this help and exit

Config:     $CONF
Peak state: $PEAK_STATE
Exit codes: 0 OK  1 WARN  2 CRITICAL  3 sensors/jq not installed
            4 no usable sensors  64 usage error
EOF
}

usage_err() { printf '%s: %s\n' "$PROG" "$1" >&2; printf "Try '%s --help'.\n" "$PROG" >&2; exit 64; }

# Is "$1" usable as an option value (present, and not itself an option)?
next_is_value() {
  case "${1-}" in
    ''|-*) return 1 ;;
    *)     return 0 ;;
  esac
}

while [ $# -gt 0 ]; do
  opt=$1
  optval=""
  has_val=0
  case "$opt" in
    --*=*) optval=${opt#*=}; opt=${opt%%=*}; has_val=1 ;;
  esac
  case "$opt" in
    --notify) [ "$has_val" = 0 ] || usage_err "--notify takes no value"; NOTIFY=1 ;;
    --popup)  [ "$has_val" = 0 ] || usage_err "--popup takes no value";  POPUP=1 ;;
    --check)  [ "$has_val" = 0 ] || usage_err "--check takes no value";  CHECK_ONLY=1 ;;
    --json)   [ "$has_val" = 0 ] || usage_err "--json takes no value";   JSON_OUT=1 ;;
    --peak)   [ "$has_val" = 0 ] || usage_err "--peak takes no value";   PEAK_SHOW=1 ;;
    --get)
      if [ "$has_val" = 0 ]; then
        next_is_value "${2-}" || usage_err "--get requires a category (cpu|gpu|drive|other)"
        shift; optval=$1
      fi
      [ -n "$optval" ] || usage_err "--get requires a category (cpu|gpu|drive|other)"
      GET_TARGET=$optval
      ;;
    --watch)
      WATCH=1
      if [ "$has_val" = 0 ] && next_is_value "${2-}"; then shift; optval=$1; has_val=1; fi
      if [ "$has_val" = 1 ]; then
        case "$optval" in
          ''|*[!0-9]*) usage_err "--watch interval must be a whole number of seconds: $optval" ;;
        esac
        [ "$optval" -ge 1 ] || usage_err "--watch interval must be at least 1 second"
        WATCH_INTERVAL=$optval
      fi
      ;;
    -V|--version) printf '%s %s\n' "$PROG" "$VERSION"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; [ $# -eq 0 ] || usage_err "unexpected argument: $1"; break ;;
    *) usage_err "unknown argument: $1" ;;
  esac
  shift
done

# Mode exclusivity. --json modifies the report and watch mode; everything else
# is a distinct mode and cannot be combined.
modes=0
[ "$CHECK_ONLY" = 1 ] && modes=$((modes + 1))
[ -n "$GET_TARGET" ] && modes=$((modes + 1))
[ "$WATCH" = 1 ] && modes=$((modes + 1))
[ "$modes" -le 1 ] || usage_err "--check, --get and --watch are mutually exclusive"
if [ -n "$GET_TARGET" ] && [ "$JSON_OUT" = 1 ]; then
  usage_err "--get prints a bare number; it cannot be combined with --json"
fi
if [ "$CHECK_ONLY" = 1 ] && [ "$JSON_OUT" = 1 ]; then
  usage_err "--check has no JSON form"
fi

# Colors (only when stdout is a terminal, and never in machine-readable modes).
if [ -t 1 ] && [ "$JSON_OUT" = 0 ] && [ -z "$GET_TARGET" ]; then
  RED=$'\033[31m'; YEL=$'\033[33m'; GRN=$'\033[32m'; DIM=$'\033[2m'; RST=$'\033[0m'
else RED=; YEL=; GRN=; DIM=; RST=; fi

# ---------------------------------------------------------------------------
# Dependencies. A canned fixture (CALDUN_SENSORS_JSON) stands in for lm-sensors,
# so the script can be exercised on machines — CI runners, VMs — that have no
# trustworthy chips at all. jq is required either way.
# ---------------------------------------------------------------------------
if [ -z "${CALDUN_SENSORS_JSON:-}" ]; then
  command -v sensors >/dev/null 2>&1 || { echo "$PROG: 'sensors' not found — install lm-sensors" >&2; exit 3; }
fi
command -v jq >/dev/null 2>&1 || { echo "$PROG: 'jq' not found — install jq" >&2; exit 3; }

# ---------------------------------------------------------------------------
# Numeric helpers (temperatures are decimals; bash can't compare floats).
# ---------------------------------------------------------------------------
fge()  { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0 >= b+0)}'; }                # a >= b ?
fgt()  { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0 >  b+0)}'; }                # a >  b ?
fsub() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.1f", a-b}'; }               # a - b
fmin() {                                                                       # min, ignoring blanks
  awk -v a="$1" -v b="$2" 'BEGIN{
    if (a=="") {print b} else if (b=="") {print a}
    else {print (a+0 < b+0) ? a : b}
  }'
}

# Read a single-line file, quietly. Never fails the script.
slurp() {
  local v=""
  [ -r "$1" ] || return 0
  IFS= read -r v < "$1" 2>/dev/null || true
  printf '%s' "$v"
}

now_iso() { date '+%Y-%m-%dT%H:%M:%S'; }

# Strip anything that would corrupt a record: the field separator itself, tabs
# and newlines. Model names come from sysfs and defect/solution text from the
# known-issues DB, so neither is under this script's control.
sanitize() {
  local v=${1-}
  v=${v//"$US"/ }
  v=${v//$'\t'/ }
  v=${v//$'\n'/ }
  printf '%s' "$v"
}

# ---------------------------------------------------------------------------
# Peak (high-water) state.
#
# Keys are "<metric>.<subject>" — temp.<chip>, suspect.<chip>, freq.cpu — so the
# store is not limited to temperatures; the frequency ceiling in freq_ceiling()
# depends on that. Each record keeps value, timestamp and an observation count.
# Peaks reset when the recorded boot_id changes.
# ---------------------------------------------------------------------------
declare -A PK_VAL=() PK_TS=() PK_CNT=()
PK_BOOT=""
PK_LOADED=0
PK_DIRTY=0

peaks_load() {
  [ "$PEAK_TRACK" = 1 ] || return 0
  [ "$PK_LOADED" = 0 ] || return 0
  PK_LOADED=1
  PK_BOOT="$(slurp /proc/sys/kernel/random/boot_id)"
  [ -r "$PEAK_STATE" ] || return 0
  # The peak file is TAB-separated, unlike the in-memory records: it is state a
  # human may want to read or delete, and peaks_save guarantees no field is ever
  # empty ("-" placeholders), so tab-collapsing cannot shift columns here.
  local k v t c file_boot=""
  while IFS=$'\t' read -r k v t c || [ -n "$k" ]; do
    case "$k" in
      ''|'#'*) continue ;;
      boot_id) file_boot=$v; continue ;;
    esac
    PK_VAL[$k]=$v; PK_TS[$k]=${t:-}; PK_CNT[$k]=${c:-1}
  done < "$PEAK_STATE"
  # A different boot means the old high-water marks describe a previous run of
  # the machine; "since boot" would be a lie. Start over.
  if [ -n "$PK_BOOT" ] && [ -n "$file_boot" ] && [ "$file_boot" != "$PK_BOOT" ]; then
    PK_VAL=(); PK_TS=(); PK_CNT=()
    PK_DIRTY=1
  fi
}

# peaks_update <key> <value> <timestamp>
peaks_update() {
  [ "$PEAK_TRACK" = 1 ] || return 0
  local k=$1 v=$2 ts=$3 old=${PK_VAL[$1]:-}
  PK_CNT[$k]=$(( ${PK_CNT[$k]:-0} + 1 ))
  PK_DIRTY=1
  if [ -z "$old" ] || fgt "$v" "$old"; then
    PK_VAL[$k]=$v; PK_TS[$k]=$ts
  fi
}

peaks_save() {
  [ "$PEAK_TRACK" = 1 ] || return 0
  [ "$PK_DIRTY" = 1 ] || return 0
  local dir tmp k
  dir=${PEAK_STATE%/*}
  [ "$dir" = "$PEAK_STATE" ] && dir=.
  mkdir -p "$dir" 2>/dev/null || return 0
  # Same-directory temp file + mv, so an interactive run and the 2-minute timer
  # run overlapping never leave a half-written file. No locking: last writer wins,
  # and losing one sample of a high-water mark is harmless.
  tmp="$(mktemp "$dir/.peaks.XXXXXX" 2>/dev/null)" || return 0
  {
    printf '# caldun peak state — rewritten automatically, safe to delete\n'
    printf 'boot_id\t%s\n' "$PK_BOOT"
    for k in "${!PK_VAL[@]}"; do
      # "-" rather than "" — see the tab-collapsing note in peaks_load.
      printf '%s\t%s\t%s\t%s\n' "$k" "${PK_VAL[$k]}" "${PK_TS[$k]:--}" "${PK_CNT[$k]:-1}"
    done
  } > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
  mv -f "$tmp" "$PEAK_STATE" 2>/dev/null || rm -f "$tmp"
  PK_DIRTY=0
}

# ---------------------------------------------------------------------------
# Device identity + known-issues database (for faulty-sensor diagnostics).
# ---------------------------------------------------------------------------
# Resolve a sensors chip name to a real device "model<TAB>firmware", when we can.
# Currently knows how to map NVMe chips (nvme-pci-<bus><devfn>) to their sysfs
# entry via the PCI address; other chips return nothing (model unknown).
device_identity() {
  local chip="$1"
  local driver="${chip%%-*}" want pcipart dev addr rest bus slot func model fw oldf found
  case "$driver" in
    nvme)
      pcipart="${chip#nvme-pci-}"
      # The script runs with `set -f` (noglob); enable globbing just to list the
      # sysfs nvme dirs, then restore it before doing anything else.
      oldf=0; case $- in *f*) oldf=1 ;; esac
      set +f
      found=""
      for dev in /sys/class/nvme/nvme*; do
        [ -r "$dev/address" ] || continue
        addr="$(cat "$dev/address" 2>/dev/null)"          # e.g. 0000:03:00.0
        rest="${addr#*:}"; bus="${rest%%:*}"
        rest="${rest#*:}"; slot="${rest%%.*}"; func="${rest#*.}"
        # libsensors suffix = <bus><device-function> as 2+2 hex (devfn = slot*8|func)
        want="$(printf '%02x%02x' "$((16#$bus))" "$(((16#$slot) * 8 + 16#$func))" 2>/dev/null)"
        if [ "$want" = "$pcipart" ]; then found="$dev"; break; fi
      done
      [ "$oldf" = 1 ] && set -f
      if [ -n "$found" ]; then
        model="$(cat "$found/model" 2>/dev/null)"
        fw="$(cat "$found/firmware_rev" 2>/dev/null)"
        # trim trailing whitespace (sysfs pads these fields)
        model="${model%"${model##*[![:space:]]}"}"
        fw="${fw%"${fw##*[![:space:]]}"}"
        printf '%s\t%s' "$model" "$fw"
      fi
      ;;
  esac
  return 0
}

# Look up a device in the known-issues DB. Prints "defect<TAB>solution" for the
# first record whose `device` glob matches the model and (optional) `firmware`
# glob matches. Records are blank-line separated "key: value" blocks; keys are
# device, firmware (optional), defect, solution. '#' lines are comments.
lookup_known_issue() {
  local model="$1" fw="$2"
  [ -n "$model" ] && [ -r "$KNOWN_ISSUES_DB" ] || return 0
  local line key val d_dev="" d_fw="" d_defect="" d_solution=""
  _emit_if_match() {
    [ -n "$d_dev" ] && [ -n "$d_defect" ] || return 1
    local ok=1
    shopt -s nocasematch
    # shellcheck disable=SC2254
    case "$model" in $d_dev) ;; *) ok=0 ;; esac
    # shellcheck disable=SC2254
    if [ -n "$d_fw" ]; then case "$fw" in $d_fw) ;; *) ok=0 ;; esac; fi
    shopt -u nocasematch
    [ "$ok" = 1 ] || return 1
    printf '%s\t%s\n' "$d_defect" "$d_solution"
    return 0
  }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '#'*) continue ;;
      '')   if _emit_if_match; then return 0; fi
            d_dev=""; d_fw=""; d_defect=""; d_solution=""; continue ;;
    esac
    key="${line%%:*}"; val="${line#*:}"
    val="${val#"${val%%[![:space:]]*}"}"     # ltrim
    case "$key" in
      device)   d_dev="$val" ;;
      firmware) d_fw="$val" ;;
      defect)   d_defect="$val" ;;
      solution) d_solution="$val" ;;
    esac
  done < "$KNOWN_ISSUES_DB"
  _emit_if_match || true
}

# ---------------------------------------------------------------------------
# Discovery: map a chip to a trusted category, or "" if untrusted.
# Driver name is the token before the first "-" (e.g. k10temp-pci-00c3).
# ---------------------------------------------------------------------------
categorize() {
  local chip="$1" driver="${1%%-*}" pat entry glob cat
  for pat in $IGNORE_SENSORS; do
    # shellcheck disable=SC2254
    case "$chip" in $pat) return 0 ;; esac          # excluded -> print nothing
  done
  for entry in $EXTRA_SENSORS; do
    glob="${entry%%=*}"; cat="OTHER"
    [ "$entry" != "$glob" ] && cat="${entry#*=}"
    # shellcheck disable=SC2254
    case "$chip" in $glob) printf '%s' "$cat"; return 0 ;; esac
  done
  case "$driver" in
    k10temp|coretemp|zenpower|k8temp|acpitz) printf CPU ;;
    amdgpu|radeon|i915|xe|nouveau)           printf GPU ;;
    nvme|drivetemp)                          printf DRIVE ;;
    *)                                       printf '' ;;
  esac
}

# All (label, input, max, crit) TEMPERATURE features of one chip, as TSV.
#
# The temp*_input filter is load-bearing, not cosmetic: a chip's feature list
# also carries voltages (in0_input), fans (fan1_input) and power (power1_input).
# Matching any *_input made vddgfx (~0.7 V) look like a 0.7 C sibling channel on
# amdgpu, which dragged siblings_min down far enough that every genuine GPU
# alarm was misfiled as a suspect sensor and never escalated. Temperatures only.
features_of() {
  printf '%s' "$SENSORS_JSON" | jq -r --arg c "$1" '
    .[$c] | to_entries[] | select(.key != "Adapter") | . as $f
    | ( $f.value | to_entries
        | map(select(.key | test("^temp[0-9]+_input$"))) | .[0].key ) as $ik
    | select($ik != null)
    | ( $ik | sub("_input$"; "") ) as $p
    | [ $f.key,
        ( $f.value[$ik]            | tostring ),
        ( ($f.value[$p+"_max"]) // "" | tostring ),
        ( ($f.value[$p+"_crit"]) // "" | tostring ) ] | join("\u001f")'
}

# All (label, rpm) FAN features of one chip, as TSV. Same trust rule as
# temperatures: callers only ask about chips that categorize() accepted, so the
# nct6798's fan channels are no more trusted here than its temperature channels.
fans_of() {
  printf '%s' "$SENSORS_JSON" | jq -r --arg c "$1" '
    .[$c] | to_entries[] | select(.key != "Adapter") | . as $f
    | ( $f.value | to_entries
        | map(select(.key | test("^fan[0-9]+_input$"))) | .[0].key ) as $ik
    | select($ik != null)
    | [ $f.key, ( $f.value[$ik] | tostring ) ] | join("\u001f")'
}

# Pick the representative feature for a category from a chip's feature TSV.
pick_primary() {
  local category="$1" feats="$2" patterns p line
  case "$category" in
    CPU)   patterns="Tctl Tdie Package Tccd Core" ;;
    GPU)   patterns="edge junction mem Temp" ;;
    DRIVE) patterns="Composite Sensor temp1" ;;
    *)     patterns="" ;;
  esac
  for p in $patterns; do
    line=$(printf '%s\n' "$feats" | awk -F"$US" -v p="$p" 'index(tolower($1),tolower(p)){print; exit}')
    [ -n "$line" ] && { printf '%s\n' "$line"; return; }
  done
  printf '%s\n' "$feats" | head -n1
}

friendly_name() {
  case "$1" in CPU) echo "Processor";; GPU) echo "Graphics chip";;
    DRIVE) echo "Drive";; *) echo "Sensor";; esac
}

# ---------------------------------------------------------------------------
# Sampling. Split out of the top level so watch mode can re-read; a fixture
# file short-circuits lm-sensors entirely.
# ---------------------------------------------------------------------------
SENSORS_JSON=""
read_sensors() {
  if [ -n "${CALDUN_SENSORS_JSON:-}" ]; then
    if [ ! -r "$CALDUN_SENSORS_JSON" ]; then
      echo "$PROG: cannot read CALDUN_SENSORS_JSON=$CALDUN_SENSORS_JSON" >&2
      exit 4
    fi
    SENSORS_JSON="$(cat "$CALDUN_SENSORS_JSON")"
  else
    SENSORS_JSON="$(sensors -j 2>/dev/null || true)"
  fi
  if [ -z "$SENSORS_JSON" ] || ! printf '%s' "$SENSORS_JSON" | jq -e . >/dev/null 2>&1; then
    echo "$PROG: 'sensors -j' produced no usable output." >&2
    echo "$PROG: run 'sudo sensors-detect' to configure sensors, then retry." >&2
    exit 4
  fi
}

# ---------------------------------------------------------------------------
# Build the sensor list. Each record (tab-separated):
#   friendly  technical  input  eff_warn  eff_crit  source  chip  siblings_min  category
# `siblings_min` is the COOLEST other channel on the same chip (blank if none).
# It lets the report tell a real overheat (every channel hot, so even the coolest
# is warm) from a faulty sensor (some channels read bogus-high while a sane
# channel on the same die stays cool). Using the coolest — not the hottest —
# sibling matters because a firmware bug can corrupt more than one channel at once
# (e.g. the Samsung 980 spikes both Composite and Sensor 1 together while Sensor 2
# stays accurate).
# ---------------------------------------------------------------------------
build_records() {
  local records="" chip category feats primary label input hw_max hw_crit \
        def_warn def_crit hw_basis eff_crit source warn_from_crit eff_warn sib_min
  while IFS= read -r chip; do
    [ -n "$chip" ] || continue
    category="$(categorize "$chip")"
    [ -n "$category" ] || continue
    feats="$(features_of "$chip")"
    [ -n "$feats" ] || continue
    primary="$(pick_primary "$category" "$feats")"
    IFS="$US" read -r label input hw_max hw_crit <<<"$primary"
    [ -n "$input" ] || continue

    # coolest channel on this chip other than the chosen primary
    sib_min="$(printf '%s\n' "$feats" | awk -F"$US" -v pl="$label" '$1!=pl{print $2}' \
                 | awk 'NF{ if (!c || $1+0 < m+0) { m=$1; c=1 } } END{ if (c) print m }')"

    # category default thresholds
    case "$category" in
      CPU)   def_warn=$CPU_WARN;   def_crit=$CPU_CRIT ;;
      GPU)   def_warn=$GPU_WARN;   def_crit=$GPU_CRIT ;;
      DRIVE) def_warn=$DRIVE_WARN; def_crit=$DRIVE_CRIT ;;
      *)     def_warn=$DEFAULT_WARN; def_crit=$DEFAULT_CRIT ;;
    esac

    # hybrid: hardware basis (prefer max, else crit), combined with default via min()
    hw_basis=""
    if [ -n "$hw_max" ]; then hw_basis=$hw_max
    elif [ -n "$hw_crit" ]; then hw_basis=$hw_crit; fi
    eff_crit="$(fmin "$hw_basis" "$def_crit")"
    source="default"
    if [ -n "$hw_basis" ]; then
      if [ -z "$def_crit" ] || fge "$def_crit" "$hw_basis"; then source="hardware"; fi
    fi
    if [ -n "$eff_crit" ]; then
      warn_from_crit="$(fsub "$eff_crit" "$WARN_MARGIN")"
      eff_warn="$(fmin "$warn_from_crit" "$def_warn")"
    else
      eff_warn=""
    fi

    records+="$(friendly_name "$category")$US${chip%%-*} $label$US$input$US$eff_warn$US$eff_crit$US$source$US$chip$US$sib_min$US$category"$'\n'
  done <<<"$(printf '%s' "$SENSORS_JSON" | jq -r 'keys[]')"
  printf '%s' "$records"
}

# ---------------------------------------------------------------------------
# Classification — the single source of truth for what a reading means.
# Every renderer (text, JSON, watch, get) goes through this; none re-implements
# the threshold or anomaly rules.
#
#   status_of <input> <warn> <crit> <siblings_min>
#     -> ok | warn | critical | suspect | unknown
# ---------------------------------------------------------------------------
status_of() {
  local input=$1 warn=$2 crit=$3 sibmin=$4 alarming=0

  if [ -n "$crit" ] && fge "$input" "$crit"; then alarming=2
  elif [ -n "$warn" ] && fge "$input" "$warn"; then alarming=1; fi

  # Faulty-sensor test: in a real overheat every channel on a chip is hot, so even
  # the COOLEST one is at least warm. If an alarming channel sits more than
  # ANOMALY_MARGIN above a sibling that is still below WARN, a sane channel on the
  # same die disagrees with it — treat the reading as a suspect sensor fault, not
  # real heat. (Comparing against the coolest sibling, not the hottest, is what
  # catches firmware bugs that corrupt several channels at once.)
  if [ "$ANOMALY_DETECT" = 1 ] && [ "$alarming" -gt 0 ] && [ -n "$sibmin" ] \
     && { [ -z "$warn" ] || ! fge "$sibmin" "$warn"; } \
     && fge "$(fsub "$input" "$sibmin")" "$ANOMALY_MARGIN"; then
    printf 'suspect'; return 0
  fi

  case "$alarming" in
    2) printf 'critical' ;;
    1) printf 'warn' ;;
    *) if [ -z "$crit" ]; then printf 'unknown'; else printf 'ok'; fi ;;
  esac
}

# Exit-code contribution of a status word (suspect never escalates).
status_rank() {
  case "$1" in critical) printf 2 ;; warn) printf 1 ;; *) printf 0 ;; esac
}

# Display tag for the text report.
status_tag() {
  case "$1" in
    critical) printf 'CRITICAL' ;; warn) printf 'WARN' ;;
    suspect)  printf 'SUSPECT'  ;; unknown) printf '—' ;;
    *)        printf 'OK' ;;
  esac
}

status_color() {
  case "$1" in
    critical) printf '%s' "$RED" ;; warn|suspect) printf '%s' "$YEL" ;;
    unknown)  printf '%s' "$DIM" ;; *) printf '%s' "$GRN" ;;
  esac
}

# ---------------------------------------------------------------------------
# CPU frequency.
#
# The obvious formula — scaling_cur_freq / cpuinfo_max_freq — is wrong on a
# large class of AMD machines and must not be used blindly. Measured on a Ryzen
# 7 4800U with scaling_driver=acpi-cpufreq: cpuinfo_max_freq reports 1800000
# (the *base* clock) while the part boosts to 4.2 GHz, and scaling_cur_freq sits
# at 1.67-1.91 GHz at idle — i.e. already ABOVE "max". The ratio reads over 100%
# doing nothing and would reach ~233% under boost. acpi-cpufreq exposes no boost
# ceiling anywhere in sysfs (scaling_available_frequencies lists P-states only);
# recovering it needs MSR/aperf-mperf reads as root, which is out of scope for a
# non-privileged user timer.
#
# So: report absolute clocks always, and a percentage only against a ceiling we
# actually trust —
#   * amd_pstate/intel_pstate: cpuinfo_max_freq IS the boost ceiling. Use it.
#   * otherwise: the highest frequency ever observed on this machine (peak
#     state), once there are enough samples for that to mean something.
# ---------------------------------------------------------------------------
# Mean clock across online cores — deliberately not the maximum. caldun is itself
# the load on the busiest core (bash, jq and awk are running while this reads
# sysfs), so a max-of-cores reading pins to boost on every single sample and says
# nothing about the machine. The mean tracks what a multi-core build actually
# gets: near boost when the machine is free, visibly depressed when it is not.
cpu_freq_khz() {
  local f v sum=0 n=0 oldf=0
  case $- in *f*) oldf=1 ;; esac
  set +f
  for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do
    [ -r "$f" ] || continue
    v="$(cat "$f" 2>/dev/null)" || continue
    case "$v" in ''|*[!0-9]*) continue ;; esac
    sum=$(( sum + v )); n=$(( n + 1 ))
  done
  [ "$oldf" = 1 ] && set -f
  [ "$n" -gt 0 ] && printf '%s' $(( sum / n ))
  return 0
}

cpu_freq_driver() { slurp /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver; }
cpu_freq_base_khz() { slurp /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq; }

# Prints "<ceiling_khz>\t<source>", or nothing when no ceiling can be trusted.
freq_ceiling() {
  local driver base observed count
  driver="$(cpu_freq_driver)"
  base="$(cpu_freq_base_khz)"
  case "$driver" in
    amd_pstate*|amd-pstate*|intel_pstate*|intel_cpufreq*)
      [ -n "$base" ] && printf '%s\thardware' "$base"
      return 0 ;;
  esac
  observed=${PK_VAL[freq.cpu]:-}
  count=${PK_CNT[freq.cpu]:-0}
  # Only trust an observed ceiling once it has both enough samples and evidence
  # of boost (a reading above the advertised base clock). Two idle samples must
  # not become a denominator.
  if [ -n "$observed" ] && [ "$count" -ge "$MIN_FREQ_SAMPLES" ] \
     && { [ -z "$base" ] || fgt "$observed" "$base"; }; then
    printf '%s\tobserved' "$observed"
  fi
  return 0
}

khz_to_ghz() { awk -v k="$1" 'BEGIN{printf "%.2f", k/1000000}'; }

# One human-readable clock line, or nothing.
clock_line() {
  local cur ceil ceil_khz ceil_src pct
  [ "$SHOW_CLOCKS" = 1 ] || return 0
  cur="$(cpu_freq_khz)"
  [ -n "$cur" ] || return 0
  ceil="$(freq_ceiling)"
  ceil_khz=${ceil%%$'\t'*}; ceil_src=""
  [ "$ceil" != "$ceil_khz" ] && ceil_src="${ceil#*$'\t'}"
  if [ -n "$ceil_khz" ]; then
    pct="$(awk -v c="$cur" -v m="$ceil_khz" 'BEGIN{printf "%.0f", (c*100)/m}')"
    printf '  %-34s %s GHz  (%s%% of %s GHz %s max)\n' "CPU clock" \
      "$(khz_to_ghz "$cur")" "$pct" "$(khz_to_ghz "$ceil_khz")" "$ceil_src"
  else
    printf '  %-34s %s GHz\n' "CPU clock" "$(khz_to_ghz "$cur")"
  fi
}

# Fan lines for trusted chips, as TSV "label<TAB>rpm" (caller formats).
fan_readings() {
  local chip category label rpm
  [ "$SHOW_FANS" = 1 ] || return 0
  while IFS= read -r chip; do
    [ -n "$chip" ] || continue
    category="$(categorize "$chip")"
    [ -n "$category" ] || continue
    while IFS="$US" read -r label rpm; do
      [ -n "$label" ] || continue
      printf '%s%s%s\n' "${chip%%-*} $label" "$US" "$rpm"
    done <<<"$(fans_of "$chip")"
  done <<<"$(printf '%s' "$SENSORS_JSON" | jq -r 'keys[]')"
  return 0
}

# ---------------------------------------------------------------------------
# Enrich records with status + suspect diagnostics. Emits one TSV line per
# sensor with every field any renderer needs:
#   friendly technical chip category celsius warn crit source status sibmin
#   model firmware defect solution
# ---------------------------------------------------------------------------
enrich_records() {
  local friendly tech input warn crit src chip sibmin category \
        st ident model fw issue defect solution
  while IFS="$US" read -r friendly tech input warn crit src chip sibmin category; do
    [ -n "$friendly" ] || continue
    st="$(status_of "$input" "$warn" "$crit" "$sibmin")"
    model=""; fw=""; defect=""; solution=""
    if [ "$st" = suspect ]; then
      ident="$(device_identity "$chip")"
      model="${ident%%$'\t'*}"
      [ "$ident" != "$model" ] && fw="${ident#*$'\t'}"
      issue="$(lookup_known_issue "$model" "$fw")"
      defect="${issue%%$'\t'*}"
      [ "$issue" != "$defect" ] && solution="${issue#*$'\t'}"
    fi
    # Tabs would corrupt the TSV; the known-issues DB is free text.
    printf '%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s\n' \
      "$friendly" "$US" "$tech" "$US" "$chip" "$US" "$category" "$US" "$input" "$US" \
      "$warn" "$US" "$crit" "$US" "$src" "$US" "$st" "$US" "$sibmin" "$US" \
      "$(sanitize "$model")" "$US" "$(sanitize "$fw")" "$US" \
      "$(sanitize "$defect")" "$US" "$(sanitize "$solution")"
  done <<<"$records"
}

# Overall status from enriched records.
overall_status() {
  local line st r max=0
  while IFS="$US" read -r _ _ _ _ _ _ _ _ st _; do
    [ -n "$st" ] || continue
    r="$(status_rank "$st")"
    [ "$r" -gt "$max" ] && max=$r
  done <<<"$1"
  printf '%s' "$max"
}

# Record this sample's peaks. Suspect readings are tracked separately so a
# phantom 84 C spike never becomes the machine's permanent high-water mark.
record_peaks() {
  local enriched=$1 ts=$2 friendly tech chip category input st freq
  [ "$PEAK_TRACK" = 1 ] || return 0
  while IFS="$US" read -r friendly tech chip category input _ _ _ st _; do
    [ -n "$chip" ] || continue
    if [ "$st" = suspect ]; then
      peaks_update "suspect.$chip" "$input" "$ts"
    else
      peaks_update "temp.$chip" "$input" "$ts"
    fi
  done <<<"$enriched"
  if [ "$SHOW_CLOCKS" = 1 ]; then
    freq="$(cpu_freq_khz)"
    [ -n "$freq" ] && peaks_update freq.cpu "$freq" "$ts"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Renderers.
# ---------------------------------------------------------------------------
render_check() {
  local friendly tech input warn crit src chip sibmin category
  echo "Sensor self-check ($PROG) — config: $CONF"
  echo "-----------------------------------------------------------------------"
  printf "  %-22s %-20s %8s %8s   %s\n" "ROLE" "SENSOR" "WARN" "CRIT" "SOURCE"
  while IFS="$US" read -r friendly tech input warn crit src chip sibmin category; do
    [ -n "$friendly" ] || continue
    printf "  %-22s %-20s %8s %8s   %s\n" "$friendly" "$tech" \
      "${warn:-—}" "${crit:-—}" "$src"
  done <<<"$records"
  echo "-----------------------------------------------------------------------"
  echo "${GRN}OK:${RST} $(printf '%s' "$records" | grep -c "$US") trustworthy sensor(s) will be monitored."
}

# Peak section for the text report (--peak).
render_peaks() {
  local k shown=0 kind chip
  peaks_load
  for k in "${!PK_VAL[@]}"; do
    case "$k" in temp.*|suspect.*|freq.cpu) ;; *) continue ;; esac
    shown=1
  done
  [ "$shown" = 1 ] || { echo; echo "${DIM}No peak history recorded yet for this boot.${RST}"; return 0; }
  echo
  echo "Peaks since boot:"
  for k in "${!PK_VAL[@]}"; do
    kind=${k%%.*}; chip=${k#*.}
    case "$kind" in
      temp)    printf '  %-34s %6s°C  (at %s)\n' "$chip" "${PK_VAL[$k]}" "${PK_TS[$k]:-?}" ;;
      suspect) printf '  %-34s %6s°C  (at %s, suspect — excluded)\n' "$chip" "${PK_VAL[$k]}" "${PK_TS[$k]:-?}" ;;
      freq)    printf '  %-34s %6s GHz (at %s, %s samples)\n' "CPU clock" \
                 "$(khz_to_ghz "${PK_VAL[$k]}")" "${PK_TS[$k]:-?}" "${PK_CNT[$k]:-1}" ;;
    esac
  done
}

# The human-readable report. Sets HOT_MSG/POPUP_MSG/SUSPECT_NOTE for notifications.
HOT_MSG=""; POPUP_MSG=""; SUSPECT_NOTE=""
render_text() {
  local enriched=$1 status=$2
  local friendly tech chip category input warn crit src st sibmin model fw defect solution
  local label color tag suspect_msg="" devdesc fanlabel fanrpm

  HOT_MSG=""; POPUP_MSG=""; SUSPECT_NOTE=""
  echo "Machine temperatures ($(date '+%Y-%m-%d %H:%M:%S'))"
  echo "-----------------------------------------------------------"
  while IFS="$US" read -r friendly tech chip category input warn crit src st sibmin model fw defect solution; do
    [ -n "$friendly" ] || continue
    label="$friendly ($tech)"
    color="$(status_color "$st")"; tag="$(status_tag "$st")"
    case "$st" in
      critical) HOT_MSG="${HOT_MSG}🔴 ${friendly} is very hot: ${input}°C (${tech})\n" ;;
      warn)     HOT_MSG="${HOT_MSG}🟡 ${friendly} is warm: ${input}°C (${tech})\n" ;;
      suspect)
        devdesc="${tech}"; [ -n "$model" ] && devdesc="$model${fw:+ (fw $fw)}, $tech"
        suspect_msg="${suspect_msg}  • ${friendly} — reads ${input}°C while another channel on this device reads only ${sibmin}°C.${RST}"$'\n'
        suspect_msg="${suspect_msg}      device: ${devdesc}"$'\n'
        if [ -n "$defect" ]; then
          suspect_msg="${suspect_msg}      known defect: ${defect}"$'\n'
          [ -n "$solution" ] && suspect_msg="${suspect_msg}      solution:     ${solution}"$'\n'
          SUSPECT_NOTE="${SUSPECT_NOTE}⚠ ${friendly} (${model:-$tech}): ${defect}\n   → ${solution}\n"
        else
          suspect_msg="${suspect_msg}      likely a faulty/buggy sensor — verify before trusting; not treated as a real alarm."$'\n'
          SUSPECT_NOTE="${SUSPECT_NOTE}⚠ ${friendly} (${devdesc}): reading inconsistent with the device's other sensors; likely a faulty sensor.\n"
        fi
        ;;
    esac
    printf "  %-34s %s%6s°C  [%s]%s\n" "$label" "$color" "$input" "$tag" "$RST"
    POPUP_MSG="${POPUP_MSG}${friendly} (${tech}): ${input}°C  [${tag}]\n"
  done <<<"$enriched"

  # Clocks and fans sit below the sensor rows. Neither matches the applet's
  # "<label>  <temp>°C  [STATUS]" row pattern, so the 1.6 applet ignores them.
  clock_line
  if [ "$SHOW_FANS" = 1 ]; then
    while IFS="$US" read -r fanlabel fanrpm; do
      [ -n "$fanlabel" ] || continue
      printf '  %-34s %6s RPM\n' "$fanlabel" "$fanrpm"
    done <<<"$(fan_readings)"
  fi

  echo "-----------------------------------------------------------"
  case $status in
    0) echo "${GRN}All sensors within normal range.${RST}" ;;
    1) echo "${YEL}Warning: one or more sensors are running warm.${RST}" ;;
    2) echo "${RED}Critical: one or more sensors at/above critical threshold.${RST}" ;;
  esac
  if [ -n "$suspect_msg" ]; then
    echo
    echo "${YEL}Suspected sensor / firmware issues (not real temperatures):${RST}"
    printf '%s' "$suspect_msg"
  fi
  [ "$PEAK_SHOW" = 1 ] && render_peaks
  return 0
}

# JSON. Built with jq from the enriched TSV — never by string concatenation,
# because model names and known-issue text contain quotes and unicode.
render_json() {
  local enriched=$1 status=$2 compact=${3:-0} ts cur ceil ceil_khz ceil_src
  ts="$(now_iso)"
  cur=""; ceil_khz=""; ceil_src=""
  if [ "$SHOW_CLOCKS" = 1 ]; then
    cur="$(cpu_freq_khz)"
    ceil="$(freq_ceiling)"
    ceil_khz=${ceil%%$'\t'*}
    [ "$ceil" != "$ceil_khz" ] && ceil_src="${ceil#*$'\t'}"
  fi
  printf '%s' "$enriched" | jq ${compact:+-c} -R -s \
    --argjson schema "$SCHEMA" \
    --arg version "$VERSION" \
    --arg ts "$ts" \
    --argjson status "$status" \
    --arg freq_khz "$cur" \
    --arg ceil_khz "$ceil_khz" \
    --arg ceil_src "$ceil_src" \
    --arg fans "$(fan_readings)" '
    def num: if . == "" then null else (tonumber? // null) end;
    def statusword: {"0":"ok","1":"warn","2":"critical"}[$status|tostring];
    {
      schema:    $schema,
      version:   $version,
      timestamp: $ts,
      status:    statusword,
      exit_code: $status,
      cpu_clock: (
        if $freq_khz == "" then null
        else {
          khz:         ($freq_khz|tonumber),
          ghz:         (($freq_khz|tonumber) / 1000000 * 100 | round / 100),
          ceiling_khz: ($ceil_khz | num),
          ceiling_source: (if $ceil_src == "" then null else $ceil_src end),
          percent_of_ceiling: (
            if $ceil_khz == "" then null
            else (($freq_khz|tonumber) * 100 / ($ceil_khz|tonumber) | round)
            end)
        } end),
      fans: [ $fans | split("\n")[] | select(length > 0) | split("\u001f")
              | {label: .[0], rpm: (.[1] | num)} ],
      sensors: [ split("\n")[] | select(length > 0) | split("\u001f") | {
        friendly:         .[0],
        technical:        .[1],
        chip:             .[2],
        category:         (.[3] | ascii_downcase),
        celsius:          (.[4] | num),
        warn:             (.[5] | num),
        crit:             (.[6] | num),
        threshold_source: .[7],
        status:           .[8],
        siblings_min:     (.[9] | num),
        model:            (if .[10] == "" then null else .[10] end),
        firmware:         (if .[11] == "" then null else .[11] end),
        defect:           (if .[12] == "" then null else .[12] end),
        solution:         (if .[13] == "" then null else .[13] end)
      } ]
    }'
}

# --get: one bare number on stdout, nothing else.
do_get() {
  local enriched=$1 target=$2 want_cat want_chip best="" friendly tech chip category input st
  want_cat="${target%%:*}"; want_chip=""
  [ "$target" != "$want_cat" ] && want_chip="${target#*:}"
  case "$want_cat" in
    cpu|gpu|drive|other) ;;
    *) usage_err "unknown category: $want_cat (expected cpu, gpu, drive or other)" ;;
  esac
  while IFS="$US" read -r friendly tech chip category input _ _ _ st _; do
    [ -n "$chip" ] || continue
    [ "$(printf '%s' "$category" | tr '[:upper:]' '[:lower:]')" = "$want_cat" ] || continue
    if [ -n "$want_chip" ]; then
      [ "$chip" = "$want_chip" ] || continue
    fi
    # Hottest wins: that is the reading a build script would gate on.
    if [ -z "$best" ] || fgt "$input" "$best"; then best=$input; fi
  done <<<"$enriched"
  if [ -z "$best" ]; then
    if [ -n "$want_chip" ]; then
      echo "$PROG: no sensor in category '$want_cat' with chip '$want_chip'" >&2
    else
      echo "$PROG: no sensor found in category '$want_cat' on this machine" >&2
    fi
    exit 4
  fi
  printf '%s\n' "$best"
}

# ---------------------------------------------------------------------------
# Desktop notifications.
# ---------------------------------------------------------------------------
notify() {
  local status=$1 urgency
  command -v notify-send >/dev/null 2>&1 || return 0
  if [ "$POPUP" = 1 ]; then
    urgency=low; [ "$status" -ge 1 ] && urgency=normal; [ "$status" -ge 2 ] && urgency=critical
    notify-send -t 15000 -u "$urgency" -i temperature "Machine temperatures" "$(printf "%b" "$POPUP_MSG")"
  elif [ "$NOTIFY" = 1 ] && [ "$status" -gt 0 ]; then
    urgency=normal; [ "$status" -ge 2 ] && urgency=critical
    notify-send -t 15000 -u "$urgency" -i temperature "Machine running hot" "$(printf "%b" "$HOT_MSG")"
  fi
  if [ "$NOTIFY" = 1 ] || [ "$POPUP" = 1 ] || [ "$NOTIFY_SUSPECT" = 1 ]; then
    if [ -n "$SUSPECT_NOTE" ]; then
      notify-send -t 15000 -u normal -i dialog-warning "Sensor reading looks faulty" "$(printf "%b" "$SUSPECT_NOTE")"
    fi
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Watch mode.
#
# Compact, greppable, tee-able:  2026-08-16T14:54:28 cpu=50 gpu=42 drive=64.9 OK
# Duplicate categories get a numeric suffix (drive=, drive2=).
# ---------------------------------------------------------------------------
declare -A WATCH_LAST_STATUS=()

watch_line() {
  local enriched=$1 status=$2 ts=$3
  local friendly tech chip category input st line="" key freq
  declare -A seen=()
  line="$ts"
  while IFS="$US" read -r friendly tech chip category input _ _ _ st _; do
    [ -n "$chip" ] || continue
    key="$(printf '%s' "$category" | tr '[:upper:]' '[:lower:]')"
    seen[$key]=$(( ${seen[$key]:-0} + 1 ))
    [ "${seen[$key]}" -gt 1 ] && key="$key${seen[$key]}"
    line="$line $key=$input"
    [ "$st" = suspect ] && line="$line!suspect"
  done <<<"$enriched"
  if [ "$SHOW_CLOCKS" = 1 ]; then
    freq="$(cpu_freq_khz)"
    [ -n "$freq" ] && line="$line cpu_mhz=$(( freq / 1000 ))"
  fi
  case "$status" in
    2) line="$line CRITICAL" ;;
    1) line="$line WARN" ;;
    *) line="$line OK" ;;
  esac
  printf '%s\n' "$line"
}

# Notify at most once per sensor per state *change*, so a 5-second interval does
# not turn into a notification storm.
watch_notify() {
  local enriched=$1 status=$2 chip st changed=0
  { [ "$NOTIFY" = 1 ] || [ "$POPUP" = 1 ] || [ "$NOTIFY_SUSPECT" = 1 ]; } || return 0
  while IFS="$US" read -r _ _ chip _ _ _ _ _ st _; do
    [ -n "$chip" ] || continue
    if [ "${WATCH_LAST_STATUS[$chip]:-}" != "$st" ]; then
      changed=1
      WATCH_LAST_STATUS[$chip]=$st
    fi
  done <<<"$enriched"
  [ "$changed" = 1 ] || return 0
  notify "$status"
}

watch_summary() {
  local k
  peaks_save
  [ "$PEAK_TRACK" = 1 ] || return 0
  printf '\n' >&2
  printf 'Peaks for this run:\n' >&2
  for k in "${!PK_VAL[@]}"; do
    case "$k" in
      temp.*)    printf '  peak %s=%s @ %s\n' "${k#temp.}" "${PK_VAL[$k]}" "${PK_TS[$k]:-?}" >&2 ;;
      suspect.*) printf '  peak %s=%s @ %s (suspect — excluded)\n' "${k#suspect.}" "${PK_VAL[$k]}" "${PK_TS[$k]:-?}" >&2 ;;
      freq.cpu)  printf '  peak cpu clock=%s GHz @ %s\n' "$(khz_to_ghz "${PK_VAL[$k]}")" "${PK_TS[$k]:-?}" >&2 ;;
    esac
  done
  return 0
}

WATCH_RUNNING=1
# Invoked indirectly via `trap watch_stop INT TERM` in run_watch.
# shellcheck disable=SC2317
watch_stop() { WATCH_RUNNING=0; }

run_watch() {
  local enriched status ts
  trap watch_stop INT TERM
  peaks_load
  while [ "$WATCH_RUNNING" = 1 ]; do
    read_sensors
    records="$(build_records)"
    if [ -z "${records//[$'\n\t '$US]/}" ]; then
      echo "$PROG: no trustworthy temperature sensors found." >&2
      exit 4
    fi
    enriched="$(enrich_records)"
    status="$(overall_status "$enriched")"
    ts="$(now_iso)"
    record_peaks "$enriched" "$ts"
    if [ "$JSON_OUT" = 1 ]; then
      render_json "$enriched" "$status" 1
    else
      # Renderers populate the notification bodies; watch_notify decides whether
      # anything is actually sent.
      HOT_MSG=""; POPUP_MSG=""; SUSPECT_NOTE=""
      watch_line "$enriched" "$status" "$ts"
    fi
    # Unbuffered by construction: printf writes a whole line per sample, and we
    # sleep between them, so `caldun --watch | grep` is never stuck in a buffer.
    watch_notify "$enriched" "$status"
    [ "$WATCH_RUNNING" = 1 ] || break
    sleep "$WATCH_INTERVAL" || break
  done
  watch_summary
  # Watch mode's exit code says the run ended cleanly, not how hot the machine
  # was on the last sample.
  exit 0
}

# ---------------------------------------------------------------------------
# Dispatch.
# ---------------------------------------------------------------------------
if [ "$WATCH" = 1 ]; then
  run_watch                                   # never returns
fi

read_sensors
records="$(build_records)"

# No trustworthy sensors -> warn and exit 4.
if [ -z "${records//[$'\n\t '$US]/}" ]; then
  if [ -n "$GET_TARGET" ]; then
    echo "$PROG: no trustworthy temperature sensors found on this machine." >&2
    exit 4
  fi
  echo "${YEL}$PROG: no trustworthy temperature sensors found on this machine.${RST}" >&2
  echo "$PROG: run 'sudo sensors-detect' (answer YES to defaults), then retry." >&2
  echo "$PROG: or list sensors manually with 'sensors -j' and add them via EXTRA_SENSORS in $CONF." >&2
  exit 4
fi

if [ "$CHECK_ONLY" = 1 ]; then
  render_check
  exit 0
fi

enriched="$(enrich_records)"
status="$(overall_status "$enriched")"

if [ -n "$GET_TARGET" ]; then
  do_get "$enriched" "$GET_TARGET"
  exit 0
fi

peaks_load
record_peaks "$enriched" "$(now_iso)"
peaks_save

if [ "$JSON_OUT" = 1 ]; then
  render_json "$enriched" "$status"
  exit "$status"
fi

render_text "$enriched" "$status"
notify "$status"
exit "$status"
