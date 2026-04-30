# fanctl

CLI for reading temperatures and controlling fans on Apple Silicon Macs.

> Research project. Tested on M4 Pro / macOS 26. Write commands require [Macs Fan Control](https://crystalidea.com/macs-fan-control) installed (see *Why MFC* below). Reads work standalone.

## Install

```sh
brew install --cask macs-fan-control
git clone git@github.com:surya-teja-222/fanctl.git
cd fanctl
make build
sudo install -m 0755 .build/release/fanctl /usr/local/bin/fanctl
```

## Usage

```sh
fanctl temps --min 40
fanctl fan all
fanctl fan show 0
fanctl get F0Tg
fanctl list --prefix F

sudo fanctl fan rpm 0 4500
sudo fanctl fan auto all
sudo fanctl set F0Md 1 --force
```

For passwordless sudo (only safe because `/usr/local/bin` is root-owned):

```sh
sudo visudo -f /etc/sudoers.d/fanctl
# yourname ALL=(root) NOPASSWD: /usr/local/bin/fanctl
```

## Run in the background (LaunchDaemon)

`fanctl watch` runs a temperature curve loop. To run it always, install the bundled LaunchDaemon. It auto-starts at boot, restarts on crash, and logs to `/var/log/fanctl.log`.

```sh
sudo make install         # builds + installs binary
sudo make install-daemon  # installs and starts the daemon
tail -f /var/log/fanctl.log

# stop:
sudo make uninstall-daemon
```

The daemon uses `--preset cool`. Edit `launchd/dev.fanctl.watch.plist` to change presets or pass `--curve` directly, then re-run `sudo make install-daemon`.

## Why MFC

Apple Silicon's kernel silently no-ops `AppleSMC` writes from regular processes, even as root. Reads work fine. We piggyback on Macs Fan Control's privileged helper via XPC, which already has the working write path.

```
fanctl  ->  XPC  ->  MFC helper  ->  IOKit  ->  AppleSMC firmware
```

Uninstall MFC and writes stop working. Reads keep working.

## Architecture

```
Sources/fanctl/
  main.swift
  SMC/         IOKit transport, byte codec, FourCC, errors
  Discovery/   key enumeration, payload decoding
  Fans/        high-level fan operations
  MFC/         XPC client to the MFC helper
  Commands/    one file per CLI subcommand
```

## Limitations

- Apple Silicon only.
- MFC must be installed for write commands. Without it, readable fan keys (`F0Ac`, `F0Tg`) report stale or zero values when nothing else is actively managing the fan. The firmware keeps cooling correctly; visible state just freezes.
- If MFC's GUI has an active custom curve, it will reassert state and override fanctl writes. Set fans to Auto in MFC, or quit MFC, before testing writes.

## Status

Research-grade. PRs welcome. Particularly interested in:

- Data points from M1 / M2 / M3 / Max / Ultra chips
- A passing experiment of writing through our own SMJobBless helper signed with a Developer ID, to characterize what the kernel actually checks
- A `fanctl watch --curve 60:3000,80:max` subcommand

## Acknowledgements

- [hholtmann/smcFanControl](https://github.com/hholtmann/smcFanControl), [exelban/stats](https://github.com/exelban/stats), [Asahi Linux](https://asahilinux.org), [Macs Fan Control](https://crystalidea.com/macs-fan-control).
