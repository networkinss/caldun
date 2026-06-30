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
# Exit codes:
#   0  all OK            2  one or more sensors at/above CRITICAL
#   1  one or more WARN  3  `sensors` not installed (install lm-sensors)
#                        4  no trustworthy sensors found (run: sudo sensors-detect)

set -euo pipefail
set -f          # no pathname expansion: EXTRA_SENSORS/IGNORE_SENSORS hold case
                # globs (e.g. "*"), matched via `case`, never against the cwd.

PROG=${0##*/}

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

CONF="${CALDUN_CONF:-/etc/caldun.conf}"
# shellcheck source=/dev/null
[ -r "$CONF" ] && . "$CONF"

# ---------------------------------------------------------------------------
# Arguments.
# ---------------------------------------------------------------------------
NOTIFY=$NOTIFY_DEFAULT
POPUP=0
CHECK_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --notify) NOTIFY=1 ;;
    --popup)  POPUP=1 ;;
    --check)  CHECK_ONLY=1 ;;
    -h|--help)
      cat <<EOF
Usage: $PROG [--notify] [--popup] [--check] [-h|--help]
  --notify  send a desktop notification on WARN or CRITICAL only
            (used by the systemd timer; silent when all sensors are OK)
  --popup   always send a desktop notification with the full reading
            (for on-demand use: keyboard shortcut, panel launcher, etc.)
  --check   self-test: list discovered sensors and effective thresholds,
            then exit (exit 0 if sensors found, exit 4 if none)
  -h|--help show this help and exit

Config:     $CONF
Exit codes: 0 OK  1 WARN  2 CRITICAL  3 sensors/jq not installed  4 no usable sensors
EOF
      exit 0 ;;
    *) echo "$PROG: unknown argument: $arg" >&2; exit 64 ;;
  esac
done

# Colors (only when stdout is a terminal).
if [ -t 1 ]; then RED=$'\033[31m'; YEL=$'\033[33m'; GRN=$'\033[32m'; DIM=$'\033[2m'; RST=$'\033[0m'
else RED=; YEL=; GRN=; DIM=; RST=; fi

command -v sensors >/dev/null 2>&1 || { echo "$PROG: 'sensors' not found — install lm-sensors" >&2; exit 3; }
command -v jq      >/dev/null 2>&1 || { echo "$PROG: 'jq' not found — install jq" >&2; exit 3; }

SENSORS_JSON="$(sensors -j 2>/dev/null || true)"
if [ -z "$SENSORS_JSON" ] || ! printf '%s' "$SENSORS_JSON" | jq -e . >/dev/null 2>&1; then
  echo "$PROG: 'sensors -j' produced no usable output." >&2
  echo "$PROG: run 'sudo sensors-detect' to configure sensors, then retry." >&2
  exit 4
fi

# ---------------------------------------------------------------------------
# Numeric helpers (temperatures are decimals; bash can't compare floats).
# ---------------------------------------------------------------------------
fge()  { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0 >= b+0)}'; }                # a >= b ?
fsub() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.1f", a-b}'; }               # a - b
fmin() {                                                                       # min, ignoring blanks
  awk -v a="$1" -v b="$2" 'BEGIN{
    if (a=="") {print b} else if (b=="") {print a}
    else {print (a+0 < b+0) ? a : b}
  }'
}
fmax_list() {                                                                  # largest of the numeric args
  printf '%s\n' "$@" | awk 'NF{ if (!c || $1+0 > m+0) { m=$1; c=1 } } END{ if (c) print m }'
}

# ---------------------------------------------------------------------------
# Device identity + known-issues database (for faulty-sensor diagnostics).
# ---------------------------------------------------------------------------
# Resolve a sensors chip name to a real device "model<TAB>firmware", when we can.
# Currently knows how to map NVMe chips (nvme-pci-<bus><devfn>) to their sysfs
# entry via the PCI address; other chips return nothing (model unknown).
device_identity() {
  local chip="$1" driver="${chip%%-*}" want pcipart dev addr rest bus slot func model fw oldf found
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

# All (label, input, max, crit) temperature features of one chip, as TSV.
features_of() {
  printf '%s' "$SENSORS_JSON" | jq -r --arg c "$1" '
    .[$c] | to_entries[] | select(.key != "Adapter") | . as $f
    | ( $f.value | to_entries | map(select(.key | endswith("_input"))) | .[0].key ) as $ik
    | select($ik != null)
    | ( $ik | sub("_input$"; "") ) as $p
    | [ $f.key,
        ( $f.value[$ik]            | tostring ),
        ( ($f.value[$p+"_max"]) // "" | tostring ),
        ( ($f.value[$p+"_crit"]) // "" | tostring ) ] | @tsv'
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
    line=$(printf '%s\n' "$feats" | awk -F'\t' -v p="$p" 'index(tolower($1),tolower(p)){print; exit}')
    [ -n "$line" ] && { printf '%s\n' "$line"; return; }
  done
  printf '%s\n' "$feats" | head -n1
}

friendly_name() {
  case "$1" in CPU) echo "Processor";; GPU) echo "Graphics chip";;
    DRIVE) echo "Drive";; *) echo "Sensor";; esac
}

