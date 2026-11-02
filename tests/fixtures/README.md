# Sensor fixtures

Canned `sensors -j` output, fed to caldun via `CALDUN_SENSORS_JSON=<file>` so
the script can be exercised where the real chips are absent (CI runners, VMs)
or where the interesting state is rare (a firmware spike).

    CALDUN_SENSORS_JSON=tests/fixtures/amd-normal.json ./caldun.sh --json

| file | what it captures |
|------|------------------|
| `amd-normal.json` | Ryzen 7 4800U laptop at idle: k10temp, amdgpu (with the voltage/power channels that are *not* temperatures), nvme with three channels, plus the deliberately untrusted nct6798. |
| `nvme-phantom-spike.json` | *Synthetic*: `amd-normal.json` with Composite + Sensor 1 at 84.85 and Sensor 2 at 65.85 — the Samsung 980 firmware-bug shape. Must be `[SUSPECT]`, exit 0. A real capture is still wanted (see `todo/MANUAL-CHECKS.md`). |
| `nvme-overheat.json` | *Synthetic*: same Composite reading, but every channel hot (coolest 80.85, above WARN). Real heat: must be `[CRITICAL]`, exit 2 — the suspect logic must never mask it. |
| `two-drives.json` | *Synthetic*: `amd-normal.json` plus a hotter second NVMe (`nvme-pci-0400`, 70.85). It sorts second, so `--get drive` must pick the hottest, not the first. |
| `no-trusted-chips.json` | Only the untrusted nct6798 from `amd-normal.json`. Every reporting mode must exit 4 with empty stdout. CI uses it instead of the runner's real hardware, which may expose a trusted chip. |

Used by `tests/run.sh`. Real captures still wanted (phantom spike from the
actual drive, a chip with no hardware limits) are tracked in `todo/MANUAL-CHECKS.md`.
