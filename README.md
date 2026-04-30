# fanctl

A Swift CLI for reading temperatures and controlling fans on Apple Silicon Macs via the SMC interface.

> ⚠️ **Research project.** Built for an M4 Pro on macOS 26 to scratch a "ramp fans aggressively at 60°C" itch. **Requires [Macs Fan Control](https://crystalidea.com/macs-fan-control) installed** for write commands — see *Why MFC is required* below. Reads work standalone.

## What it does

- `fanctl temps` — read all temperature sensors (~285 on M4 Pro), filter and sort
- `fanctl fan all` / `fanctl fan show <id>` — current fan state (mode, RPM, target, min/max)
- `fanctl fan rpm <id> <rpm>` — force a fan to a specific RPM
- `fanctl fan auto <id|all>` — release fans back to firmware-managed mode
- `fanctl list [--prefix F] [--values]` — enumerate raw SMC keys
- `fanctl get <key>` — read any single SMC key
- `fanctl set <key> <value>` — raw write any SMC key (gated; advanced use)
- `fanctl mfc probe` / `mfc write` — direct XPC probes to the MFC helper

## Quick start

```sh
# Prerequisites: Apple Silicon Mac, macOS 13+, Xcode CLT, Macs Fan Control installed
brew install --cask macs-fan-control

# Build and install
git clone git@github.com:surya-teja-222/fanctl.git
cd fanctl
make build
sudo install -m 0755 .build/release/fanctl /usr/local/bin/fanctl

# Read-only commands work as your user
fanctl temps --min 40
fanctl fan all

# Write commands need root
sudo fanctl fan rpm 0 4500
sleep 8
fanctl fan show 0

# Release back to auto when done
sudo fanctl fan auto all
```

### Optional: passwordless sudo

For convenience, allow `fanctl` without a password prompt. **Only safe because `/usr/local/bin` is root-owned** — never do this for a binary on a user-writable path.

```sh
sudo visudo -f /etc/sudoers.d/fanctl
# Paste, replacing `yourname`:
yourname ALL=(root) NOPASSWD: /usr/local/bin/fanctl
```

## Why MFC is required

Apple Silicon's kernel **silently no-ops `AppleSMC` writes from regular processes — even when running as root.** You can read SMC state freely, but `IOConnectCallStructMethod` write calls return `kIOReturnSuccess` while the underlying value never changes. Independent of running as root, having hardened runtime, or being in `/Library/PrivilegedHelperTools`.

Macs Fan Control's privileged helper (`com.crystalidea.macsfancontrol.smcwrite`, installed at `/Library/PrivilegedHelperTools/`) does have working SMC writes — through some authorization the kernel honors that we haven't fully characterized. So `fanctl` piggybacks on it via XPC:

```
fanctl  ──XPC──>  MFC helper (already trusted by the kernel)  ──IOKit──>  AppleSMC firmware
```

The XPC protocol is small and easy to reverse: it accepts `{ "command": "open" | "close" | "write", "key": "F0Tg", "value": "<hex>" }`. The helper's `shouldAcceptNewConnection` runs `SecCodeCheckValidityWithErrors` against MFC's designated requirement — but appears not to reject our connections in practice. (If you find it does on your machine, please open an issue.)

If you uninstall MFC, fanctl loses fan-write capability. Reads continue to work standalone.

## Standalone path (future)

A real fix would be to ship our own privileged helper, signed with a Developer ID and installed via `SMJobBless`, that holds the working SMC write path. Two open questions: (1) what specifically the kernel checks (we ruled out path, root, hardened runtime, `cs.disable-library-validation`; the most likely remaining gate is some combination of binary location + signing chain that Apple may also have on a TeamID allowlist), and (2) whether a non-Apple TeamID is ever going to land on whatever allowlist exists. Until that's understood, the MFC piggyback is the pragmatic answer.

## How reads work

Apple Silicon's `IOServiceMatching("AppleSMC")` matches `AppleSMCKeysEndpoint`. The IOConnect protocol is the classic SMCKeyData_t 80-byte struct (key at offset 0, dataSize at 28, command byte at 42, payload at 48–79). One M-series quirk: **multi-byte fields use host byte order (little-endian on arm64)** for both struct framing *and* payload values. Classic Intel SMC docs say BE for payloads — Apple changed the convention.

`SMCConnection` caches `keyInfo(key:)` results since they're static per boot, so `fanctl temps` and the planned `fanctl watch` loop avoid 2× IOConnect overhead per read.

## Architecture

```
Sources/fanctl/
├── main.swift                   # ArgumentParser entry
├── SMC/
│   ├── SMCConnection.swift      # IOKit transport, byte buffer + offsets
│   ├── SMCKey.swift             # FourCC codec
│   ├── SMCEncode.swift          # type-aware payload encoding
│   └── SMCError.swift
├── Discovery/
│   ├── KeyEnumerator.swift      # walk all keys via READ_INDEX
│   └── SMCValue.swift           # type-aware payload decoding
├── Fans/
│   └── FanController.swift      # high-level fan ops (delegates writes to helper)
├── MFC/
│   └── MFCHelperClient.swift    # XPC client to MFC's privileged helper
└── Commands/                    # one file per CLI subcommand
```

## Limitations

- **Apple Silicon only.** No Intel fallback; the read endpoint and byte order both differ.
- **MFC must be installed** for any write command. Reads work without it but readable fan keys (`F0Ac`, `F0Tg`) report stale/zero values when neither MFC's GUI nor helper is actively managing the fan — the firmware keeps cooling correctly, the *visible* state just freezes.
- **MFC fights you** if it has an active custom curve. Set fans to `Auto` in MFC's GUI before testing fanctl writes, or quit MFC entirely.
- **Tested only on M4 Pro / macOS 26.** Other Apple Silicon models likely work but the SMC key set and types differ slightly per chip.

## License

TBD — likely MIT. Until a `LICENSE` lands, treat as "personal research, no warranty, ask before redistributing."

## Status

Research-grade. The reader is solid; the writer is a pragmatic workaround. PRs welcome — especially:

- Confirmation/data points from M1 / M2 / M3 / M4 Max / Ultra
- A passing-experiment of writing through our own SMJobBless'd helper signed with a Developer ID, to characterize what the kernel actually checks
- A `fanctl watch --curve 60:3000,80:max` subcommand (not yet implemented; partly the point of building this)

## Acknowledgements

- [hholtmann/smcFanControl](https://github.com/hholtmann/smcFanControl) — reference for the SMC IOConnect struct (Intel-era, doesn't write on Apple Silicon)
- [exelban/stats](https://github.com/exelban/stats) — working M-series SMC *reader* in Swift
- [Macs Fan Control](https://crystalidea.com/macs-fan-control) — without their helper, this project would not exist
- [Asahi Linux](https://asahilinux.org) — kernel-side reference for what the M-series SMC actually looks like under the hood
