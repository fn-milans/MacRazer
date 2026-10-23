# Serpentine — notes for Claude Code

Serpentine is a native macOS app (Swift, SwiftUI on AppKit, SwiftPM, no Xcode project) that
controls Razer mice over USB HID and Bluetooth LE. Its purpose is to write every setting into
the mouse's own memory, so the mouse behaves the same with the app closed; what only software
can do ("driver mode") works while it runs, optionally in the background as a menu bar item.
It started as a fork of MacRazer by SorcRR (credited in README, About, NOTICE).

**Start with [`docs/claude/`](docs/claude/README.md).** It has the architecture, the design
decisions and why, the UI design rules, the workflows, the conventions, and where the work
stands. Read `status.md` before changing anything.

## Commands

```sh
swift build                                  # debug build (all targets)
swift test                                   # 274 tests: protocol, device kit, app
bash Tests/Scripts/changelog-test.sh         # also release-test.sh, release-notes-test.sh
swift run Serpentine                         # the app, with the Terminal's permissions
swift run serpentine-cli battery             # hardware probes: info, battery, dpi, poll, stages, rgb, brightness
swift run Serpentine render-window [battery|settings] [zones] [light] [scrolled] [width] out.png
SERPENTINE_SNAPSHOTS=/tmp/snaps swift test --filter SnapshotTests   # every preview scene as PNG
./Scripts/build-app.sh                       # universal Serpentine.app, signed with the Apple Development cert
./Scripts/build-app.sh --adhoc               # the same, ad-hoc signed (what releases use)
```

## Rules that matter here

- **Look at UI changes before calling them done.** This shell can't screen-capture windows;
  `render-window` draws the real window offscreen (`render-ui` a single page). Check light and
  dark, and the widths 600, 1000 and 1400 (the dashboard has three layouts).
- **Nothing here has been tried on a mouse since the rename.** Hardware paths (`MouseController`,
  `RazerDeviceKit`, `OnboardButtons`, the F20 bridge) can only be verified on a Basilisk V4 Pro
  or Cobra HyperSpeed. Say so when a change touches them.
- **One coherent change per commit**, message in plain prose saying what changed and why (see
  `docs/claude/conventions.md`). The user asked for phases to be committed separately.
- **Ask before pushing, releasing, or anything outward-facing.** `Scripts/release.sh` and the
  Release workflow publish a version.
- **Keep the docs true** in the same commit: `CHANGELOG.md` (Unreleased), the file map in
  `docs/DOCUMENTATION.md`, and `docs/claude/` when architecture or decisions change.
- **Settings keys** are only ever named in `Preferences.swift`; a removed one goes into
  `LegacyPreferences.keys`. `PreferencesTests` pins their spellings.
- **Adding a mouse** touches `Sources/RazerProtocol/RazerDevices.swift` only; capabilities
  come from `DeviceCapabilities`, never from PID checks in the app.
