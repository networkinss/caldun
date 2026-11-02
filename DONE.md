# Caldun — completed work

Moved here from `TODO.md` once done. Derived from the original feature
wishlist; phases 0–5, the applet follow-on and CI shipped as **1.7**
(`debian/changelog`); the fixture test suite (CI only) followed. All code work is
done — checks that need real hardware or a person are in `MANUAL-CHECKS.md`.
New work: add a `TODO.md` again, and move items here once done.

Rules that applied throughout, and still apply to new work:

- Machine-readable output goes to **stdout only**; diagnostics to stderr, so
  `caldun --json | jq` never breaks.
- Exit-code contract (`0 OK / 1 WARN / 2 CRITICAL / 3 missing dep / 4 no sensors`)
  is load-bearing for `caldun.user.service` and the applet. Usage errors use 64.
  Watch mode is the sole documented exception (exits 0 on interrupt).
- Every new flag updated `man/caldun.1`, README (both languages), `--help` and
  `caldun.conf`.

---

## Phase 0 — Restructure the script ✅

- [x] Real argument parser (`while`/`case`, `--opt value` and `--opt=value`,
      exit 64 on error). Hand-rolled; `getopts` (no long options), enhanced
      `getopt` (GNU-only, would split the macOS port), argbash (not in the
      Ubuntu archive) and docopt.sh/bash-argsparse (runtime deps) were all
      rejected — see the comment above the parser in `caldun.sh`.
- [x] `read_sensors()` split out so watch mode can re-sample.
- [x] Classification centralised in `status_of()`; every renderer (text, JSON,
      watch, get) goes through it, none re-implements thresholds.
- [x] Dispatch at the bottom of the script.
- [x] `CALDUN_SENSORS_JSON` fixture override (kept from the deferred testing
      work, because retrofitting it later would mean re-opening every phase).
- [x] **Fixed a shipped bug found while restructuring**: `features_of()` matched
      any `*_input` field, so amdgpu's `vddgfx` (~0.7 V) and `power1_input` were
      treated as temperature siblings. A 97 °C GPU was compared against a
      0.7 "°C" sibling, tagged `[SUSPECT]` and reported as "All sensors within
      normal range", exit 0. Now restricted to `temp[0-9]+_input`. Verified
      side-by-side against the 1.6 script with the same input.
- [x] **Fixed a latent trap in the record format**: the internal separator is
      now US (`0x1f`), not TAB. Tab is IFS *whitespace*, so `IFS=$'\t' read`
      collapses runs of tabs — one empty field silently shifted every later
      column left. It only stayed hidden in 1.6 because the sole empty field was
      last.

## Phase 1 — `--json` ✅

- [x] One object per sensor with `friendly`, `technical`, `chip`, `category`,
      `celsius`, `warn`, `crit`, `threshold_source`, `status`, `siblings_min`,
      and `model`/`firmware`/`defect`/`solution` for suspects. Wrapped in
      `{schema, timestamp, status, exit_code, cpu_clock, fans, sensors}`.
- [x] `schema: 1` from day one.
- [x] Built with `jq -n`/`-R -s`, never string concatenation — verified with a
      defect string containing quotes, a comma and non-ASCII.
- [x] No colour, no notifications; exit code unchanged.

## Phase 2 — `--get CATEGORY` ✅

- [x] Bare number, nothing else.
- [x] Multi-sensor collision resolved: hottest in the category wins;
      `--get drive:nvme-pci-0300` names a chip exactly. Documented.
- [x] Unknown category → stderr, exit 64, nothing on stdout.
- [x] Category present but no sensor → exit 4, nothing on stdout.
- [x] Built on the same enriched record set, not a second code path.

## Phase 3 — `--watch [N]` ✅

- [x] Default 30 s, `--watch 5` overrides, non-numeric/`<1` rejected with 64.
- [x] `2026-08-16T15:30:26 gpu=43 cpu=57.75 drive=65.85 cpu_mhz=4250 OK`,
      duplicate categories suffixed (`drive`, `drive2`), suspects marked
      `!suspect`.
- [x] One `printf` per sample then a sleep, so a downstream `grep` never waits
      on a buffer. Verified through a pipe.
- [x] `--watch --json` → JSONL.
- [x] Config read once at startup, not per sample.
- [x] `SIGINT`/`SIGTERM` → peak summary, exit 0. Documented as the one place the
      exit contract differs.
- [x] Notifications rate-limited to one per sensor per state change.

## Phase 4 — Peak tracking ✅

- [x] Watch mode tracks max per sensor and prints a summary on exit.
- [x] `--peak` reports since-boot high-water marks from
      `$XDG_STATE_HOME/caldun/peaks` (user state — the timer is a *user*
      service and must not need root).
- [x] Every run contributes, including the timer's. Boot id recorded; peaks
      reset when it changes.
- [x] Suspect readings tracked under a separate key, so a phantom 84 °C spike
      never becomes a sensor's peak.
