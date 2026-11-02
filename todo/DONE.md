# Caldun — completed work

One short entry per finished topic. Details live in the code, `CLAUDE.md`,
`debian/changelog` and git history. Open checks that need real hardware or a
person are in `MANUAL-CHECKS.md`; new work is planned in `TODO.md` here.

## 1.7

- **Script restructure:** hand-rolled long-option parser (exit 64), the
  `read_sensors → build_records → enrich_records → renderer` pipeline with
  `status_of()` as the single source of truth, and the `CALDUN_SENSORS_JSON` fixture hook.
- **Fixed:** `features_of()` matched voltages/power as temperature siblings, so a
  97 °C GPU read as "normal"; now `temp[0-9]+_input` only. Record separator
  changed from TAB to US (`0x1f`) so empty fields no longer shift columns.
- **`--json`:** schema 1, built with `jq`, stdout only, exit code unchanged.
- **`--get CATEGORY[:chip]`:** one bare number; hottest wins, a chip name selects exactly.
- **`--watch [N]`:** one line per sample (JSONL with `--json`), exit 0 on
  SIGINT, notifications once per state change.
- **Peak tracking:** since-boot high-water marks in `$XDG_STATE_HOME/caldun/peaks`,
  reset on a new boot id; suspect readings kept under their own key.
- **CPU clock and fans:** mean clock across cores, a percentage only against a
  trusted ceiling (not `cpuinfo_max_freq` under `acpi-cpufreq`); fan RPM from trusted chips.
- **Applet:** reads `--json`, falls back to the text report for a 1.6 binary,
  suspect sensors get their own colour.
- **CI:** `.deb` build on Ubuntu 22.04/24.04, lint (shellcheck, py_compile,
  groff, lintian), release on `v*` tags.

## 1.7.1 / 1.7.2

- **Applet invisible after login:** removed the iid gate in `_applet_fill`
  (1.7.1), and deferred the first refresh with `GLib.idle_add` so the panel can
  size the applet (1.7.2).

## After 1.7.2 (CI only)

- **Smoke test:** the no-sensors check uses `no-trusted-chips.json` instead of
  the runner's hardware.
- **`tests/run.sh`:** hermetic fixture suite (33 tests: exit codes, suspect
  path, multi-drive `--get`, watch rate limit), run by the CI `smoke` job.
  Verified to fail on planted bugs.

## Explicitly not doing

- No `nct6798` mainboard/ambient line: its channels are bogus on AMD boards.
- No raising NVMe thresholds to hide phantom spikes; suspect detection handles them.
- No CPU percentage of `cpuinfo_max_freq`: it reads >100 % at idle here.
- No argument-parsing dependency (`getopt` is GNU-only, libraries unpackaged).
