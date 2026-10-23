# Decisions

Each entry: what was decided, why, and what was ruled out. Numbered so other notes can point
at them. Newest at the bottom. If you reverse one, add an entry saying so rather than editing
history.

## Product

**D1. The mouse keeps the settings; the app is for what it can't.** Every setting the mouse
can store is written to it (onboard memory, the active slot), so it works with Serpentine
closed, on any link and on other computers. Driver-mode features (remaps the mouse can't
store, the DPI Cycle F20 bridge, low-battery alerts, battery history) only work while the
app runs. Everything in the UI that has a setting says which kind it is (`SettingResidency`).

**D2. Renamed from MacRazer, with a new bundle id.** `io.github.fn-milans.serpentine`
(the user's GitHub, reverse-DNS). A new id loses UserDefaults and TCC grants, so
`LegacyInstall` copies the old `com.macrazer.menubar` domain (never overwriting newer
values, never importing `launchAtLoginDefaultApplied`) and moves `Application Support/MacRazer`.
Permissions must be granted again; that can't be migrated. MacRazer stays only where it
credits SorcRR (README, About, NOTICE, the BLE protocol note). The PR to SorcRR/MacRazer from
`feat/basilisk-v4-pro` is kept as it is.

## Code structure

**D3. Two libraries, the app, and a CLI.** `RazerProtocol` (pure) and `RazerDeviceKit`
(hardware) so the protocol is testable without AppKit and the layers can't reach into each
other; `serpentine-cli` so the probes need no AppKit. The app stays an executable target
tested with `@testable` rather than splitting out an app library, which SwiftPM allows on
macOS and which kept the move mechanical.

**D4. The device queue is a serial `DispatchQueue`, not an actor.** The mouse needs commands
in the order they were sent; actor jobs aren't FIFO. The transports block (Bluetooth waits on
a semaphore), which must not happen on the shared cooperative pool. A custom serial executor
would fix the second but not the first. `DeviceQueue` wraps the queue and the "user work goes
first" counter.

**D5. `MouseController` is split into feature files, not service objects.** The open
device, its serial, the slot state and the onboard sync state are shared by every feature;
separate services would mostly pass them around. The state is declared in
`MouseController.swift`; `+Reads`, `+Writes`, … hold the work. Pulled out where something was
self-contained: `DeviceQueue`, `BatteryTracker`. Same for `ButtonRemapper`.

**D6. `MouseController`, `ButtonRemapper`, `AppearanceSettings` stay `ObservableObject`.**
About ten Combine pipelines (debounce, `combineLatest`) drive the onboard remap sync and the
F20 bridge off `@Published` timing; Observation has no publishers to replace them, and the
timing can only be checked on hardware. `LaunchAtLogin` and `PermissionsModel` are
`@Observable`.

**D7. Capabilities and residency live in `RazerProtocol`.** "No polling over Bluetooth", "wheel
settings USB only" and "which remaps the mouse can store" are protocol facts, so
`DeviceCapabilities` and `RemapAction.residency` are there, tested in `RazerProtocolTests`.

**D8. One list of settings keys.** `Preferences` names every UserDefaults key;
`PreferencesTests` pins the spellings (a rename would silently drop a setting for everyone);
removed keys go to `LegacyPreferences.keys`, which deletes them on launch.

**D9. The icon is Health Icons' `animal-snake`, drawn from its SVG path.** The user picked it
as a stand-in (MIT, credited in NOTICE and About). `SVGPath` parses path data into a `CGPath`,
so the menu bar mark stays a template image and the charging variant keeps its dynamic colours.
Replacing it: change `MenuBarIcon.serpentPathData`, run `Scripts/make-icon.sh`. The Razer
triskelion was removed from every drawing.

## The window

**D10. AppKit hosts SwiftUI; no SwiftUI `App` lifecycle.** `AppDelegate` owns an `NSWindow`
with an `NSHostingController` (title and toolbar bridged). It keeps the dev commands in
`main.swift`, lets the activation policy switch directly (`.regular` ↔ `.accessory`), and
`render-window` can build the exact same window.

**D11. Background mode.** Off on a new install: most people set the mouse up and quit. On, once,
for anyone upgrading from the menu bar version (a battery reading or the old login-item flag in
the defaults), so their menu bar item doesn't vanish. It never turns itself on; the first time
a driver-mode feature is set up the app asks once, listing what needs it. Start at login only
exists with background mode, and a login launch starts without a window.

**D12. The menu bar item is an `NSStatusItem`, glyph only.** Not `MenuBarExtra`: the charging
icon resolves its colours at draw time, which needs `NSStatusItem` (and nothing may watch
`effectiveAppearance`, issue #25). No battery percentage (the user's call). Its menu: the
mouse's status, Open, Quit; everything else is in the window.

**D13. A dashboard of tiles.** The window went through three shapes with the user: a sidebar
of sections (too fragmented, and its split view drew a black frame), the popover's cards
stacked in one column (the menu bar app moved into a window), then a dashboard: the mouse
across the top and a tile per setting. Each tile is one setting, its value large, its controls
under it.

**D14. Title bar: title left, everything else right.** The window buttons and the title (or
the back button and the detail's title) at the leading edge; status, profiles, Refresh,
Settings at the trailing edge (HIG toolbar layout). No centred tabs.

**D15. Buttons are a third column, and the layout follows the width.** Behind a tile they
were too hard to find. At ≥1180 pt: two tile columns and the 400 pt Buttons column; ≥820:
one of each; below: a single column, Buttons last. Window minimum 560 pt.

**D16. Profiles are a title bar menu: switch, and Manage Profiles….** The Profiles tile went
into the header. Adding, renaming, resetting and deleting happen in the Manage sheet; the
menu doesn't repeat them. Manage is always there, so the first profile can be made.

**D17. Settings is a sheet behind a cog.** No Settings window, no Settings tab. About stays a
small window.

**D18. Content doesn't scroll under the title bar.** Full-size content is kept (turning it
off pushed the toolbar items onto a second row); each page's `ScrollView` is `.clipped()` at
the toolbar.

**D19. The popover's glass, everywhere.** The window and About use `WindowBackdrop` (the
popover material, or a solid colour per Settings › Appearance); tiles are a light fill and a
hairline on top. System materials, no custom blur.

**D20. UI is checked by rendering, not by screenshots.** This environment can't capture
windows (no Screen Recording grant), and AppleScript UI scripting hangs on a permission prompt.
`render-window` and `render-ui` draw the real views offscreen; snapshot tests render every
preview scene.
