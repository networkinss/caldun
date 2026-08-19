**[English](#caldun) · [Deutsch](#caldun-deutsch)**

# Caldun

Free for noncommercial use. For commercial use, see [COMMERCIAL.md](COMMERCIAL.md).

Caldun reports a machine's **trustworthy** temperature sensors and flags anything
running warm or critical. It auto-discovers sensors, so the same package works
across different machines, and it can sit in your panel and pop a desktop alert
when the machine gets hot.

It is built for **Ubuntu** and **Linux Mint** with the **MATE** desktop, and
ships three components:

| Component | What it is |
|-----------|------------|
| **`caldun`** (CLI) | Bash utility that reads sensors via `lm-sensors`, flags warm/critical readings, and optionally fires a desktop notification. Also runs as a per-user systemd timer every 2 minutes. |
| **Caldun applet** | Python 3 MATE panel applet showing live CPU/GPU/drive temperatures in the panel bar, colour-coded by status. |
| **`.deb` package** | Installs both components, their config, icons, man page, and the systemd user timer. |

A minimal **macOS (Intel) proof of concept** lives in [`macos/`](macos/README.md).

## Why only "trustworthy" sensors?

Some chips lie. The reliable readings come from dedicated kernel drivers —
`k10temp`/`coretemp`/`zenpower` (CPU), `amdgpu`/`i915`/`nouveau` (GPU),
`nvme`/`drivetemp` (drives). The ISA **Super-I/O** chips (e.g. `nct6798`) have
`CPUTIN`/`AUXTIN*`/`SYSTIN` channels that are **mislabeled** on many boards —
especially AMD — and report bogus values (e.g. `CPUTIN: +127°C`). Caldun
selects sensors by a **driver-class allowlist** and ignores Super-I/O chips by
default, so it never raises false alarms from a lying chip. The allowlist is
configurable (see `EXTRA_SENSORS` / `IGNORE_SENSORS`).

## How thresholds are decided (hybrid)

For each sensor:

- If the hardware reports a limit (`temp*_max` / `temp*_crit` in `sensors -j`),
  that limit is used.
- Otherwise a per-category default (`CPU_*`, `GPU_*`, `DRIVE_*`) is used. CPUs
  and GPUs usually report no limit, so defaults matter there.
- When **both** exist, the **lower (more conservative)** value wins — a hardware
  limit can only make an alert fire *sooner*, never later than the default.

`WARN` is set `WARN_MARGIN` degrees (default 10) below the effective `CRITICAL`.
Run `caldun --check` to see exactly what will be monitored and whether each
threshold came from `hardware` or a `default`.

## Installation

```bash
sudo apt install ./caldun_<ver>_all.deb     # pulls in lm-sensors, jq
```

On first install you may need a one-time sensor scan so the kernel exposes the
chips:

```bash
sudo sensors-detect      # answer YES to the defaults, then reboot
```

The package enables a **per-user** systemd timer for all users; it starts on the
next login. (User scope is deliberate — it runs inside your desktop session, so
`notify-send` popups actually appear.)

To add the panel applet after install: right-click the MATE panel →
**Add to Panel** → **Caldun**. (If it doesn't appear in the list, log out and
back in — see the [applet section](#mate-panel-applet) below.)

## Usage

```bash
caldun                 # print a one-shot report
caldun --notify        # same, plus a desktop popup if WARN/CRITICAL
caldun --check         # self-test: list discovered sensors + thresholds
caldun --peak          # add the high-water marks recorded since boot
caldun --version       # print the version (also in --json as "version")

caldun --json          # the same report as one JSON object, for programs
caldun --get cpu       # print one bare number and nothing else, for scripts
caldun --watch 10      # one compact line every 10s until interrupted
caldun --watch --json  # ... as JSONL
```

Example report:

```
Machine temperatures (2026-08-16 15:38:25)
-----------------------------------------------------------
  Graphics chip (amdgpu iGPU (edge))     43°C  [OK]
  Processor (k10temp CPU (Tctl))     55.125°C  [OK]
  Drive (nvme Composite)              65.85°C  [OK]
  CPU clock                          1.80 GHz
-----------------------------------------------------------
All sensors within normal range.
```

### For scripts and other programs

`--json` exists so nothing has to scrape the table above — that layout is free
to change, the schema is not. Consumers should check the `schema` field.

```bash
caldun --json | jq '.sensors[] | select(.status != "ok")'
```

`--get` prints a bare number, so no `grep | sed` is needed to do arithmetic:

```bash
[ "$(caldun --get drive)" -lt 70 ] || echo "SSD too hot to start the build"
```

Categories are `cpu`, `gpu`, `drive` and `other`. When a category holds more
than one sensor (two NVMe drives, say) the **hottest** wins — that being the
reading a build gate cares about — and `--get drive:nvme-pci-0300` selects one
exactly. It exits 4 when the category has no sensor on this machine, so
`t=$(caldun --get gpu) || skip` behaves on a headless box.

`--watch` produces a log you can `tee` next to a build and grep afterwards:

```
2026-08-16T15:30:26 gpu=43 cpu=57.75 drive=65.85 cpu_mhz=4250 OK
2026-08-16T15:30:28 gpu=43 cpu=55.75 drive=65.85 cpu_mhz=4289 OK
```

On exit it writes a peak summary to stderr. **Watch mode exits 0 on a clean
interrupt** — unlike every other mode, its status reports that the run ended,
not how hot the machine was on the last sample.

### CPU clock, and why the percentage is sometimes missing

Temperature alone does not answer the question you have during a 40-minute
compile — *am I losing clocks?* 85 °C while holding boost is fine; 85 °C at
1.4 GHz means the build now takes twice as long.

Two deliberate choices here:

- **The figure is the mean across cores, not the maximum.** caldun is itself
  load on the busiest core, so a maximum would read near boost on every sample.
  The mean discriminates: on a Ryzen 7 4800U it reads ~1.5 GHz idle and ~2.1 GHz
  under an all-core load.
- **A percentage appears only against a ceiling caldun trusts.** Under
  `amd_pstate`/`intel_pstate`, `cpuinfo_max_freq` *is* the boost ceiling and is
  used directly. Under `acpi-cpufreq` it is only the **base** clock — that same
  4800U reports 1.8 GHz there while boosting to 4.2 GHz, so the obvious
  `current / cpuinfo_max_freq` ratio reads over 100 % at idle — and sysfs
  exposes no boost ceiling at all. caldun therefore uses the highest clock it
  has ever observed on the machine, and prints absolute GHz only until it has
  `MIN_FREQ_SAMPLES` observations to back that up.

Example `--check`:

```
  ROLE                   SENSOR                   WARN     CRIT   SOURCE
  Processor              k10temp Tctl               85       95   default
  Drive                  nvme Composite           73.0       83   default
```

Each row leads with a plain-language name and keeps the technical sensor name in
parentheses. The desktop popup (`--notify`) uses the same wording, e.g.:

```
🟡 Drive is warm: 78.0°C (nvme Composite)
🔴 Processor is very hot: 96.0°C (k10temp Tctl)
```

### Exit codes

| Code | Meaning |
|------|---------|
| `0`  | All sensors OK |
| `1`  | At least one sensor at/above its **warn** threshold |
| `2`  | At least one sensor at/above its **critical** threshold |
| `3`  | A required command (`sensors` or `jq`) is not installed |
| `4`  | No trustworthy sensors found (run `sudo sensors-detect`), or `--get` was asked for a category this machine has no sensor for |
| `64` | Usage error: unknown argument, missing option value, or two output modes at once |

`--watch` is the exception: it exits `0` on a clean interrupt, because its
status reports that the run ended rather than the last sample's temperature.

### Requirements

- `lm-sensors` (`sensors`) and `jq` — pulled in automatically by the package.
  One-time setup: `sudo sensors-detect`.
- `libnotify-bin` (`notify-send`) — only for `--notify`; if absent, the popup is
  silently skipped and the text report still prints.

## MATE panel applet

The applet shows live temperatures right in the panel, e.g. `T: CPU:42° SSD:45°`,
with the text colour following the worst status (green OK, amber WARN, red
CRITICAL). Hover for the full multi-line `caldun` report as a tooltip.

- **Add it:** right-click the MATE panel → **Add to Panel** → **Caldun**.
- **Left-click** the applet to refresh immediately. **Right-click** opens the
  panel's standard menu (Remove, Move, Lock).
- It re-reads sensors every 120 s on its own, and reappears at its saved position
  after logout/login.

It is a thin front end: it runs `/usr/bin/caldun` and parses the report, so it
inherits the same trust model, thresholds, and faulty-sensor handling as the CLI.

If the applet appears in **Add to Panel** but no process starts, **log out and
back in** — the D-Bus session daemon only rescans its service directory at login.
For a quick health check of the Python dependencies and the applet binary:

```bash
./diagnose-applet.sh
```

## Configuration

Settings live in `/etc/caldun.conf` (a dpkg conffile — your edits survive
upgrades). It is sourced as shell; set only variables. Highlights:

```sh
WARN_MARGIN=10                 # WARN this many °C below the effective CRIT
CPU_WARN=85;   CPU_CRIT=95
GPU_WARN=85;   GPU_CRIT=95
DRIVE_WARN=75; DRIVE_CRIT=83   # conservative on purpose (see NVMe incident)
EXTRA_SENSORS=""               # force-include: "chip-glob[=CATEGORY] ..."
IGNORE_SENSORS=""              # force-exclude: "chip-glob ..."
```

Edit and save — no rebuild needed. The background service picks up changes on its
next run.

## Faulty sensors and the known-issues database

Even a *trusted* driver can report a bogus value — usually a device firmware bug.
The classic example: some **Samsung 980** SSD firmwares intermittently report a
phantom `~84°C` (on the `Composite` *and* `Sensor 1` channels) while a third
channel and the drive itself are actually `~65°C`.

Caldun catches this automatically. The insight is physical: a real overheat
heats **every** channel on a chip together, so even the *coolest* one is warm;
a faulty sensor leaves a sane channel reading cool. So when an alarming channel
reads more than `ANOMALY_MARGIN` (default 15°C) hotter than *another channel on
the same chip that is still below its `WARN` level*, the reading is treated as a
**suspected sensor fault**, not real heat. (The check compares against the
*coolest* channel, not the hottest — a firmware bug can corrupt several channels
at once, so the hottest sibling can be bogus too.)

- it is tagged `[SUSPECT]` and listed in a separate *"Suspected sensor / firmware
  issues"* section instead of raising a thermal alarm;
- it does **not** change the exit code (no false `WARN`/`CRITICAL`);
- a genuine overheat — where the sibling channels are also hot — is **never**
  masked and still alerts as usual.

```
  Drive (nvme Composite)              83.85°C  [SUSPECT]
-----------------------------------------------------------
All sensors within normal range.

Suspected sensor / firmware issues (not real temperatures):
  • Drive — reads 83.85°C while another channel on this device reads only 65.85°C.
      device: Samsung SSD 980 1TB (fw 2B4QFXO7), nvme Composite
      known defect: Firmware 2B4QFXO7 reports phantom ~84°C Composite spikes…
      solution:     Update the SSD firmware to 3B4QFXO7 or later…
```

### The database

The defect/solution text comes from **`/etc/caldun-known-issues.conf`** (a
dpkg conffile — your edits survive upgrades). It maps a device to a human-readable
defect and fix. When a `[SUSPECT]` reading has no matching entry, Caldun
still flags it, with a generic *"likely a faulty sensor, verify before trusting"*
note.

Each record is a blank-line-separated block of `key: value` lines:

```
device:   Samsung SSD 980*    # REQUIRED. case-insensitive glob on the model name
firmware: 2B4QFXO7            # OPTIONAL. glob on firmware; omit to match any
defect:   one-line description of the problem (shown to you)
solution: one-line description of the fix (shown to you)
```

- The **first** matching record wins; `#` lines are comments.
- Device model/firmware are currently resolved for **NVMe** drives (via sysfs);
  other chips match only a `device: *` wildcard entry.
- To add your own, append a new record. For example, to silence a different drive:

  ```
  device:   Crucial P2*
  defect:   Idle temperature reported below 0°C — a SMART reporting error.
  solution: Cosmetic; update firmware if Crucial has published a fix.
  ```

### Tuning

In `/etc/caldun.conf`:

```sh
ANOMALY_DETECT=1      # 0 disables faulty-sensor detection entirely
ANOMALY_MARGIN=15     # °C a channel must exceed all (sub-WARN) siblings by
```

## The systemd user timer

Units are shipped by the package into `/usr/lib/systemd/user/` and enabled for
all users:

- `caldun.service` — runs `caldun --notify` (oneshot)
- `caldun.timer` — fires 1 minute after login, then every **2 minutes**

### Common commands

| Action | Command |
|--------|---------|
| Watch it live | `journalctl --user -u caldun.service -f -o cat` |
| Last run | `systemctl --user status caldun.service` |
| Next scheduled run | `systemctl --user list-timers caldun.timer` |
| Run once now | `systemctl --user start caldun.service` |
| Stop / disable (this user) | `systemctl --user disable --now caldun.timer` |
| Re-enable | `systemctl --user enable --now caldun.timer` |

### Change the interval

Override the unit without editing package files:

```bash
systemctl --user edit caldun.timer      # set OnUnitActiveSec=…
systemctl --user restart caldun.timer
```

### Keep it running when logged out (optional)

A user timer pauses when you fully log out. To keep it alive without an active
session, enable lingering (needs `sudo`):

```bash
sudo loginctl enable-linger "$USER"
```

## Building the package

The build host needs `debhelper` (target machines do **not** — they only need
the runtime `Depends`, which `apt` resolves):

```bash
sudo apt-get install debhelper devscripts lintian   # one-time, build host only
./build-deb.sh                                       # produces caldun_<ver>_all.deb
```

`build-deb.sh` wraps `dpkg-buildpackage -us -uc -b` in a temporary build dir so
the `.deb` lands next to the script. The result is a normal `.deb`: build it once,
copy it to any machine, and `apt install ./caldun_<ver>_all.deb`.

To deploy a script-only change to an already-installed machine without bumping the
version:

```bash
sudo cp caldun.sh /usr/bin/caldun
sudo cp applet/caldun-applet /usr/lib/mate-panel/applets/caldun-applet
```

## Notification duration

The popup uses `notify-send -t 15000` (15 s). **GNOME ignores `-t`** and uses its
own fixed duration; on GNOME, use a notification daemon that honors timeouts
(e.g. `dunst`) if you need it to linger.

## macOS (Intel) proof of concept

[`macos/caldun-macos.sh`](macos/README.md) ports the core logic to Intel Macs.
The categorise → threshold → report → notify pipeline carries over almost
unchanged; only the sensor backend differs (macOS has no `lm-sensors`, so it uses
`iStats` or `osx-cpu-temp`). It runs on a `launchd` LaunchAgent instead of a
systemd timer. See [`macos/README.md`](macos/README.md) for setup and the
PoC's scope limits (no hardware thresholds, Intel only).

## NVMe thermal incident — 2026-06-20

A Samsung SSD 980 1TB (`/dev/nvme0`) caused a hard system freeze at ~14:55.
`smartd` had fired `Critical Warning 0x02: Temperature` 40 minutes earlier. The
NVMe throttled hard under load, stalling kernel I/O and freezing the system.

This is why `DRIVE_CRIT` defaults to **83°C** even though the drive's *hardware*
critical is ~109°C: a drive that hot can take the machine down long before it
reaches the silicon limit. The hybrid logic keeps the conservative 83°C because
it is lower than the hardware value. **Physical fix:** a 1 mm thermal pad
(≥ 6 W/m·K) between the SSD and the case lid drops temperatures 15–25°C.

---

**[English](#caldun) · [Deutsch](#caldun-deutsch)**

# Caldun (Deutsch)

Kostenlos für die nichtkommerzielle Nutzung. Für die kommerzielle Nutzung siehe
[COMMERCIAL.md](COMMERCIAL.md).

Caldun meldet die **vertrauenswürdigen** Temperatursensoren eines Rechners und
kennzeichnet alles, was warm oder kritisch läuft. Es erkennt Sensoren
automatisch, sodass dasselbe Paket auf verschiedenen Rechnern funktioniert. Es
kann in der Kontrollleiste sitzen und eine Desktop-Warnung anzeigen, wenn der
Rechner heiss wird.

Es ist für **Ubuntu** und **Linux Mint** mit dem **MATE**-Desktop gebaut und
liefert drei Komponenten:

| Komponente | Was es ist |
|-----------|------------|
| **`caldun`** (CLI) | Bash-Werkzeug, das Sensoren über `lm-sensors` ausliest, warme/kritische Werte kennzeichnet und optional eine Desktop-Benachrichtigung auslöst. Läuft zudem als benutzereigener systemd-Timer alle 2 Minuten. |
| **Caldun-Applet** | Python-3-MATE-Panel-Applet, das CPU-/GPU-/Laufwerks-Temperaturen live in der Kontrollleiste anzeigt, farblich nach Status codiert. |
| **`.deb`-Paket** | Installiert beide Komponenten, deren Konfiguration, Symbole, die Handbuchseite und den systemd-Benutzer-Timer. |

Ein minimaler **Machbarkeitsnachweis für macOS (Intel)** liegt in
[`macos/`](macos/README.md).

## Warum nur „vertrauenswürdige“ Sensoren?

Manche Chips lügen. Die zuverlässigen Werte stammen von dedizierten
Kernel-Treibern — `k10temp`/`coretemp`/`zenpower` (CPU),
`amdgpu`/`i915`/`nouveau` (GPU), `nvme`/`drivetemp` (Laufwerke). Die
ISA-**Super-I/O**-Chips (z. B. `nct6798`) haben Kanäle
`CPUTIN`/`AUXTIN*`/`SYSTIN`, die auf vielen Boards — besonders bei AMD —
**falsch beschriftet** sind und Unsinnswerte melden (z. B. `CPUTIN: +127°C`).
Caldun wählt Sensoren über eine **Erlaubnisliste nach Treiberklasse** aus und
ignoriert Super-I/O-Chips standardmässig, sodass es nie Fehlalarme von einem
lügenden Chip auslöst. Die Erlaubnisliste ist konfigurierbar (siehe
`EXTRA_SENSORS` / `IGNORE_SENSORS`).

## Wie Schwellenwerte bestimmt werden (hybrid)

Für jeden Sensor:

- Meldet die Hardware ein Limit (`temp*_max` / `temp*_crit` in `sensors -j`),
  wird dieses Limit verwendet.
- Andernfalls wird ein kategoriespezifischer Standardwert (`CPU_*`, `GPU_*`,
  `DRIVE_*`) verwendet. CPUs und GPUs melden meist kein Limit, daher sind die
  Standardwerte dort entscheidend.
- Existieren **beide**, gewinnt der **niedrigere (vorsichtigere)** Wert — ein
  Hardware-Limit kann eine Warnung nur *früher* auslösen, nie später als der
  Standardwert.

`WARN` wird `WARN_MARGIN` Grad (Standard 10) unter dem effektiven `CRITICAL`
gesetzt. Führe `caldun --check` aus, um genau zu sehen, was überwacht wird und
ob jeder Schwellenwert von `hardware` oder einem `default` stammt.

## Installation

```bash
sudo apt install ./caldun_<ver>_all.deb     # zieht lm-sensors, jq mit ein
```

Bei der ersten Installation kann ein einmaliger Sensor-Scan nötig sein, damit
der Kernel die Chips bereitstellt:

```bash
sudo sensors-detect      # die Vorgaben mit JA beantworten, dann neu starten
```

Das Paket aktiviert einen **benutzereigenen** systemd-Timer für alle Benutzer;
er startet bei der nächsten Anmeldung. (Der Benutzerkontext ist beabsichtigt —
er läuft in deiner Desktop-Sitzung, damit `notify-send`-Pop-ups auch
erscheinen.)

Um das Panel-Applet nach der Installation hinzuzufügen: Rechtsklick auf die
MATE-Kontrollleiste → **Zum Panel hinzufügen** → **Caldun**. (Erscheint es nicht
in der Liste, melde dich ab und wieder an — siehe den
[Applet-Abschnitt](#mate-panel-applet-deutsch) unten.)

## Verwendung

```bash
caldun                 # einmaligen Bericht ausgeben
caldun --notify        # dasselbe, plus Desktop-Pop-up bei WARN/CRITICAL
caldun --check         # Selbsttest: erkannte Sensoren + Schwellenwerte auflisten
caldun --peak          # zusätzlich die Höchstwerte seit dem Systemstart
caldun --version       # Version ausgeben (steht auch in --json unter "version")

caldun --json          # derselbe Bericht als ein JSON-Objekt, für Programme
caldun --get cpu       # nur eine nackte Zahl ausgeben, für Skripte
caldun --watch 10      # alle 10 s eine kompakte Zeile, bis abgebrochen wird
caldun --watch --json  # ... als JSONL
```

Beispielbericht:

```
Machine temperatures (2026-08-16 15:38:25)
-----------------------------------------------------------
  Graphics chip (amdgpu iGPU (edge))     43°C  [OK]
  Processor (k10temp CPU (Tctl))     55.125°C  [OK]
  Drive (nvme Composite)              65.85°C  [OK]
  CPU clock                          1.80 GHz
-----------------------------------------------------------
All sensors within normal range.
```

### Für Skripte und andere Programme

`--json` gibt es, damit niemand die obige Tabelle auswerten muss — deren Layout
darf sich ändern, das Schema nicht. Programme sollten das Feld `schema` prüfen.

```bash
caldun --json | jq '.sensors[] | select(.status != "ok")'
```

`--get` gibt eine nackte Zahl aus, sodass für eine Rechnung kein `grep | sed`
nötig ist:

```bash
[ "$(caldun --get drive)" -lt 70 ] || echo "SSD zu heiss für den Build"
```

Kategorien sind `cpu`, `gpu`, `drive` und `other`. Enthält eine Kategorie
mehrere Sensoren (etwa zwei NVMe-Laufwerke), gewinnt der **heisseste** — das ist
der Wert, auf den ein Build-Gate schaut —, und `--get drive:nvme-pci-0300`
wählt gezielt einen aus. Fehlt die Kategorie auf dieser Maschine, ist der
Exit-Code 4, sodass `t=$(caldun --get gpu) || skip` auch auf einer Maschine ohne
Grafikchip funktioniert.

`--watch` erzeugt ein Protokoll, das sich neben einem Build mit `tee` mitschreiben
und später durchsuchen lässt:

```
2026-08-16T15:30:26 gpu=43 cpu=57.75 drive=65.85 cpu_mhz=4250 OK
2026-08-16T15:30:28 gpu=43 cpu=55.75 drive=65.85 cpu_mhz=4289 OK
```

Beim Beenden wird eine Zusammenfassung der Höchstwerte nach stderr geschrieben.
**Der Watch-Modus endet bei sauberem Abbruch mit 0** — anders als alle anderen
Modi meldet sein Exit-Code, dass der Lauf beendet wurde, und nicht, wie heiss
die Maschine bei der letzten Messung war.

### CPU-Takt, und warum der Prozentwert manchmal fehlt

Die Temperatur allein beantwortet die Frage nicht, die man während eines
40-minütigen Compiles wirklich hat — *verliere ich Takt?* 85 °C bei anliegendem
Boost sind unbedenklich; 85 °C bei 1,4 GHz bedeuten, dass der Build nun doppelt
so lange dauert.

Zwei bewusste Entscheidungen:

- **Angegeben wird der Mittelwert über alle Kerne, nicht das Maximum.** caldun
  ist selbst Last auf dem am stärksten belasteten Kern; ein Maximum läge daher
  bei jeder einzelnen Messung nahe am Boost. Der Mittelwert unterscheidet: auf
  einem Ryzen 7 4800U rund 1,5 GHz im Leerlauf und rund 2,1 GHz unter Volllast
  auf allen Kernen.
- **Ein Prozentwert erscheint nur gegenüber einer Obergrenze, der caldun traut.**
  Unter `amd_pstate`/`intel_pstate` *ist* `cpuinfo_max_freq` die Boost-Grenze und
  wird direkt verwendet. Unter `acpi-cpufreq` ist sie nur der **Basistakt** —
  derselbe 4800U meldet dort 1,8 GHz, während er auf 4,2 GHz boostet, sodass das
  naheliegende Verhältnis `aktuell / cpuinfo_max_freq` schon im Leerlauf über
  100 % liegt —, und sysfs kennt dort überhaupt keine Boost-Grenze. caldun
  verwendet deshalb den höchsten je auf dieser Maschine beobachteten Takt und
  gibt bis zu `MIN_FREQ_SAMPLES` Messungen nur absolute GHz aus.

Beispiel `--check`:

```
  ROLE                   SENSOR                   WARN     CRIT   SOURCE
  Processor              k10temp Tctl               85       95   default
  Drive                  nvme Composite           73.0       83   default
```

Jede Zeile beginnt mit einem klar verständlichen Namen und behält den
technischen Sensornamen in Klammern. Das Desktop-Pop-up (`--notify`) verwendet
denselben Wortlaut, z. B.:

```
🟡 Drive is warm: 78.0°C (nvme Composite)
🔴 Processor is very hot: 96.0°C (k10temp Tctl)
```

### Exit-Codes

| Code | Bedeutung |
|------|---------|
| `0`  | Alle Sensoren OK |
| `1`  | Mindestens ein Sensor auf/über seinem **Warn**-Schwellenwert |
| `2`  | Mindestens ein Sensor auf/über seinem **kritischen** Schwellenwert |
| `3`  | Ein benötigter Befehl (`sensors` oder `jq`) ist nicht installiert |
| `4`  | Keine vertrauenswürdigen Sensoren gefunden (`sudo sensors-detect` ausführen), oder `--get` wurde nach einer Kategorie gefragt, für die diese Maschine keinen Sensor hat |
| `64` | Aufruffehler: unbekanntes Argument, fehlender Optionswert oder zwei Ausgabemodi gleichzeitig |

`--watch` ist die Ausnahme: bei sauberem Abbruch endet es mit `0`, weil sein
Exit-Code meldet, dass der Lauf beendet wurde, und nicht die Temperatur der
letzten Messung.

### Voraussetzungen

- `lm-sensors` (`sensors`) und `jq` — werden automatisch vom Paket mitgezogen.
  Einmalige Einrichtung: `sudo sensors-detect`.
- `libnotify-bin` (`notify-send`) — nur für `--notify`; fehlt es, wird das
  Pop-up stillschweigend übersprungen und der Textbericht trotzdem ausgegeben.

## MATE-Panel-Applet
<a id="mate-panel-applet-deutsch"></a>

Das Applet zeigt Temperaturen live in der Kontrollleiste, z. B.
`T: CPU:42° SSD:45°`, wobei die Textfarbe dem schlechtesten Status folgt (grün
OK, gelb WARN, rot CRITICAL). Beim Überfahren mit der Maus erscheint der
vollständige mehrzeilige `caldun`-Bericht als Tooltip.

- **Hinzufügen:** Rechtsklick auf die MATE-Kontrollleiste → **Zum Panel
  hinzufügen** → **Caldun**.
- **Linksklick** auf das Applet aktualisiert sofort. **Rechtsklick** öffnet das
  Standardmenü der Kontrollleiste (Entfernen, Verschieben, Sperren).
- Es liest die Sensoren von selbst alle 120 s neu und erscheint nach
  Abmeldung/Anmeldung wieder an seiner gespeicherten Position.

Es ist ein schlankes Frontend: Es führt `/usr/bin/caldun` aus und wertet den
Bericht aus, erbt also dasselbe Vertrauensmodell, dieselben Schwellenwerte und
dieselbe Behandlung defekter Sensoren wie die CLI.

Erscheint das Applet unter **Zum Panel hinzufügen**, aber es startet kein
Prozess, dann **melde dich ab und wieder an** — der D-Bus-Sitzungsdienst liest
sein Dienstverzeichnis nur bei der Anmeldung neu ein. Für eine schnelle Prüfung
der Python-Abhängigkeiten und des Applet-Programms:

```bash
./diagnose-applet.sh
```

## Konfiguration

Die Einstellungen liegen in `/etc/caldun.conf` (eine dpkg-conffile — deine
Änderungen überstehen Upgrades). Sie wird als Shell eingelesen; setze nur
Variablen. Höhepunkte:

```sh
WARN_MARGIN=10                 # WARN so viele °C unter dem effektiven CRIT
CPU_WARN=85;   CPU_CRIT=95
GPU_WARN=85;   GPU_CRIT=95
DRIVE_WARN=75; DRIVE_CRIT=83   # bewusst vorsichtig (siehe NVMe-Vorfall)
EXTRA_SENSORS=""               # erzwingen aufnehmen: "chip-glob[=KATEGORIE] ..."
IGNORE_SENSORS=""              # erzwingen ausschliessen: "chip-glob ..."
```

Bearbeiten und speichern — kein Neubau nötig. Der Hintergrunddienst übernimmt
Änderungen beim nächsten Lauf.

## Defekte Sensoren und die Datenbank bekannter Probleme

Selbst ein *vertrauenswürdiger* Treiber kann einen falschen Wert melden — meist
ein Firmware-Fehler des Geräts. Das klassische Beispiel: Manche
**Samsung-980**-SSD-Firmwares melden sporadisch ein Phantom von `~84°C` (auf den
Kanälen `Composite` *und* `Sensor 1`), während ein dritter Kanal und das
Laufwerk selbst tatsächlich `~65°C` haben.

Caldun erkennt dies automatisch. Die Einsicht ist physikalisch: Eine echte
Überhitzung erwärmt **jeden** Kanal eines Chips gemeinsam, sodass selbst der
*kühlste* warm ist; ein defekter Sensor lässt einen intakten Kanal kühl. Wenn
also ein alarmierender Kanal mehr als `ANOMALY_MARGIN` (Standard 15°C) wärmer
liest als *ein anderer Kanal desselben Chips, der noch unter seinem
`WARN`-Niveau liegt*, wird der Wert als **vermuteter Sensorfehler** behandelt,
nicht als echte Hitze. (Die Prüfung vergleicht mit dem *kühlsten* Kanal, nicht
dem heissesten — ein Firmware-Fehler kann mehrere Kanäle gleichzeitig
verfälschen, also kann auch der heisseste Geschwisterkanal falsch sein.)

- Er wird als `[SUSPECT]` markiert und in einem separaten Abschnitt
  *„Suspected sensor / firmware issues“* aufgeführt, statt einen
  Temperaturalarm auszulösen;
- er ändert den Exit-Code **nicht** (kein falsches `WARN`/`CRITICAL`);
- eine echte Überhitzung — bei der die Geschwisterkanäle ebenfalls heiss sind —
  wird **nie** verdeckt und alarmiert wie gewohnt.

```
  Drive (nvme Composite)              83.85°C  [SUSPECT]
-----------------------------------------------------------
All sensors within normal range.

Suspected sensor / firmware issues (not real temperatures):
  • Drive — reads 83.85°C while another channel on this device reads only 65.85°C.
      device: Samsung SSD 980 1TB (fw 2B4QFXO7), nvme Composite
      known defect: Firmware 2B4QFXO7 reports phantom ~84°C Composite spikes…
      solution:     Update the SSD firmware to 3B4QFXO7 or later…
```

### Die Datenbank

Der Defekt-/Lösungstext stammt aus **`/etc/caldun-known-issues.conf`** (eine
dpkg-conffile — deine Änderungen überstehen Upgrades). Sie ordnet einem Gerät
einen menschenlesbaren Defekt und eine Lösung zu. Hat ein `[SUSPECT]`-Wert
keinen passenden Eintrag, kennzeichnet Caldun ihn trotzdem, mit einem generischen
Hinweis *„likely a faulty sensor, verify before trusting“*.

Jeder Datensatz ist ein durch Leerzeilen getrennter Block aus
`key: value`-Zeilen:

```
device:   Samsung SSD 980*    # PFLICHT. Glob auf den Modellnamen (Gross-/Kleinschreibung egal)
firmware: 2B4QFXO7            # OPTIONAL. Glob auf die Firmware; weglassen = beliebig
defect:   einzeilige Beschreibung des Problems (wird dir angezeigt)
solution: einzeilige Beschreibung der Lösung (wird dir angezeigt)
```

- Der **erste** passende Datensatz gewinnt; `#`-Zeilen sind Kommentare.
- Gerätemodell/Firmware werden derzeit für **NVMe**-Laufwerke aufgelöst (über
  sysfs); andere Chips passen nur auf einen `device: *`-Platzhaltereintrag.
- Um eigene hinzuzufügen, hänge einen neuen Datensatz an. Beispiel, um ein
  anderes Laufwerk stummzuschalten:

  ```
  device:   Crucial P2*
  defect:   Idle temperature reported below 0°C — a SMART reporting error.
  solution: Cosmetic; update firmware if Crucial has published a fix.
  ```

### Feinabstimmung

In `/etc/caldun.conf`:

```sh
ANOMALY_DETECT=1      # 0 deaktiviert die Erkennung defekter Sensoren komplett
ANOMALY_MARGIN=15     # °C, um die ein Kanal alle (unter WARN liegenden) Geschwister übertreffen muss
```

## Der systemd-Benutzer-Timer

Die Units werden vom Paket nach `/usr/lib/systemd/user/` ausgeliefert und für
alle Benutzer aktiviert:

- `caldun.service` — führt `caldun --notify` aus (oneshot)
- `caldun.timer` — feuert 1 Minute nach der Anmeldung, dann alle **2 Minuten**

### Häufige Befehle

| Aktion | Befehl |
|--------|---------|
| Live mitverfolgen | `journalctl --user -u caldun.service -f -o cat` |
| Letzter Lauf | `systemctl --user status caldun.service` |
| Nächster geplanter Lauf | `systemctl --user list-timers caldun.timer` |
| Jetzt einmal ausführen | `systemctl --user start caldun.service` |
| Stoppen / deaktivieren (dieser Benutzer) | `systemctl --user disable --now caldun.timer` |
| Wieder aktivieren | `systemctl --user enable --now caldun.timer` |

### Das Intervall ändern

Überschreibe die Unit, ohne Paketdateien zu bearbeiten:

```bash
systemctl --user edit caldun.timer      # OnUnitActiveSec=… setzen
systemctl --user restart caldun.timer
```

### Bei Abmeldung weiterlaufen lassen (optional)

Ein Benutzer-Timer pausiert, wenn du dich vollständig abmeldest. Um ihn ohne
aktive Sitzung am Leben zu halten, aktiviere Lingering (benötigt `sudo`):

```bash
sudo loginctl enable-linger "$USER"
```

## Das Paket bauen

Der Build-Host benötigt `debhelper` (Zielrechner **nicht** — sie brauchen nur
die Laufzeit-`Depends`, die `apt` auflöst):

```bash
sudo apt-get install debhelper devscripts lintian   # einmalig, nur Build-Host
./build-deb.sh                                       # erzeugt caldun_<ver>_all.deb
```

`build-deb.sh` kapselt `dpkg-buildpackage -us -uc -b` in einem temporären
Build-Verzeichnis, sodass die `.deb` neben dem Skript landet. Das Ergebnis ist
eine normale `.deb`: einmal bauen, auf beliebige Rechner kopieren und
`apt install ./caldun_<ver>_all.deb`.

Um eine reine Skript-Änderung auf einem bereits installierten Rechner zu
verteilen, ohne die Version zu erhöhen:

```bash
sudo cp caldun.sh /usr/bin/caldun
sudo cp applet/caldun-applet /usr/lib/mate-panel/applets/caldun-applet
```

## Benachrichtigungsdauer

Das Pop-up verwendet `notify-send -t 15000` (15 s). **GNOME ignoriert `-t`** und
verwendet eine eigene feste Dauer; nutze unter GNOME einen
Benachrichtigungsdienst, der Timeouts beachtet (z. B. `dunst`), wenn es länger
stehen bleiben soll.

## macOS-(Intel-)Machbarkeitsnachweis

[`macos/caldun-macos.sh`](macos/README.md) portiert die Kernlogik auf
Intel-Macs. Die Pipeline kategorisieren → Schwellenwert → berichten →
benachrichtigen wird fast unverändert übernommen; nur das Sensor-Backend
unterscheidet sich (macOS hat kein `lm-sensors`, es nutzt daher `iStats` oder
`osx-cpu-temp`). Es läuft über einen `launchd`-LaunchAgent statt eines
systemd-Timers. Siehe [`macos/README.md`](macos/README.md) für die Einrichtung
und die Grenzen des Machbarkeitsnachweises (keine Hardware-Schwellenwerte, nur
Intel).

## NVMe-Wärmevorfall — 2026-06-20

Eine Samsung SSD 980 1TB (`/dev/nvme0`) verursachte gegen 14:55 einen harten
Systemstillstand. `smartd` hatte 40 Minuten zuvor `Critical Warning 0x02:
Temperature` ausgelöst. Die NVMe drosselte unter Last stark, blockierte die
Kernel-I/O und fror das System ein.

Deshalb hat `DRIVE_CRIT` den Standardwert **83°C**, obwohl das *Hardware*-Limit
des Laufwerks bei ~109°C liegt: Ein so heisses Laufwerk kann den Rechner zum
Absturz bringen, lange bevor es das Silizium-Limit erreicht. Die Hybrid-Logik
behält die vorsichtigen 83°C, weil sie niedriger als der Hardware-Wert sind.
**Physische Lösung:** Ein 1-mm-Wärmeleitpad (≥ 6 W/m·K) zwischen SSD und
Gehäusedeckel senkt die Temperatur um 15–25°C.
