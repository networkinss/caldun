# TEST.md — caldun test plan

Manual + scripted test plan for the two components (CLI `caldun` and the
MATE panel applet) plus the systemd timer integration. Re-run after any change.

Legend: `[ ]` to do · `[x]` verified · "you" = needs human eyes on the panel.

Last run: 2026-06-30 (v1.6) — ALL functional tests pass (applet 1–7, CLI 8–14,
integration 15–17, faulty-sensor detection 19–22). Optional remaining: 7a/7b
error states, 18 live stress test.

---

## Pre-flight

```bash
which caldun                       # /usr/bin/caldun
pgrep -af caldun-applet            # applet process running
systemctl --user is-active caldun.timer
```

Expected: binary found, one applet python3 process, timer `active`.

---

## A. Panel applet (MATE) — needs your eyes

- [x] **1. Live display** — bottom panel shows `T: CPU:42° SSD:45°`
      (this machine: CPU + SSD only; no GPU sensor exposed — see note below).
- [x] **2. Color coding** — text is green when OK (amber/red only when hot, test 9–11).
- [x] **3. Left-click refresh** — left-click the applet, then hover → the tooltip's
      timestamp line (`Machine temperatures (YYYY-MM-DD HH:MM:SS)`) advances to now.
      NOTE: the panel digits round to whole degrees, so they usually do **not**
      visibly change on click when temps are stable — that is expected. The
      tooltip timestamp is the proof the refresh ran.
- [x] **4. Tooltip** — hover the applet → full multi-line `caldun` report.
- [x] **5. Right-click menu** — right-click → standard MATE menu (Remove/Move/Lock).
      This is intentionally the panel's menu, not ours.
- [x] **6. Auto-refresh** — wait 2+ min → tooltip timestamp advances on its own (120 s timer).
- [x] **7. Survives logout/login** — applet reappears at saved position (v1.4 fix).

Error-state display (optional, harder to stage):

- [ ] **7a. Binary missing** → applet shows red `T: N/A`, tooltip names install cmd.
      Run: `sudo ./tests/test-applet-7a-binary-missing.sh` (auto-reverts).
- [ ] **7b. No sensor data** → applet shows grey `T: ?`, tooltip shows raw output.
      Run: `sudo ./tests/test-applet-7b-no-sensors.sh` (auto-reverts).

---

## B. CLI (`caldun`)

- [x] **8. One-shot report** — `caldun` → sensor table, "All sensors within
      normal range.", exit `0`.
- [x] **9. Self-check** — `caldun --check` → ROLE/SENSOR/WARN/CRIT/SOURCE
      table, "N trustworthy sensor(s)", exit `0`.
- [x] **13. Help** — `caldun --help` → usage text, exit `0`.
- [x] **14. Bad arg** — `caldun --bogus` → "unknown argument", exit `64`.

### Alert thresholds (forced via a temp config — non-destructive)

`CALDUN_CONF` points the script at an alternate config; no need to touch
`/etc/caldun.conf`.

```bash
cd "$(mktemp -d)"

# WARN: warn below current temp, crit above
printf 'CPU_WARN=30\nCPU_CRIT=95\nDRIVE_WARN=30\nDRIVE_CRIT=83\n' > warn.conf
CALDUN_CONF=$PWD/warn.conf caldun;            echo "exit=$?"   # expect [WARN], exit 1

# CRITICAL + desktop popup: crit below current temp
printf 'CPU_WARN=20\nCPU_CRIT=30\nDRIVE_WARN=20\nDRIVE_CRIT=30\n' > crit.conf
CALDUN_CONF=$PWD/crit.conf caldun --notify;   echo "exit=$?"   # expect [CRITICAL], exit 2 + popup
```

- [x] **10. WARN detection** — `[WARN]` rows, "running warm.", exit `1`.
- [x] **11. CRITICAL detection** — `[CRITICAL]` rows, "at/above critical.", exit `2`.
- [x] **12. `--notify` popup** — critical run pops a desktop notification
      "Machine running hot" (urgency=critical, red). Confirmed via forced-low
      thresholds while real temps were normal — fired correctly.

### Exit-code matrix (reference)

| Code | Meaning                          | How to trigger                       |
|------|----------------------------------|--------------------------------------|
| 0    | all OK                           | normal run when cool                 |
| 1    | one or more WARN                 | `warn.conf` above                    |
| 2    | one or more CRITICAL             | `crit.conf` above                    |
| 3    | `sensors`/`jq` not installed     | `PATH= caldun` (cmd not found)  |
| 4    | no trustworthy sensors found     | config ignoring all chips            |
| 64   | unknown argument                 | `caldun --bogus`                |

