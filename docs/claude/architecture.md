# Architecture

## Targets

```
Package.swift
├── RazerProtocol      library     Pure: report framing, command builders and parsers, the BLE
│                                  translation, onboard button and slot tables, the device
│                                  registry, DeviceCapabilities, SettingResidency, RemapAction.
│                                  Foundation and CoreGraphics only. Public API.
├── RazerDeviceKit     library     Hardware: HIDDevice (IOKit), BluetoothDevice (CoreBluetooth),
│                                  RazerTransport + retry ladder, OnboardSlotTransport, HID
│                                  monitors, DeviceProbe. Depends on RazerProtocol.
├── Serpentine         executable  The app (AppKit + SwiftUI) and dev tools (render-*, icons).
└── SerpentineCLI      executable  `serpentine-cli`: hardware probes, no AppKit.

Tests: RazerProtocolTests (52), RazerDeviceKitTests (10), SerpentineTests (212, @testable app)
```

The app target is an executable, and its tests import it with `@testable`. That is why
`SerpentineTests` can reach internal types without a separate app library.

## From a click to the mouse

```
Tile (SwiftUI)  ──calls──▶  MouseController.setDPI(…)          main thread
                                   │
                                   ▼  io.user { … }            DeviceQueue: one serial queue,
                         ensureDevice() → any RazerTransport     user work ahead of polls
                                   │
                    RazerCommands.setDPI(x:y:) → RazerReport
                                   │
             HIDDevice.sendWithRetry  or  BluetoothDevice (BLEProtocol translates the report)
                                   │
                         read back where the mouse supports it
                                   │
                                   ▼  publish { … }            main thread: @Published update
                        Tile re-renders from controller state
```

- **`MouseController`** (an `ObservableObject`) holds the connected mouse's state as
  `@Published` values and does the work in feature files: `+Connection` (opening a link,
  USB vs Bluetooth, the device key), `+Reads` (the poll loop, settings reads, live checks),
  `+Writes`, `+Lighting`, `+Slots`, `+OnboardButtons`, `+Profiles`, `+Preview`. Published
  values have internal setters for those files; views only read them and call methods.
- **`DeviceQueue`**: every command runs on one serial `DispatchQueue`, in order. A user
  command (`io.user`) bumps a counter that background reads check between round trips
  (`userWorkPending`) so they stand down; writes never do. Why not an actor: decision D4.
- **Writes publish only on success** (`lastWriteFailure` lets sliders snap back). Lighting
  has no readback on most mice, so the controller is the source of truth for it.
- **`DeviceCapabilities`** (RazerProtocol) says what a mouse can do on its link, from the
  registry row and the link (`.usb`, `.bluetooth`). `controller.capabilities` derives it from
  the published `deviceID` and `deviceIsBluetooth`. Ask it rather than checking PIDs.
- **Transports**: `openTransport` prefers Bluetooth over an idle dongle, a cable over
  Bluetooth. Mice with onboard slots get an `OnboardSlotTransport`, which points every
  settings command at the active slot.
- **Device key**: the serial number, or the PID when there is none. Per-mouse data is keyed
  by it; a PID-keyed session is migrated to the serial when it resolves
  (`migratePerDeviceData`).

## Polling and connection

`BatteryPollStateMachine` is the pure decision core (offline debounce, garbage rejection,
charge confirmation, cadence). The controller does the I/O and acts on its verdicts. The
cadence is fast while settling, slower while connected (faster while the pointer moves), and
backs off while the mouse is away. `HIDMonitor` (plug/unplug), `HIDInputWatcher` (the mouse
moving while it reads offline) and the BLE monitor trigger immediate checks. While the main
window is open, `setLiveChecks(true)` re-reads the active slot and DPI every 2 s.

## Buttons

Three layers:

- **The remap table** (`ButtonRemapper.mappings`, `[Int: RemapAction]`, per device key):
  CGEvent button numbers, `HardwareButton` ids for controls macOS never sees, and HyperShift
  entries at `id + RemapCatalog.hyperShiftOffset`.