# ---------------------------------------------------------------------------
# Build the sensor list. Each record (tab-separated):
#   friendly  technical  input  eff_warn  eff_crit  source  chip  siblings_min
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
    IFS=$'\t' read -r label input hw_max hw_crit <<<"$primary"
    [ -n "$input" ] || continue

    # coolest channel on this chip other than the chosen primary
    sib_min="$(printf '%s\n' "$feats" | awk -F'\t' -v pl="$label" '$1!=pl{print $2}' \
                 | awk 'NF{ if (!c || $1+0 < m+0) { m=$1; c=1 } } END{ if (c) print m }')"

    # category default thresholds
    case "$category" in
      CPU)   def_warn=$CPU_WARN;   def_crit=$CPU_CRIT ;;
      GPU)   def_warn=$GPU_WARN;   def_crit=$GPU_CRIT ;;
      DRIVE) def_warn=$DRIVE_WARN; def_crit=$DRIVE_CRIT ;;
      *)     def_warn=$DEFAULT_WARN; def_crit=$DEFAULT_CRIT ;;
    esac

    # hybrid: hardware basis (prefer max, else crit), combined with default via min()
    hw_basis=""; [ -n "$hw_max" ] && hw_basis=$hw_max || { [ -n "$hw_crit" ] && hw_basis=$hw_crit; }
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

    records+="$(friendly_name "$category")"$'\t'"${chip%%-*} $label"$'\t'"$input"$'\t'"$eff_warn"$'\t'"$eff_crit"$'\t'"$source"$'\t'"$chip"$'\t'"$sib_min"$'\n'
  done <<<"$(printf '%s' "$SENSORS_JSON" | jq -r 'keys[]')"
  printf '%s' "$records"
}

records="$(build_records)"

# ---------------------------------------------------------------------------
# No trustworthy sensors -> warn and exit 4.
# ---------------------------------------------------------------------------
if [ -z "${records//[$'\n\t ']/}" ]; then
  echo "${YEL}$PROG: no trustworthy temperature sensors found on this machine.${RST}" >&2
  echo "$PROG: run 'sudo sensors-detect' (answer YES to defaults), then retry." >&2
  echo "$PROG: or list sensors manually with 'sensors -j' and add them via EXTRA_SENSORS in $CONF." >&2
  exit 4
fi

# ---------------------------------------------------------------------------
# --check: show what we found and what we'd alert on, then exit.
# ---------------------------------------------------------------------------
if [ "$CHECK_ONLY" = 1 ]; then
  echo "Sensor self-check ($PROG) — config: $CONF"
  echo "-----------------------------------------------------------------------"
  printf "  %-22s %-20s %8s %8s   %s\n" "ROLE" "SENSOR" "WARN" "CRIT" "SOURCE"
  while IFS=$'\t' read -r friendly tech input warn crit src chip sibmin; do
    [ -n "$friendly" ] || continue
    printf "  %-22s %-20s %8s %8s   %s\n" "$friendly" "$tech" \
      "${warn:-—}" "${crit:-—}" "$src"
  done <<<"$records"
  echo "-----------------------------------------------------------------------"
  echo "${GRN}OK:${RST} $(printf '%s' "$records" | grep -c $'\t') trustworthy sensor(s) will be monitored."
  exit 0
fi

