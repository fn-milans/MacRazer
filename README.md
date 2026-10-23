# Serpentine

Control your Razer mouse on a Mac.

Set DPI, polling rate, lighting, sleep, battery alerts and button remaps. Serpentine saves
every setting it can into the mouse itself, so you can set it up, quit the app, and the mouse
keeps working the same way, even on another computer.

Unofficial, and not affiliated with Razer. Started as a fork of
[MacRazer](https://github.com/SorcRR/MacRazer) by SorcRR.

## Install

1. Download `Serpentine.dmg` from the [latest release](../../releases/latest).
2. Drag **Serpentine** into Applications.
3. The first time, right-click **Serpentine** in Finder, choose **Open**, then **Open** again.

Step 3 is needed because the app isn't signed with a paid Apple Developer ID. If macOS still
won't open it, go to System Settings › Privacy & Security and click **Open Anyway**, or run
`xattr -cr /Applications/Serpentine.app` in Terminal.

Needs macOS 14 or later.

## Permissions

- **Input Monitoring**, to talk to the mouse. Serpentine asks for it on first launch.
- **Accessibility**, only if you remap buttons.

## Good to know

- Use the **2.4 GHz dongle or a USB cable**. Over Bluetooth most mice only work as a plain
  pointer. The Cobra HyperSpeed and Basilisk V4 Pro can still be set up over Bluetooth, with
  fewer options.
- Some things only the app can do, like remaps the mouse can't store. For those, turn on
  **Keep running in the background** in Settings and Serpentine stays in the menu bar.
- Serpentine sends nothing over the internet. Settings stay on your Mac.

## Contributing

Pull requests are welcome, especially for mice that haven't been checked yet. See
[CONTRIBUTING.md](CONTRIBUTING.md).

## License

GPL-2.0-or-later. See [LICENSE](LICENSE). Credits and trademark notes are in
[NOTICE.md](NOTICE.md).
