# Serpentine refactor plan

Written 2026-10-23, right after the rename from MacRazer. The code grew feature by feature on
top of a menu bar prototype and never had a structural plan. This is that plan. It is ordered
so every phase ships on its own, keeps the 260 tests green, and leaves the app working.

It is written to support the move to a windowed app ([WINDOWED_APP.md](WINDOWED_APP.md)): the
phases marked **(W)** are the ones that move first because the window depends on them.

## Status (2026-10-23)

All eight phases have been through once, on the `refactor` branch, one commit each. Where
the result differs from the plan below, it says so here.

| Phase | Done | Differs from the plan |
|---|---|---|
| 0 Hygiene | Razer mark gone from the drawings, stale comments fixed, `Preferences` lists every key | — |
| 1 `RazerProtocol` | Library with tests; also holds `RemapAction`, the catalog, `RazerError`, `LightingEffect` | `OnboardOwnership` (UserDefaults) stayed in the app |
| 2 `RazerDeviceKit` | Library with tests; includes the slot transport | — |
| 3 Capabilities | `DeviceCapabilities`, `DeviceSettings`, `SettingResidency` (in `RazerProtocol`) | `DeviceSettings` covers the custom DPI and Single-mode stages; profiles, slot names and remaps keep their own stores |
| 4 Split the controller | `DeviceQueue`, `BatteryTracker`, and the rest split by feature into `MouseController+*.swift` | Feature files, not separate service objects: the device, its serial and the slot state are shared by every feature, so separate services would only pass them around. Services can follow once the window decides what each pane needs |
| 5 Concurrency | `LaunchAtLogin`, `PermissionsModel` on Observation | The serial queue stays (see the phase), and `MouseController`/`ButtonRemapper` stay `ObservableObject` until W2 |
| 6 UI split | `Features/` views, `Appearance*` renames, `ButtonRemapper+*.swift` | `ButtonRemapper` is split by file rather than into model and engine types, for the same reason as phase 4 |
| 7 CLI | `serpentine-cli`, `PreviewScene`, snapshot tests | The `render-*` commands stay alongside the tests: they are how a person looks at a change |
| 8 Docs | File map, contributing, this table | — |

None of it was tried against a mouse: every phase kept `swift test` and the release build
green, and the popover renders the same, byte for byte, but the hardware paths need a pass on
a Basilisk V4 Pro and a Cobra HyperSpeed before this is merged.

## Where the code was (before the refactor)

One executable target, `Sources/Serpentine`, 49 files, about 14,000 lines. The tests import it
with `@testable`.

| Area | Files | What's wrong with it |
|---|---|---|
| `MouseController.swift` | 2,453 lines | Everything about a connected mouse: transport, polling, battery history, DPI, lighting, onboard profiles and slots, onboard button remaps, Bluetooth recovery, wake recovery, sounds, preview fixtures. About 60 `@Published` properties. A change to lighting means reading past battery polling. |
| `PopoverView.swift` | 1,619 lines | The whole main UI in one view with ~20 `@State` values, page navigation by enum, and popover sizing tricks (`HeightKey`, `subPageMinHeight`). None of it is reusable in a window as it stands. |
| `ButtonRemapper.swift` | 831 lines | Three jobs: the remap data model, the CGEvent tap engine, and the onboard (in-mouse) remap planning, plus the DPI Cycle F20 bridge. |
| `main.swift` | 503 lines | App entry point, a hardware CLI (battery, dpi, poll, rgb…), the icon renderer, and the `render-*` screenshot commands, in one top-level `switch`. |
| `AppDelegate.swift` | 474 lines | Status item, popover, the right-click menu, focus hand-back after the popover closes, window presentation, notifications. Mostly menu bar mechanics that go away with the window. |
| Concurrency | — | A private GCD `io` queue, a lock-counted "user work" priority scheme, manual hops to main via `publish`, and ten `@unchecked Sendable` types. It works and is tested, but Swift 6 can't check any of it. |
| Settings | 11 files | `UserDefaults` read with string-literal keys in eleven files (`"showPercentInMenuBar"`, `"buttonMappings-\(key)"`, …). No single list of what the app stores. |
| Capabilities | everywhere | "Can this mouse do X" is answered ad hoc: `deviceIsBluetooth`, `RazerDevices.supportsX(pid:)`, `lightingZones.isEmpty`, `activeOnboardSlot != nil`, scattered over the controller and the views. |
| Test hooks in production | `MouseController` | `setPreviewOffline()`, `setPreviewBluetooth()`, `runUserCommandForTesting` and friends live on the real class. |
| Naming | — | `AppearanceTheme`, `AppearanceLook`, `PopoverFocusReturn`, `PopoverBackdropView`, `setPopoverVisible` — names that will be wrong once the main UI is a window. |
| Stale text | — | Comments still describe the removed updater (`AppWindows.swift` explains itself through "an automatic update install"), and the icon carries a Razer triskelion cut-out, which a project that says it is not affiliated with Razer shouldn't ship. |