# ---------------------------------------------------------------------------
# Normal report.
# ---------------------------------------------------------------------------
status=0
HOT_MSG=""
POPUP_MSG=""            # plain-text full reading for --popup notification
SUSPECT_MSG=""          # human-readable faulty-sensor section (printed below)
SUSPECT_NOTE=""         # short notification body for suspected sensor faults
echo "Machine temperatures ($(date '+%Y-%m-%d %H:%M:%S'))"
echo "-----------------------------------------------------------"
while IFS=$'\t' read -r friendly tech input warn crit src chip sibmin; do
  [ -n "$friendly" ] || continue
  label="$friendly ($tech)"
  color=$GRN; tag="OK"

  # Would this reading raise a thermal alarm at all?
  alarming=0
  if [ -n "$crit" ] && fge "$input" "$crit"; then alarming=2
  elif [ -n "$warn" ] && fge "$input" "$warn"; then alarming=1; fi

  # Faulty-sensor test: in a real overheat every channel on a chip is hot, so even
  # the COOLEST one is at least warm. If an alarming channel sits more than
  # ANOMALY_MARGIN above a sibling that is still below WARN, a sane channel on the
  # same die disagrees with it — treat the reading as a suspect sensor fault, not
  # real heat. (Comparing against the coolest sibling, not the hottest, is what
  # catches firmware bugs that corrupt several channels at once.)
  suspect=0
  if [ "$ANOMALY_DETECT" = 1 ] && [ "$alarming" -gt 0 ] && [ -n "$sibmin" ] \
     && { [ -z "$warn" ] || ! fge "$sibmin" "$warn"; } \
     && fge "$(fsub "$input" "$sibmin")" "$ANOMALY_MARGIN"; then
    suspect=1
  fi

  if [ "$suspect" = 1 ]; then
    color=$YEL; tag="SUSPECT"            # reported, but does NOT escalate $status
    ident="$(device_identity "$chip")"
    model="${ident%%$'\t'*}"; fw=""
    [ "$ident" != "$model" ] && fw="${ident#*$'\t'}"
    issue="$(lookup_known_issue "$model" "$fw")"
    defect="${issue%%$'\t'*}"; solution=""
    [ "$issue" != "$defect" ] && solution="${issue#*$'\t'}"
    devdesc="${tech}"; [ -n "$model" ] && devdesc="$model${fw:+ (fw $fw)}, $tech"
    SUSPECT_MSG="${SUSPECT_MSG}  • ${friendly} — reads ${input}°C while another channel on this device reads only ${sibmin}°C.${RST}"$'\n'
    SUSPECT_MSG="${SUSPECT_MSG}      device: ${devdesc}"$'\n'
    if [ -n "$defect" ]; then
      SUSPECT_MSG="${SUSPECT_MSG}      known defect: ${defect}"$'\n'
      [ -n "$solution" ] && SUSPECT_MSG="${SUSPECT_MSG}      solution:     ${solution}"$'\n'
      SUSPECT_NOTE="${SUSPECT_NOTE}⚠ ${friendly} (${model:-$tech}): ${defect}\n   → ${solution}\n"
    else
      SUSPECT_MSG="${SUSPECT_MSG}      likely a faulty/buggy sensor — verify before trusting; not treated as a real alarm."$'\n'
      SUSPECT_NOTE="${SUSPECT_NOTE}⚠ ${friendly} (${devdesc}): reading inconsistent with the device's other sensors; likely a faulty sensor.\n"
    fi
  elif [ "$alarming" = 2 ]; then
    color=$RED; tag="CRITICAL"; [ "$status" -lt 2 ] && status=2
    HOT_MSG="${HOT_MSG}🔴 ${friendly} is very hot: ${input}°C (${tech})\n"
  elif [ "$alarming" = 1 ]; then
    color=$YEL; tag="WARN"; [ "$status" -lt 1 ] && status=1
    HOT_MSG="${HOT_MSG}🟡 ${friendly} is warm: ${input}°C (${tech})\n"
  elif [ -z "$crit" ]; then
    tag="—"; color=$DIM        # report-only: no threshold available
  fi
  printf "  %-34s %s%6s°C  [%s]%s\n" "$label" "$color" "$input" "$tag" "$RST"
  POPUP_MSG="${POPUP_MSG}${friendly} (${tech}): ${input}°C  [${tag}]\n"
done <<<"$records"
echo "-----------------------------------------------------------"

case $status in
  0) echo "${GRN}All sensors within normal range.${RST}" ;;
  1) echo "${YEL}Warning: one or more sensors are running warm.${RST}" ;;
  2) echo "${RED}Critical: one or more sensors at/above critical threshold.${RST}" ;;
esac

# Separate faulty-sensor section (kept distinct from thermal alarms above).
if [ -n "$SUSPECT_MSG" ]; then
  echo
  echo "${YEL}Suspected sensor / firmware issues (not real temperatures):${RST}"
  printf '%s' "$SUSPECT_MSG"
fi

# Desktop notifications (best-effort; work because this runs as a user service).
if command -v notify-send >/dev/null 2>&1; then
  if [ "$POPUP" = 1 ]; then
    urgency=low; [ "$status" -ge 1 ] && urgency=normal; [ "$status" -ge 2 ] && urgency=critical
    notify-send -t 15000 -u "$urgency" -i temperature "Machine temperatures" "$(printf "%b" "$POPUP_MSG")"
  elif [ "$NOTIFY" = 1 ] && [ "$status" -gt 0 ]; then
    urgency=normal; [ "$status" -ge 2 ] && urgency=critical
    notify-send -t 15000 -u "$urgency" -i temperature "Machine running hot" "$(printf "%b" "$HOT_MSG")"
  fi
  if [ "$NOTIFY" = 1 ] || [ "$POPUP" = 1 ]; then
    if [ -n "$SUSPECT_NOTE" ]; then
      notify-send -t 15000 -u normal -i dialog-warning "Sensor reading looks faulty" "$(printf "%b" "$SUSPECT_NOTE")"
    fi
  fi
fi

exit $status