- [x] Atomic write (temp file in the same dir + `mv`), no locking.
- [x] Keyed `<metric>.<subject>`, which is what let Phase 5 store the frequency
      ceiling in the same file.

## Phase 5 — Clock / throttle state ✅

Implemented **against the measurements, not the original spec** — see below.

- [x] Absolute clocks always; percentage only against a trusted ceiling.
- [x] `amd_pstate`/`intel_pstate` → `cpuinfo_max_freq` is the boost ceiling, use
      it. Otherwise → highest clock ever observed, from the peak file, and only
      after `MIN_FREQ_SAMPLES` (20) observations *and* evidence of boost.
- [x] Mean across cores, not maximum: caldun is itself load on the busiest core,
      so a max reads near boost on every sample. Measured: ~1.5 GHz idle vs
      ~2.1 GHz under all-core load on the 4800U — the max-based version read
      ~4.29 GHz in both cases.
- [x] `cpufreq` absent → line omitted silently.
- [x] Fan RPM from `fan[0-9]+_input`, only on chips that pass `categorize()`.
- [x] `SHOW_CLOCKS`, `SHOW_FANS`, `MIN_FREQ_SAMPLES`, `PEAK_TRACK` in
      `caldun.conf`, all commented out at their defaults.

**Why the original "% of cpuinfo_max_freq" was dropped** — measured on this
machine, and the reason the plan changed:

| path | value |
|------|-------|
| `scaling_driver` | `acpi-cpufreq` (not `amd_pstate`) |
| `cpuinfo_max_freq` | `1800000` — the *base* clock; the part boosts to 4.2 GHz |
| `scaling_available_frequencies` | `1800000 1700000 1400000` — P-states only |
| `scaling_cur_freq`, idle | `1672669`, `1815019`, `1891906` |

Current already exceeds "max" at idle, so the ratio reads >100 % doing nothing
and ~233 % under boost. No boost ceiling exists anywhere in cpufreq sysfs under
`acpi-cpufreq`; recovering it needs MSR/aperf-mperf reads as root.
`/sys/.../thermal_throttle/` is Intel-only and absent here.

## Applet — consumes `--json` ✅

- [x] `caldun --json` + `json.loads` instead of the row regex.
- [x] Regex path kept as a fallback, triggered by exit 64 (a 1.6 binary rejects
      `--json`) or an unrecognised `schema`. Both paths tested against the real
      1.6 script.
- [x] Suspect sensors get their own colour instead of looking like a warning;
      tooltip carries the defect and fix.

## CI ✅

- [x] `.github/workflows/build.yml`: `.deb` build on `ubuntu-22.04` and
      `ubuntu-24.04` (the Mint 21 / Mint 22 bases, and the MATE 1.26 vs 1.28
      split where `factory_main` compatibility matters), calling `build-deb.sh`
      unmodified; artifact upload; asserts the D-Bus service file is present and
      correctly named.
- [x] Lint job: `shellcheck` on all four shell scripts, `py_compile` on the
      applet, `groff -ww` on the man page. All currently clean, so blocking.
- [x] `lintian` on the built `.deb`, blocking — this surfaced a **pre-existing**
      error (`python3-script-but-no-python3-dep`, present in 1.6 too), fixed by
      adding `python3:any` to `Depends`.
- [x] Smoke job: now runs the fixture test suite (below). Its exit-4 check uses
      `no-trusted-chips.json`, not the runner's hardware, which may expose
      acpitz/coretemp.
- [x] `.github/workflows/release.yml`: tag `v*` builds and attaches the `.deb`,
      refusing to publish when the tag and `debian/changelog` disagree.
- [x] apt package caching.

## Fixture test suite ✅

- [x] `tests/run.sh`: hermetic harness over the fixtures (test config instead of
      `/etc/caldun.conf`, temp peaks file, logging `notify-send` stub), wired
      into the CI `smoke` job in place of its hand-rolled assertions. 33 tests.
- [x] Suspect path: phantom spike → `[SUSPECT]`, exit 0, one faulty-sensor
      notification, kept out of the drive's peak; `ANOMALY_DETECT=0` and
      `NOTIFY_SUSPECT=0` honoured; an all-channels-hot overheat is never masked.
- [x] Multi-drive `--get`: hottest wins (the hotter drive sorts second, so
      "first found" fails), `drive:<chip>` selects exactly, unknown chip → 4.
- [x] Watch mode: one line per sample, `drive2`, `!suspect`, JSONL, exit 0 on
      SIGINT while critical, and notifications once per state change.
- [x] Checked that the suite catches regressions: removing the rate limit,
      comparing against the hottest sibling and "first drive wins" each make it
      fail.

## Explicitly not doing

- Re-adding an `nct6798` mainboard/ambient line — permanent false CRITICALs
  (see CLAUDE.md).
- Raising the NVMe thresholds to silence phantom spikes — that is what the
  faulty-sensor detection is for.
- Reporting CPU frequency as a percentage of `cpuinfo_max_freq` — measured as
  wrong on this hardware; it reads >100 % at idle.
- Adding an argument-parsing dependency — see Phase 0.