What is in good shape and should be kept as is: the protocol layer (`RazerReport`,
`RazerCommands`, `BLEProtocol`, `OnboardButtons`, `OnboardSlots`) is pure and well tested;
`BatteryPollStateMachine`, `DischargeCurveModel` and `VersionedFileStore` are small and
focused; the device registry (`RazerDevices`) is the right idea.

## Where it should end up

```
Package.swift
├── RazerProtocol      library  Pure encoding/decoding. No AppKit, no IOKit. Foundation only.
│     RazerReport, RazerCommands, BLEProtocol, OnboardButtons, OnboardSlots (encoding part),
│     LightingZones, HardwareButtons, RazerDevices (registry + Capabilities)
├── RazerDeviceKit     library  Talking to hardware.
│     RazerTransport, HIDDevice, HIDDeviceSelection, HIDMonitor, HIDInputWatcher,
│     BluetoothDevice, RazerRetry, DeviceProbe
├── SerpentineCore     library  App logic with no UI.
│     DeviceSession (actor), feature services, stores, Preferences, LegacyInstall,
│     RemapEngine (event tap), LowBatteryNotifier, LaunchAtLogin
├── SerpentineUI       library  SwiftUI views and view models, one folder per feature.
├── Serpentine         executable  The app: scenes, menu bar extra, AppKit glue. Small.
└── serpentine-cli     executable  Hardware diagnostics (battery, dpi, poll, rgb, …).
```

Tests split to match: `RazerProtocolTests`, `SerpentineCoreTests`, `SerpentineUITests`
(render/snapshot tests that replace the `render-*` commands).

Why modules and not just folders: access control. Today any view can reach into any part of
the controller; with modules the compiler keeps the layers apart, and `RazerProtocol` can be
tested in milliseconds without a run loop.

### The device model

`MouseController` becomes a thin facade first, then disappears:

- **`DeviceSession`** (an `actor`): owns the open transport and serialises every command.
  Replaces the `io` queue, the `userWork` lock and counter (user commands go first; polls
  yield), and the `@unchecked Sendable`.
- **`DeviceCapabilities`** (a struct, computed once per connection from the registry and the
  link): `hasBattery`, `lightingZones`, `maxDPI`, `supportsPollRate`, `supportsDpiStages`,
  `onboardSlots`, `onboardButtonTable`, `link` (`.dongle`, `.wired`, `.bluetooth`). Views and
  services ask this, not the PID.
- **Feature services**, each an `@Observable @MainActor` model that talks to the session:
  `BatteryService` (poll state machine, history, estimate, low-battery alert),
  `PerformanceService` (DPI, stages, polling rate), `LightingService`, `PowerService` (sleep
  timer, low-battery level), `ScrollService` (wheel mode, Smart-Reel, acceleration),
  `ProfilesService` (onboard slots and saved profiles), `ButtonsService` (onboard remaps; the
  software tap stays in `RemapEngine`), `ConnectionService` (HID and Bluetooth monitoring,
  wake recovery).
- **`SettingResidency`**: every setting declares where it lives, `.mouse` (written to onboard
  memory, works with Serpentine closed) or `.app` (driver mode: only while Serpentine runs).
  This is the product's whole point, so it belongs in the model, and the UI shows it.

### Settings

One `Preferences` type with typed keys, and a `DeviceSettings` store keyed by `DeviceKey`
(serial, or PID when there is none) for everything per mouse: custom DPI, remaps, profiles,
names. `LegacyPreferences` and `LegacyInstall` keep reading the old keys and are the only
place allowed string literals.

## Phases

Each phase is one PR. "Size" is a rough guess at review effort.

