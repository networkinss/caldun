# Caldun — manual checks

Things that need real hardware, a rare event, or a person at the panel, so no
code change can tick them off. Captures go to `tests/fixtures/` (see the README
there); once captured, add a test for it in `tests/run.sh`.

## Captures

- [ ] Samsung 980 phantom-84 °C spike (Composite + Sensor 1 high, Sensor 2
      sane) — needs the drive to actually misbehave, so grab a `sensors -j`
      dump next time it happens. A synthetic stand-in
      (`nvme-phantom-spike.json`) is already tested; the real dump would
      confirm the shape matches.
- [ ] A chip with no `_max`/`_crit`.

Capture with:

```
sensors -j > tests/fixtures/<name>.json
```

## Verified by hand, not yet on real hardware

- [ ] Peak file behaviour across a reboot (boot-id reset). The logic is
      exercised, the reboot is not.
- [ ] `amd_pstate` branch of `freq_ceiling()` — this machine is `acpi-cpufreq`,
      so the pstate path has never run. Test on a machine with
      `scaling_driver=amd_pstate` before relying on the percentage there.
- [ ] The applet under a real MATE panel on 1.26 (Mint 21) and 1.28 (Mint 22 /
      Ubuntu 24.04). Its logic is tested headless; `factory_main` and D-Bus
      activation are not. Mint 21.3 / 1.26: applet shows after a panel restart
      with 1.7.2; still to confirm after a fresh login (the 1×1-socket bug
      appeared at login). Check with:

      ```
      xwininfo -root -tree | grep -B1 caldun-applet
      ```

      `…x28`/`…x42` is good, `1x1` is the bug.