- **In the mouse** (`OnboardButtons`): on a mouse whose function table is known (today the
  Basilisk V4 Pro, `RazerDeviceInfo.buttonTable`), each remap the mouse can store is written
  into its table and read back; `OnboardOwnership` records what Serpentine wrote, so only
  those entries are ever put back. On connect, and when the mouse changes slot, the table is
  read and replaces the one shown (`OnboardButtons.adopt`). The sync is driven from
  `AppDelegate`: `remapper.$mappings` debounced 300 ms → `controller.setOnboardMappings`.
- **By the app** (`ButtonRemapper+EventTap`): a CGEvent tap acts on what the mouse can't
  store, and on every remap of a mouse whose table isn't known. Needs Accessibility. Paused
  while the mouse is offline (the tap can't tell which mouse clicked).

`RemapAction.residency(onButton:of:)` says which of the two a remap is.

## Persistence

- **UserDefaults**: every key named in `Preferences` (app-wide, and per device under
  `Preferences.Device`). Removed keys are cleaned by `LegacyPreferences`; the MacRazer
  domain is imported once by `LegacyInstall`.
- **Files** in `~/Library/Application Support/Serpentine/`: battery history, charge cycles,
  discharge curves (`VersionedFileStore`: atomic writes, a version envelope, throttled).
  `BatteryTracker` owns them on the device queue; `flushHistoryToDisk` on quit and sleep.
- **Per-mouse app data**: `DeviceSettings` (custom DPI, stages set aside in Single mode),
  `ProfileStore` and `SlotNames` (profiles), remaps (`ButtonRemapper+Persistence`).

## The app shell

- `main.swift`: no arguments → `LegacyInstall.migrate()`, then `NSApplication` with
  `AppDelegate` and the `.regular` policy. With arguments → dev tools (`render-ui`,
  `render-window`, `render-settings`, `icon`, `iconset`, `login-item`, …).
- **`AppDelegate`** wires everything: the controller, remapper, monitors, the onboard sync,
  `BackgroundMode`, `MenuBarItem`, `AppMenu`, `MainWindowController`, notifications.
  Closing the last window quits unless background mode is on; then the app switches to
  `.accessory` and the menu bar item remains. A login-item launch with background mode on
  starts without a window.
- **`MainWindowController`** builds one `NSWindow` (unified toolbar, full-size content,
  title-bar separator off, glass via `AppearanceSettings.track`) hosting `MainWindowView` in
  an `NSHostingController` whose `sceneBridgingOptions` bridge SwiftUI's title and toolbar.
  `hostWindow(_:)` is shared with `render-window`, so renders match the app.
- **`MainWindowView`**: a `NavigationStack` (path in `WindowNavigation`) with `Dashboard` at
  the root and `WindowRoute.battery` (Battery History) as the only detail. Toolbar, trailing:
  sync status, `ProfileMenu`, Refresh, the Settings cog. Sheets: Settings, setup
  (`PermissionsView`), Manage Profiles, the colour wheel. Each page is a `ScrollView`,
  clipped at the toolbar.
- **`Dashboard`**: `DeviceTile` across the top, then `Tile`s in a `Grid` and the Buttons
  column, laid out by `Dashboard.Layout` from the width (see ui-design.md).
- **Feature views** (`Features/`): `DPICard` (`inTile`), `PollingRateControls`,
  `LightingControls`, `PowerControls` (`parts`), `QuickProfiles`, the Bluetooth and no-mouse
  notices. They hold the control logic; tiles give them a frame and a heading.
- **`MenuBarItem`**: an `NSStatusItem` (the serpent, a bolt while charging, dimmed offline)
  whose menu is the mouse's status, Open and Quit. Only while background mode is on.

## Tools for looking without a screen

- `PreviewScene` (`render-ui`, `SnapshotTests`): each page in a preview state, from the
  controller's `setPreview…` fixtures (`MouseController+Preview`).
- `render-window`: the real window offscreen at any width, light or dark, optionally scrolled.