### Phase 0: hygiene (S)
- Rewrite comments that describe removed features (updater, crash reports, device test).
- Remove the Razer triskelion from the drawn marks and replace the app and menu bar icons
  (see [the icon section of WINDOWED_APP.md](WINDOWED_APP.md#icons)).
- Delete the `appicon` concepts command; keep `iconset`.
- Collect every `UserDefaults` key into `Preferences` (keys only, same storage), so the next
  phases can see what they're moving.

### Phase 1: `RazerProtocol` module (M, mechanical) **(W)**
Move the pure protocol files into a library target and make their API `public`. No behaviour
change; the protocol tests move with them. This is the lowest-risk, highest-value split: it
draws the line everything else depends on.

### Phase 2: `RazerDeviceKit` module (M) **(W)**
Move the transports and monitors. `MouseController` imports it. `DeviceProbe` and the CLI
commands use only this and `RazerProtocol`, which makes Phase 7 easy.

### Phase 3: capabilities and preferences (M) **(W)**
Introduce `DeviceCapabilities` and route every "supports" question through it. Introduce
`DeviceSettings`. Add `SettingResidency` to every setting. Tests: a capabilities table test
per registered mouse (what the README's support table claims, checked by code).

### Phase 4: split `MouseController` behind a facade (L) **(W)**
Extract the feature services one at a time, battery first (it's the most self-contained, and
`BatteryPollStateMachine` is already separate), then performance, lighting, power/scroll,
profiles, buttons. `MouseController` keeps forwarding so the popover keeps working during the
transition. Move preview fixtures into a `PreviewDevice` that conforms to the same protocol,
out of the production class.

### Phase 5: actor IO and Observation (L)
Replace the `io` queue with `DeviceSession`, `publish` with `@MainActor` services, and
`ObservableObject`/`@Published` with `@Observable` (macOS 14 has it). Remove the ten
`@unchecked Sendable`. Turn on complete strict concurrency checking, which Swift 6 mode
already implies, and fix what it reports. `RazerRetry` becomes `async` with `Task.sleep`.

**Outcome (2026-10-23).** Done in part, on purpose:
- The device queue stays a serial `DispatchQueue` (`DeviceQueue`). An actor would lose the
  one guarantee the mouse needs: commands run in the order they were sent. Jobs on an actor
  are not run first-in first-out, and the transports block (a Bluetooth request waits on a
  semaphore), which an actor on the shared thread pool must not do. A custom serial executor
  would fix the second problem but not the first.
- `LaunchAtLogin` and `PermissionsModel` are `@Observable` and `@MainActor`.
- `MouseController`, `ButtonRemapper` and `AppearanceSettings` stay `ObservableObject`: about
  ten Combine pipelines (debounces, `combineLatest`) drive the onboard remap sync and the
  DPI Cycle bridge off `@Published`'s timing, and Observation has no publishers to replace
  them with. Moving them is worth doing with the window work (W2), where those views are
  rebuilt anyway, and with a mouse on the desk to check the bridge.
- Swift 6 language mode already checks concurrency completely; the remaining
  `@unchecked Sendable` types are the ones guarded by a queue or a lock.

### Phase 6: UI split (L) **(W)**
Break `PopoverView` into one view per feature (`BatteryView`, `DPIView`, `LightingView`, …)
that take a service, not the controller. These are the panes of the window. Rename
`Popover*` theme types to `Appearance*`. Split `ButtonRemapper` into `RemapModel` (data),
`RemapEngine` (event tap) and the onboard planning that already lives in `OnboardButtons`.

### Phase 7: CLI target (S)
Move the hardware commands to `serpentine-cli`. Replace `render-*` with snapshot tests in
`SerpentineUITests` that write PNGs to a temp folder on demand (`SERPENTINE_SNAPSHOTS=1`).
`main.swift` in the app shrinks to the `@main` App.

### Phase 8: docs (S)
Update the file map in `docs/DOCUMENTATION.md` and `CONTRIBUTING.md` (adding a mouse should
touch `RazerDevices` and nothing else; say so and check it).

## Order and dependencies

```
0 ─► 1 ─► 2 ─► 3 ─► 4 ─► 6 ─► (window work)
                     └─► 5 (can run alongside 6)
               7 after 2;  8 last
```

Phases 1–4 and 6 are on the critical path to the window. Phase 5 is valuable but not
blocking: it can follow the window if time is short.

## Rules while refactoring

- One behaviour-preserving PR at a time; no feature work mixed in.
- Every PR keeps `swift test` and `Tests/Scripts/*` green, and is tried against a real mouse
  (Basilisk V4 Pro and Cobra HyperSpeed at least), since half of this code only fails on
  hardware.
- Keep migrations (`LegacyInstall`, `LegacyPreferences`, the per-device key migration) working
  and tested; users carry data across all of these.
