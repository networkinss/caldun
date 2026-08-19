# Sensor fixtures

Canned `sensors -j` output, fed to caldun via `CALDUN_SENSORS_JSON=<file>` so
the script can be exercised where the real chips are absent (CI runners, VMs)
or where the interesting state is rare (a firmware spike).

    CALDUN_SENSORS_JSON=tests/fixtures/amd-normal.json ./caldun.sh --json

| file | what it captures |
|------|------------------|
| `amd-normal.json` | Ryzen 7 4800U laptop at idle: k10temp, amdgpu (with the voltage/power channels that are *not* temperatures), nvme with three channels, plus the deliberately untrusted nct6798. |

Only the one fixture so far — enough for CI to assert that the reporting modes
produce real output rather than only that they fail correctly. The wider suite
(phantom-spike, no-hardware-limits, no-trusted-chips) is still to be captured;
see TODO.md.