---

## C. Integration

- [x] **15. systemd user timer** — `systemctl --user status caldun.timer`
      → `active (waiting)`, triggers every 2 min.
      Force a run now: `systemctl --user start caldun.service` then
      `journalctl --user -u caldun.service -n 20`.
- [x] **16. Sensor trust model** — `caldun --check` lists only k10temp (CPU)
      and nvme (DRIVE); the `nct6798` Super-I/O chip is excluded (no false CRIT).
- [x] **17. Live config edit** — change a threshold in `/etc/caldun.conf`,
      rerun `caldun` → new threshold applies with no rebuild/reload.
- [ ] **18. Real high-temp alert (optional)** — drive temps up and watch the
      panel turn amber/red and a real notification fire.
      Run: `sudo ./tests/test-applet-18-high-temp.sh [seconds]` (lowers CPU_WARN to 50,
      loads all cores, auto-reverts). Left-click the applet during the load.

---

## D. Faulty-sensor detection (known-issues DB)

A buggy sensor reports bogus-high on one channel while a sane channel on the same
chip stays cool; a real overheat heats *every* channel. `caldun` flags the former
`[SUSPECT]` (separate section, **no** thermal alarm, exit unchanged) and the
latter `[CRITICAL]`. Real glitches are intermittent, so stage them with a fake
`sensors` (replace `nvme-pci-0300` with your drive's chip from
`sensors -j | jq keys`):

```bash
cd "$(mktemp -d)"; mkdir bin
sensors -j > base.json
# bogus: Composite AND Sensor 1 spike to 83.85, Sensor 2 stays ~65 (the 980 bug)
jq '.["nvme-pci-0300"].Composite.temp1_input=83.85
  | .["nvme-pci-0300"]["Sensor 1"].temp2_input=83.85
  | .["nvme-pci-0300"]["Sensor 2"].temp3_input=65.85' base.json > glitch.json
# real overheat: all three channels hot
jq '.["nvme-pci-0300"].Composite.temp1_input=84
  | .["nvme-pci-0300"]["Sensor 1"].temp2_input=83
  | .["nvme-pci-0300"]["Sensor 2"].temp3_input=82' base.json > hot.json
mkstub(){ printf '#!/usr/bin/env bash\ncat %s/%s\n' "$PWD" "$1" > bin/sensors; chmod +x bin/sensors; }
```

- [x] **19. SUSPECT detection** — `mkstub glitch.json; PATH=$PWD/bin:$PATH caldun`
      → drive row `[SUSPECT]`, a "Suspected sensor / firmware issues" section,
      "All sensors within normal range.", exit `0` (no false CRITICAL).
- [x] **20. Known-issue lookup** — same run shows the device
      (`Samsung SSD 980 1TB (fw 2B4QFXO7)`) plus the `known defect:` / `solution:`
      text from `/etc/caldun-known-issues.conf`. With no matching DB entry it
      falls back to a generic "likely a faulty sensor" note.
- [x] **21. Real overheat not masked** — `mkstub hot.json; PATH=$PWD/bin:$PATH caldun`
      → drive row `[CRITICAL]`, "at/above critical threshold.", exit `2`.
- [x] **22. Disable switch** — `ANOMALY_DETECT` is a config setting, not an env
      var (the script seeds defaults then sources the conf), so disable it there:
      `printf 'ANOMALY_DETECT=0\n' > off.conf; mkstub glitch.json;
      PATH=$PWD/bin:$PATH CALDUN_CONF=$PWD/off.conf caldun` → the bogus reading is
      taken at face value: `[CRITICAL]`, exit `2` (detection off).

A `[SUSPECT]` reading never changes the exit code — it is a sensor-fault notice,
not a thermal alarm. See README "Faulty sensors and the known-issues database".

## Notes / known observations

- **No GPU sensor** is currently reported — only CPU (k10temp/Tctl) and SSD
  (nvme/Composite). The script and applet support GPU (`amdgpu`/`edge`), but it
  is absent from `sensors -j` on this run (amdgpu driver not loaded, or the APU
  doesn't expose `edge`). Not a failure; revisit if a GPU temp is expected.
- Applet refresh interval is 120 s (`REFRESH_SECONDS` in `caldun-applet`);
  it runs `/usr/bin/caldun` and parses rows matching
  `label  <2+ spaces>  temp°C  [STATUS]`.
- Thresholds are hybrid (hardware limit vs. category default, more conservative
  wins); see CLAUDE.md "sensor trust model" and README "NVMe thermal incident".
