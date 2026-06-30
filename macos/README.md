# macOS proof of concept (Intel)

A minimal port of `../caldun.sh` to Intel Macs. It proves the core idea
works: the categorise → threshold → report → notify logic carries over almost
unchanged; only the **sensor backend** differs (macOS has no `lm-sensors`).

## Install a temperature backend (pick one, no sudo needed)

```bash
gem install iStats          # preferred — exposes CPU/GPU/disk where available
# or
brew install osx-cpu-temp   # CPU (+ GPU best-effort) only
```

## Run

```bash
./caldun-macos.sh           # one-shot report
./caldun-macos.sh --notify  # + macOS notification on WARN/CRITICAL
./caldun-macos.sh --check   # self-test: backend, sensors, thresholds
```

Exit codes match the Linux script: `0` OK, `1` WARN, `2` CRITICAL,
`3` no backend installed, `4` no usable sensors.

Config (optional): same variable names as Linux, read from
`/usr/local/etc/caldun.conf` (override with `$CALDUN_CONF`).

## Run on a schedule (launchd — the systemd-timer equivalent)

`ch.inss.caldun.plist` is a **LaunchAgent**: it runs the script every
120 seconds in your login session, in `--notify` mode. (`launchd` is macOS's
service manager; a LaunchAgent is a user-session job; a plist is its XML config.)

```bash
# 1. Put the script where the plist expects it (or edit ProgramArguments):
sudo cp caldun-macos.sh /usr/local/bin/caldun-macos.sh
sudo chmod +x /usr/local/bin/caldun-macos.sh

# 2. Install and start the agent:
cp ch.inss.caldun.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/ch.inss.caldun.plist

# Check it's registered (look for ch.inss.caldun):
launchctl list | grep caldun

# Logs (configured in the plist):
cat /tmp/caldun.out.log /tmp/caldun.err.log
```

To stop / remove it:

```bash
launchctl unload ~/Library/LaunchAgents/ch.inss.caldun.plist
rm ~/Library/LaunchAgents/ch.inss.caldun.plist
```

Notes:
- On newer macOS, `launchctl load/unload` still works but the modern form is
  `launchctl bootstrap gui/$(id -u) <plist>` / `bootout`.
- The plist sets `PATH` to include `/usr/local/bin` and `/opt/homebrew/bin` so
  `istats`/`osx-cpu-temp` are found — launchd's default PATH is minimal.
- macOS may prompt once to allow notifications from the script/`osascript`.

## What's a PoC shortcut vs. the real Linux version

- **No hardware thresholds.** iStats/osx-cpu-temp don't report per-sensor
  `*_max`/`*_crit`, so every threshold is the category DEFAULT (`source` is
  always `default`). The Linux script's hybrid hardware-limit logic is dropped.
- **Coverage = whatever the tool exposes.** Apple restricts SMC keys; NVMe
  drive temps are often absent on Intel Macs. Run `istats scan` to see yours.
- **Notification** uses `osascript display notification` (the `notify-send`
  equivalent) — single line, no urgency levels.

## Not done in this PoC (was scoped out)

- Menu-bar entry (the MATE-applet equivalent — would be SwiftBar/xbar).
- **Apple Silicon.** SMC keys differ; needs `smctemp` or `powermetrics` (sudo).
  This script targets Intel only.
