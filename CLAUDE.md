# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A temperature monitoring tool for Ubuntu and Linux Mint with the MATE desktop,
consisting of three components:

1. **`caldun.sh`** — Bash utility that reads temperature sensors via
   `lm-sensors`, flags warm/critical readings, and optionally fires a desktop
   notification. Also deployed as a systemd user timer (every 2 minutes).
2. **`caldun-applet`** — Python 3 MATE panel applet that shows live
   CPU/GPU/drive temperatures in the panel bar, colour-coded by status.
3. **`.deb` package** — built via `build-deb.sh`, installs both components.

## Running the CLI

```bash
./caldun.sh            # one-shot text report
./caldun.sh --notify   # same, plus notify-send popup if WARN/CRITICAL
./caldun.sh --check    # self-test: list discovered sensors and thresholds
```

Exit codes feed the systemd service: `0` OK, `1` WARN, `2` CRITICAL,
`3` `sensors`/`jq` not installed, `4` no trustworthy sensors found.

## Building and installing the .deb

```bash
./build-deb.sh                              # produces caldun_<ver>_all.deb
sudo apt install ./caldun_<ver>_all.deb   # first install (pulls Recommends)
sudo dpkg -i ./caldun_<ver>_all.deb       # reinstall same version
```

After install, add the panel applet: right-click the MATE panel →
**Add to Panel** → **Caldun**.

To deploy a script-only change without bumping the version:
```bash
sudo cp applet/caldun-applet /usr/lib/mate-panel/applets/caldun-applet
sudo cp caldun.sh /usr/bin/caldun
```

## MATE panel applet (`caldun-applet`)

### Files installed by the .deb

| Path | Purpose |
|------|---------|
| `/usr/lib/mate-panel/applets/caldun-applet` | Python 3 applet script |
| `/usr/share/mate-panel/applets/org.mate.panel.applet.Caldun.mate-panel-applet` | Panel registration (`Icon=caldun`) |
| `/usr/share/dbus-1/services/org.mate.panel.applet.CaldunAppletFactory.service` | D-Bus activation |
| `/usr/share/icons/hicolor/{16,22,24,32,48,256,512}x.../caldun.png` | Custom icon |

### Key implementation decisions

- **`factory_main` signature** is 5 arguments across all MATE versions
  (1.24/Ubuntu 20.04/Mint 20 through 1.28/Ubuntu 24.04/Mint 22):
  ```python
  MatePanelApplet.Applet.factory_main(
      'CaldunAppletFactory',
      True,                              # out_process — dummy bool, always True
      MatePanelApplet.Applet.__gtype__,
      _applet_fill,
      None,
  )
  ```
- **D-Bus service name must equal `org.mate.panel.applet.<FactoryId>`.** The
  panel derives the activation bus name from the factory `Id`
  (`CaldunAppletFactory`, set in both `factory_main()` and the
  `.mate-panel-applet` file), so the `.service` file's `Name=` — and its
  filename — must be `org.mate.panel.applet.CaldunAppletFactory`. A mismatch
  makes the panel silently skip the applet at startup (it requests a bus name
  D-Bus cannot activate); manually running the binary hides the bug because the
  factory self-registers the correct name. Every stock MATE applet follows this
  convention. (Fixed in 1.4; was `…CaldunFactory` before.)
- **`Gtk.Button` (no relief)** is used instead of `EventBox` — the MATE panel
  intercepts button events on `EventBox` containers before they reach the applet.
- **Left-click** triggers an immediate refresh. Right-click shows the panel's
  standard menu (Remove, Move, etc.) — intentionally left to the panel.
- Margins use `set_margin_start/end`; `set_padding` is deprecated since GTK 3.14.
- The applet parses `caldun` stdout (no ANSI codes outside a terminal).
  Sensor rows match: `label  <2+ spaces>  temp°C  [STATUS]`.

### Diagnosing applet problems

```bash
# Check Python dependencies:
python3 -c "import gi; gi.require_version('MatePanelApplet','4.0'); \
  from gi.repository import MatePanelApplet; print('OK')"

# Run applet directly (blocks silently = working; traceback = error):
/usr/lib/mate-panel/applets/caldun-applet

# Or use the bundled script which does both:
./diagnose-applet.sh
```

If the applet appears in "Add to Panel" but no process starts, log out and back
in — the D-Bus session daemon only rescans `/usr/share/dbus-1/services/` at login.

## Architecture / key domain knowledge (sensor trust model)

This is an **AMD** system. The central design decision is *which sensors to trust*:

