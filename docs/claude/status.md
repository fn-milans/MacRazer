# Status

As of 2026-10-23, `main` at the commit that added this file. Version 0.0.0 in
`Packaging/Info.plist` (versioning restarted for Serpentine); everything below is in CHANGELOG's Unreleased section and has not been
released.

## Done in this round

1. **Rename** MacRazer → Serpentine: package, targets, bundle id `io.github.fn-milans.serpentine`,
   DMG, scripts, docs. `LegacyInstall` copies the old `com.macrazer.menubar` preferences and
   moves `Application Support/MacRazer` on first launch. Credits to SorcRR stay.
2. **Icons**: Health Icons' `animal-snake` (MIT) for the app and the menu bar, drawn from its
   SVG path (`SVGPath`, `MenuBarIcon.serpentPathData`). A stand-in; the user may replace it.
3. **Refactor**, in phases 0-8: `RazerProtocol` and
   `RazerDeviceKit` libraries, `serpentine-cli`, `DeviceCapabilities`, `SettingResidency`,
   `Preferences`, `DeviceQueue`, `BatteryTracker`, the controller and remapper split into
   feature files, feature views in `Features/`, snapshot tests.
4. **Windowed app**, in phases W1-W5, then redesigned
   with the user over several rounds into the current dashboard (see
   [ui-design.md](ui-design.md) and decisions D10-D17).

## Never run on a mouse

All of the above passed `swift test` (274 tests), the script tests, and the universal release
build, and the UI was checked in offscreen renders. **None of it has been run against real
hardware.** Before the next release, on a Basilisk V4 Pro and a Cobra HyperSpeed, over the
dongle and over Bluetooth:

- connecting, sleeping and waking, unplugging the dongle, switching to Bluetooth;
- DPI (both modes on the V4 Pro, stages and custom on the Cobra), polling, lighting incl.
  zones, sleep timer, low-battery level, Smart-Reel and acceleration;
- onboard slots: switch from the title bar and from a Cycle Profile button on the mouse,
  add, rename, reset, delete (Manage Profiles…);
- remaps written into the mouse, the HyperShift layer, reading them back on connect;
- software remaps and the event tap on the Cobra; the Basilisk V3 X's DPI Cycle F20 bridge;
- the MacRazer → Serpentine migration on a Mac that ran MacRazer;
- background mode: closing the window, the menu bar item, the one-time question;
- **launch at login starting without a window**: it relies on `keyAELaunchedAsLogInItem`
  being set for `SMAppService` launches, which was not confirmed.

## Known gaps and next steps

- **Observation for `MouseController`, `ButtonRemapper`, `AppearanceSettings`.** Still
  `ObservableObject` because ~10 Combine pipelines (debounces, `combineLatest`) drive the
  onboard remap sync and the F20 bridge (`AppDelegate`, `ButtonRemapper+DpiCycle`). Move them
  with a mouse on the desk to check the timing. See decision D6.
- **Services instead of feature files.** `MouseController` is split into `+Reads`,
  `+Writes`, … extensions sharing state. Separate service objects were deferred (D5); revisit
  if a feature grows its own state.
- **The Buttons column** hosts the existing `RemapView` (a list built for the popover). A
  drawing of the mouse with callouts per button was in the original design and would read
  better in a 400 pt column.
- **Battery history in the background**: history is only recorded while the app runs. With
  background mode off it has gaps; the battery tile could say so.
- **Preview data**: `render-window zones` shows "Couldn't read the profiles" because the V4 Pro
  preview has no slots loaded. Give `setPreviewZonedLighting` slots if that matters.
- **About** is still the small glass window; it could become the standard About panel.
- **Release**: when it's time, `./Scripts/release.sh 0.1.0`, review, commit, then run the
  Release workflow (Actions → Release). See [workflows.md](workflows.md).
