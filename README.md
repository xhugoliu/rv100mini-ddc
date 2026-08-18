# DDC Input Hotkeys

A small, native macOS command-line tool and global-hotkey daemon that changes an
external monitor's input through DDC/CI. It targets Apple Silicon Macs and does
not need BetterDisplay, a menu-bar item, or Accessibility permission.

The runtime is intentionally narrow: it only sends MCCS input-source VCP `0x60`.
The low-level I²C/DDC transport comes from the MIT-licensed
[AppleSiliconDDC](https://github.com/waydabber/AppleSiliconDDC) package.

The complete RV100mini hardware identification, VCP experiments, confirmed
private input mappings, and known inactive-port limitation are recorded in the
[Chinese experiment notes](docs/experiment-notes.zh-CN.md).

## Build and inspect

```sh
swift build -c release
.build/release/ddc-input-hotkeys list
.build/release/ddc-input-hotkeys sources
```

## RV100mini input codes

This monitor uses non-standard raw values instead of the MCCS values it reports
in its capabilities string:

- HDMI = `5` (confirmed)
- DisplayPort = `6` (inferred; awaiting a live DP device)
- USB-C = `7` (confirmed)

The example configuration is already set up for this monitor:

- Control-Option-1 to HDMI
- Control-Option-2 to DisplayPort
- Control-Option-3 to USB-C

You can test the confirmed inputs directly:

```sh
.build/release/ddc-input-hotkeys set 5 --display RV100mini
.build/release/ddc-input-hotkeys set 7 --display RV100mini
```

## Standard input codes

For other monitors, the standard codes most likely to matter are:

- `hdmi1` = `0x11`
- `hdmi2` = `0x12`
- `displayport1` = `0x0F`
- `displayport2` = `0x10`
- `usbc` = `0x1B`

Many USB-C monitor inputs identify themselves as DisplayPort. Raw decimal or
hexadecimal codes are accepted in both the CLI and configuration file.

```sh
.build/release/ddc-input-hotkeys set hdmi1 --display RV100mini
.build/release/ddc-input-hotkeys set displayport1 --display RV100mini
```

Some monitors stop accepting commands from a port after switching away from it.
Keep the monitor's physical input button within reach during initial testing.

## Run the daemon manually

Copy and edit the example first:

```sh
mkdir -p "$HOME/Library/Application Support/DDCInputHotkeys"
cp config.example.json "$HOME/Library/Application Support/DDCInputHotkeys/config.json"
.build/release/ddc-input-hotkeys daemon
```

Supported keys are `0`-`9`, `A`-`Z`, and `F1`-`F20`. Supported modifiers are
`command`, `control`, `option`, and `shift`.

## Start automatically at login

After verifying both input codes and editing `config.example.json` if needed:

```sh
./scripts/install.sh
```

The installer places one binary in `~/.local/bin`, one configuration file under
`~/Library/Application Support/DDCInputHotkeys`, and one LaunchAgent plist. It
does not install a package manager or a menu-bar app.

To remove the daemon and binary while preserving configuration:

```sh
./scripts/uninstall.sh
```

## License note

This project depends on AppleSiliconDDC at commit
`97af3818b9803e51412fb50cac1506db1d73b5bf`, which is licensed under the MIT
License and Copyright © 2021 Istvan T. See Swift Package Manager's checked-out
dependency for the full license text.