- **Trusted** (dedicated PCI sensors): `k10temp`/`Tctl` (CPU), `amdgpu`/`edge`
  (iGPU), `nvme`/`Composite` (SSD). Only these are reported.
- **Deliberately excluded**: the `nct6798` Super-I/O chip. Its
  `CPUTIN`/`AUXTIN*`/`SYSTIN` channels are mislabeled on AMD boards and report
  bogus values (e.g. CPUTIN ~127°C at idle). Do **not** re-add a
  mainboard/ambient line from this chip — it produces permanent false CRITICAL
  alarms.

How the script works:

- `categorize()` maps a chip name to a trusted category (CPU/GPU/DRIVE) by
  driver prefix, or ignores it entirely (Super-I/O chips).
- `features_of()` extracts all temperature features from `sensors -j` JSON for
  one chip via `jq`.
- `pick_primary()` selects the representative feature per category
  (e.g. `Tctl` for CPU, `edge` for GPU, `Composite` for NVMe).
- `report` logic escalates `$status` and appends to `$HOT_MSG` for the popup.
- Thresholds (`CPU_WARN`/`CPU_CRIT`, etc.) live in `/etc/caldun.conf` —
  edit and save, no rebuild needed.

### Faulty-sensor detection (anomaly + known-issues DB)

A real overheat heats *every* channel on a chip, so even the coolest is warm; a
buggy sensor leaves a sane channel reading cool. `build_records()` records
`siblings_min` (the **coolest** *other* channel on the same chip). In the report,
an alarming channel that sits more than `ANOMALY_MARGIN` (default 15 °C) above a
sibling that is **still below WARN** is tagged `[SUSPECT]`: shown in a separate
"Suspected sensor / firmware issues" section, it **does not escalate `$status`**
(no false alarm; a genuinely hot part — where even the coolest channel is warm —
is never masked). **Compare against the coolest sibling, not the hottest:** a
firmware bug can corrupt several channels at once (the Samsung 980 spikes both
`Composite` and `Sensor 1` together; only `Sensor 2` stays accurate), so the
hottest sibling can be bogus too — the coolest is the trustworthy witness.

- `device_identity()` maps a `sensors` chip to a real `model<TAB>firmware`. NVMe
  only so far: it matches the chip's `nvme-pci-<bus><devfn>` suffix to a
  `/sys/class/nvme/nvmeN` via that device's PCI `address`. **Must toggle `set +f`**
  around the `/sys/class/nvme/nvme*` glob — the script runs under `set -f`.
- `lookup_known_issue()` reads `/etc/caldun-known-issues.conf` (override:
  `CALDUN_ISSUES`), a blank-line-separated DB of `device:`/`firmware:`/
  `defect:`/`solution:` records (`device` is a case-insensitive glob on the model;
  `firmware` optional). First match wins; its `defect`/`solution` are shown and
  pushed as a `notify-send` (normal urgency, separate from thermal popups).
- Disable with `ANOMALY_DETECT=0`. The DB ships as a conffile (installed to
  `/etc`, listed in `debian/rules` + `build-deb.sh`).

## Deployment (systemd user timer)

The `.deb` installs units to `/usr/lib/systemd/user/`. After install they are
enabled per-user automatically via `dh_installsystemduser`.

After editing **unit files**: `systemctl --user daemon-reload`.
After editing **the script only**: nothing needed.

## NVMe thermal context

A Samsung SSD 980 (`/dev/nvme0`) hard-froze the system at high temperature
(incident 2026-06-20). `NVME_WARN=75`/`NVME_CRIT=83` are set below the hardware
critical (85°C) deliberately, to alert with time to act. See the README's
"NVMe thermal incident" section before loosening NVMe thresholds.

**Phantom 84 °C spikes (separate from the real incident).** This drive is on
firmware `2B4QFXO7`, which has a documented bug: it intermittently reports a
bogus ~84 °C value (for 1 s up to ~40 s) on **both** `Composite` and `Sensor 1`
while `Sensor 2` stays ~65 °C and the drive is cool — exactly +22 °C, no
intermediate values, snapping instantly. Real heat can't jump 22 °C in 1 s, so
it's a reporting bug, not heat. Fixed in firmware `3B4QFXO7`+. The faulty-sensor
detection above catches it generically (Composite disagrees with its siblings)
and the known-issues DB attaches the firmware-update fix. This is *why* that
feature exists — don't "fix" the false alarm by raising NVMe thresholds.

## Other
Also cd to a relative path. If a path is outside of this repo, it is probably wrong.
Avoid absolute paths.
