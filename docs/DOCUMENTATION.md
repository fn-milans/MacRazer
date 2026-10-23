# Serpentine: Documentation

A native macOS app to control Razer mice: battery, DPI, polling rate, RGB lighting,
brightness, power, profiles and button remapping, written into the mouse wherever it can keep
them. Razer's Synapse does not support macOS, so this
app talks to the mouse directly over USB HID. Four models have been verified on real
hardware: the Razer Cobra HyperSpeed (the development mouse), the Razer Atheris, the Razer
Basilisk V3 X HyperSpeed and the Razer Viper Ultimate. By design it detects and tries to
control any Razer mouse in the same protocol family; the registry carries twelve product ids,
and README's table says which of them anyone has actually run the probes against.

This document explains how the app is built and how every feature works, so a future Claude
session or a human can pick it up cold. See also:
- [`BRIEF.md`](BRIEF.md), the original research/planning brief and device facts.
- [`../CHANGELOG.md`](../CHANGELOG.md), feature list / history.
- [`../README.md`](../README.md), quick status + build commands.

---

## 1. Overview & how it works at a glance

The mouse speaks Razer's proprietary HID protocol. We did **not** reverse-engineer it from
scratch, we **ported the protocol from OpenRazer's Linux driver** (the Cobra Pro command
set, which the Cobra HyperSpeed reuses). All command bytes were read from the OpenRazer C
source and reimplemented in Swift over Apple's IOKit HID Manager. No kernel extension is
required: Razer mice respond to standard USB HID **feature reports** that any HID-capable
userspace process can send.

```
Razer mouse  <-- HID feature reports (90-byte razer_report) -->  HIDDevice (IOKit)
                                                                       |
                                                  RazerCommands (builds the command bytes)
                                                                       |
                                                  MouseController (poll loop, battery, state)
                                                                       |
                                                  SwiftUI window (+ menu bar item in background mode)
```

The app is a SwiftPM **executable** (not an Xcode project). With **no arguments** it launches
the app; with a subcommand it runs a development tool (render-*, icons). The hardware
diagnostics are a separate executable, `serpentine-cli` (see §9).

---

## 2. Quick start

Requires macOS 14+ (Apple Silicon), Xcode 16 / Swift 6.1.

```sh
# Develop (inherits your Terminal's permission grants, easiest loop):
swift run Serpentine

# Build a standalone .app:
./Scripts/setup-signing.sh # one-time: stable self-signed identity (see §7)
./Scripts/build-app.sh # to "Serpentine.app"
open "Serpentine.app"
```

**Permissions** (see §7): the app needs **Input Monitoring** (to send/receive HID reports)
and, for button remapping, **Accessibility** (for the event tap). Both are requested in-app.

---

## 3. The HID protocol (ported from OpenRazer)

### 3.1 The wire format, `razer_report` (90 bytes)
Every command is a fixed 90-byte structure sent as a HID **feature report, report id 0**.
Ported in [`RazerReport.swift`](../Sources/Serpentine/RazerReport.swift):

| Offset | Field | Notes |
|---|---|---|
| 0 | status | response: `0x02` success, `0x01` busy, `0x03` failure, `0x04` timeout |
| 1 | transaction_id | **`0x1f` for all Cobra Pro/HyperSpeed commands** |
| 2-3 | remaining_packets | big-endian, usually 0 |
| 4 | protocol_type | 0 |
| 5 | data_size | size of the arguments used |
| 6 | command_class | |
| 7 | command_id | direction bit: get = `0x80\|id` |
| 8-87 | arguments[80] | |
| 88 | crc | XOR of bytes 2..87 |
| 89 | reserved | 0 |

### 3.2 Request/response timing (critical)
`HIDDevice.send()` sends the request (SetReport), waits, then reads the response (GetReport). The wait is
**31 ms** (`RAZER_NEW_MOUSE_RECEIVER_WAIT_US` in OpenRazer). Too short a wait returns status
`0x01` (BUSY) with empty arguments. On BUSY we re-read a few times.

### 3.3 Command reference (verified on hardware)
Built in [`RazerCommands.swift`](../Sources/Serpentine/RazerCommands.swift). VID `0x1532`.

| Operation | class / id | data_size | Notes |
|---|---|---|---|
| Get battery | `0x07` / `0x80` | `0x02` | response `args[1]` is 0-255; `* 100 / 255` gives the %. |
| Get charging | `0x07` / `0x84` | `0x02` | response `args[1]` != 0 = charging. |
| Get / Set DPI | `0x04` / `0x85` / `0x05` | `0x07` | VARSTORE + big-endian x/y; clamp **100-50000** (arbitrary DPI). |
| Get / Set poll | `0x00` / `0x85` / `0x05` | `0x01` | 1000->`0x01`, 500->`0x02`, 125->`0x08` (basic set only). |
| Lighting effect | `0x0F` / `0x02` | varies | extended-matrix on **ZERO_LED (0x00)**; effect ids: none `0x00`, static `0x01`, spectrum `0x03`, wave `0x04`. |
| Get / Set brightness | `0x0F` / `0x84` / `0x04` | `0x03` | value 0-255. LED group is **per model** (`RazerDevices.brightnessLed`), never ZERO_LED — see quirk below. |

### 3.4 Hardware quirks (discovered by testing, important!)
- **Battery works over the 2.4 GHz dongle.** The OpenRazer PR author thought it didn't; the
 real fix was the 31 ms wait + targeting the correct interface.
- **Brightness lives on a different LED group than effects, and which one is per model.**
 Colors/effects are driven on ZERO_LED for every model so far, but brightness is not: the
 Cobra family answers only on `LOGO_LED` (0x04), while the Basilisk V3 X HyperSpeed — whose
 only lit zone is the scroll wheel — answers only on `SCROLL_LED` (0x01). Every other group
 returns status `0x03` (failure), so a wrong id is not a silent no-op: the brightness slider
 simply stops working. The id is a registry field (`RazerDevices.brightnessLed`, default
 `LOGO_LED`); `swift run serpentine-cli brightness` sweeps all four groups to find it on a new
 model. Both verified live.
- **Lighting is one group.** The "4 zones" in marketing aren't independently addressable;
 everything is driven together via ZERO_LED.
- **Transient garbage on reconnect.** Right after a USB reconnect the battery can read 0x00
 (0%) or 0xFF (100%) before settling. The controller distrusts these (see §5.1).
- **Two product IDs:** `0x00DA` (wired) and `0x00DB` (wireless dongle).

---

## 4. IOKit HID layer

### `HIDDevice.swift`
- `matchingDevices(vendorId:)` enumerates all HID interfaces for a vendor **without opening
 the manager** (opening the manager grabs the keyboard/mouse interfaces and yields
 `kIOReturnNotOpen` on SetReport, a bug we hit and fixed).
- `open(vendorId:)` picks the **control interface** by score: it must carry a 90-byte feature
 report (`MaxFeatureReportSize >= 90`); we prefer a vendor usage page and the Mouse usage
 (`0x01`/`0x02`) so we don't grab a connected Razer keyboard. Exposes the device's
 `productID` and `productName` (from the USB product string).
- `send()` / `sendWithRetry()` implement the request/response with the 31 ms wait, BUSY
 re-reads, and retry/backoff for the finicky wireless link.

### `HIDMonitor.swift`
IOKit **service** notifications (`IOServiceAddMatchingNotification`, matched + terminated)
for instant USB plug/unplug detection. It does **not** open the device, so it can't
interfere with the control-interface open. Fires `onAppear` / `onRemove` callbacks on the
main queue. (Polling, §5, is the fallback for the wireless-sleep case where the dongle stays
plugged in.)

### Bluetooth LE: `BLEProtocol.swift` + `BluetoothDevice.swift`
Over Bluetooth the mouse is a plain HID pointer (feature report size 1, no control
interface). Razer's control protocol lives in a separate **vendor GATT service**
(`52401523-F97C-7F90-0E7F-6C6F4E36DB1C`), reverse-engineered by @ungrav in #32 and confirmed
on the Cobra HyperSpeed (Bluetooth PID `0x00DC`, vendor `0x068E`).

- **Framing.** A request is a header `[id, payloadLength, 0, 0, class, command, arg, arg]`
 written to `…1524`, then the payload in 20-byte writes. The reply arrives as notifications
 on `…1525`: a header `[id, length, 0, 0, 0, 0, 0, status]` (status `02` ok, `03` failure,
 `05` not supported) followed by `length` payload bytes. The mouse also sends an
 unsolicited `01 … 03` frame when notifications are enabled, which the assembler skips.
- **Commands (verified on the Cobra HyperSpeed):** battery `05 81 00 01` (0-255, same scale
 as USB), serial `01 83 00 00` (the same serial as over the dongle), DPI stages get/set
 `0B 84 01 00` / `0B 04 01 00`, brightness get/set `10 85 01 <led>` / `10 05 01 <led>` (LOGO
 `04` on the Cobra, like USB), static colour `10 04 00 00`.
- **Stage table.** `[activeID, count]` then per stage `[id, x_lo, x_hi, y_lo, y_hi, 0, 0]`,
 ids from 1, little-endian. Replies drop the last reserved byte. There is no direct "set
 DPI", so selecting a DPI rewrites the table with a new active stage, then reads it back.
- `BLEProtocol` translates `RazerReport` requests and replies, so `MouseController` and the
 `RazerCommands` parsers are shared with USB. Commands without a BLE equivalent (polling
 rate, effects other than static) throw `notSupported`, and the window hides them.
- **Link choice** (`MouseController.openTransport`): a cable wins. An idle dongle loses to a
 supported mouse on Bluetooth, because the mouse is on one wireless link at a time and the
 dongle would only time out. Detection runs on IOHID (`HIDDevice.bluetoothRazerMouse`), so
 CoreBluetooth and its permission prompt only appear for someone who has such a mouse.

---

## 5. The controller, `MouseController.swift`

The orchestrator and single source of UI truth (an `ObservableObject`). All blocking HID IO
runs on one serial queue (`DeviceQueue`), in order, with what the user asked for ahead of
background reads; `@Published` state is updated on the main queue via `publish`. The work is
split by feature into `MouseController+*.swift`; battery history lives in `BatteryTracker`.
What a mouse can do on its link is `capabilities` (`DeviceCapabilities`).

Published state: `connected`, `batteryPercent`, `charging`, `dpi`, `pollRate`, `brightness`,
`timeEstimate`, `statusText`, `deviceName`, `deviceSupported`, `deviceHasBattery`,
`isRefreshing`, `showPercentInMenuBar`.

### 5.1 Polling & connection logic
- **Adaptive self-rescheduling poll**: every **15 s when connected, 4 s when offline / not
 yet ready**, so disconnects show within ~15 s and reconnects within ~4 s, all without a
 manual refresh.
- **Instant plug/unplug** via `HIDMonitor` to `forceCheck()` (USB removal is definitive, so it
 marks offline immediately, bypassing the debounce).
- **2-failure debounce**: a single transient wireless timeout won't flap the UI to "offline".
- **Reconnect sanity checks** (fixes the 0%/100% jumps): a raw `0` reading is treated as
 "not ready" (keep last value, re-poll fast); and the first post-reconnect reading is
 rejected if it jumps >20% from the last trusted value (transient garbage) until confirmed.
- **Battery-less mice**: if `deviceHasBattery` is false (registry), a successful DPI read is
 the alive-check instead of a battery read, and the battery UI is hidden.

### 5.2 Connect/disconnect sounds
On a connection-state transition (after the first baseline poll), plays a system sound:
**Pop** on connect, **Submarine** on disconnect (`NSSound`, names are constants).

### 5.3 Writes
`setDPI`, `setPollRate`, `setBrightness`, `setStatic/Spectrum/Wave/LightingOff`, each
dispatches a command on the device queue and publishes the new value once the mouse took it.
While the main window is open, `setLiveChecks(true)` re-reads what a button on the mouse
changes (the active slot and the DPI) every 2 s, so it shows at once.

### `BatteryHistory.swift`, time-until-empty estimate
- Logs `(timestamp, %)` samples to `~/Library/Application Support/Serpentine/battery-history.json`.
- Computes a discharge rate by **linear least-squares fit** over samples (needs >=5 samples,
 >=30 min span, >=3% measured drop before it's trusted, otherwise the coarse reading is
 noise and the estimate drifts).
- Persists a **learned discharge rate** (`learnedDischargeRate` in UserDefaults), blended
 (EMA) across sessions and charge cycles, so after a restart/recharge the estimate is
 available **immediately** instead of re-deriving for ~3 hours.
- The estimate is always labelled "(est.)".

### `RazerDevices.swift`, device registry
Maps PID to a `RazerDeviceInfo` row: name, support flags, protocol quirks and capabilities
(§8). The connected device's **name comes from
its own USB product string** (works for any Razer mouse); the registry only adds the
"controls verified" flag (Cobra family) and the battery flag. Unknown mice show their name +
"limited support". This is the extension point for universal support (see §8).

---

## 6. The UI

### 6.1 The window, `Window/`
A normal Mac app (Dock icon, menus), one main window (`MainWindowController`, frame
remembered) on the popover's glass (`AppearanceSettings.track`). The title bar follows the
HIG's layout: the window buttons and the title (or a back button and the detail's title) at
the leading edge; the status mark (whether the mouse holds what was set), the profile menu,
Refresh (⌘R) and the Settings cog (⌘,) at the trailing edge.

- **Dashboard** (`Dashboard.swift`): the mouse across the top (`DeviceTile`: the model, its
 link, the battery as a ring, the time left and Battery History), then a tile per setting the
 mouse has (DPI, polling rate, lighting, sleep, low battery, scroll wheel) and the
 **Buttons** column (`RemapView`, unfolded). A `Tile` has a coloured symbol, the name, where
 the setting lives (`ResidencyMark`), the value large, and the controls (the feature views in
 `Features/`). Offline the tiles stay, dimmed, with the last known values.
- **Responsive** (`Dashboard.Layout`, from the width): at 1180 pt and up, two columns of tiles
 and the buttons column (400 pt); from 820, one column of tiles and the buttons column; below
 that, one column with the buttons last and the battery under the mouse's name. The window
 goes down to 560 pt wide. The page's scroll view is clipped at the toolbar, so content never
 slides beneath the title bar (`render-window … scrolled` shows it).
- **Battery History** opens from the mouse's tile in place, with a back button
 (`NavigationStack`, `WindowRoute`). The colour wheel opens as a sheet.
- **Profiles** are in the title bar (`ProfileMenu`): the one in use is the label; the menu
 switches, and Manage Profiles… opens a sheet to add (a new slot, or the current setup saved),
 rename, reset to factory (slots) and delete. A failed apply turns the status mark into a
 warning.
- **Settings** (`SettingsView`, from the cog): background mode, start at login, connection
 sounds, theme and glass, in a sheet.
- **Setup**: Input Monitoring and Accessibility in a sheet (`PermissionsView`), opened at
 launch when Input Monitoring is missing, with a banner until it is granted.
- **Menus** (`AppMenu`): Serpentine (About, Settings… ⌘,, Hide, Quit), Edit, View (Refresh, Full
 Screen), Go (Dashboard ⌘1, Battery History ⌘2), Window, Help.

### 6.2 Background mode and the menu bar item
`BackgroundMode`: Settings › Keep running in the background (`keepRunningInBackground`). Off,
closing the window quits (`applicationShouldTerminateAfterLastWindowClosed`). On, closing it
switches the app to `.accessory` (no Dock icon) and leaves `MenuBarItem`: the serpent (Health
Icons' `animal-snake`, drawn from its SVG path by `SVGPath.swift`; a template image, a bolt while
charging, dimmed when the mouse is away), no percentage. Its menu is the mouse's status,
Open (the window) and Quit.

- Off on a new install; on for an upgrade from the menu bar version (a battery reading or the
 old login-item flag in the defaults), so nothing it relied on disappears.
- The first time a driver-mode feature is set up (`DriverModeUsage`: a remap only the app can
 do, the DPI Cycle action) the app asks once, listing what needs it (`backgroundModeAsked`).
 While it is off the window lists the same things above its cards.
- Start at login needs background mode (turning it off unregisters the login item), and a
 login launch (`keyAELaunchedAsLogInItem`) starts in the menu bar with no window.

### 6.3 Appearance, `Appearance.swift`
Settings › Appearance has a **Theme** (System, Dark, Light, Razer Green) and a **Glass effect**
switch (`appearance.theme`, `appearance.glass`). `AppearanceLook.resolve` turns theme, glass
and the system's light or dark mode into one of six looks, which the main window and About take
(`WindowBackdrop`: the popover material behind the content and title bar, or a solid colour, and
`BackdropTintView` for the green).
Colours (`Palette.swift`): `razerGreen` is the fill; text and icons use `razerGreenText`
(#23891A on light); anything on a green fill uses `onRazerGreen`, because white on #44D62C is
only about 1.9:1.

### 6.4 Button remapping, `ButtonRemapper.swift` + `RemapView.swift`
On a mouse whose button function table is known (`RazerDeviceInfo.buttonTable`, today the
Basilisk V4 Pro), remaps are **written into the mouse** (`OnboardButtons.swift`): each remap
the mouse can do itself goes in its table and is read back, the HyperShift layer too, and
clearing a remap puts back the factory function. Serpentine only ever restores entries it wrote
itself (`OnboardOwnership`). The mouse also does Double Click (`0B`), turbo clicks and keys
(`0E`, `0D`), a DPI clutch (`06 05 05`) and Cycle Scroll Mode (`12`), so these are offered on
that mouse only. Actions it can't do (a key with no HID usage) stay with the tap.
The mouse is where remaps live: on each new connection, and when the mouse switches slot by
itself, both layers are read and replace the remap table shown (`OnboardButtons.adopt`), so a
fresh install or another Mac shows what the mouse holds. Every switch to another slot, from
the app or the mouse, reads that slot's remaps the same way, from an empty table, so nothing
of the previous slot's carries over (`MouseController.followSlotSync`).

On every other mouse it is **software** remapping via a `CGEvent` tap. The tap watches
`otherMouseDown/Up`; for a mapped button it **suppresses the original event and posts the
mapped action** (events the app itself posts are tagged and skipped to avoid loops). Only the
side buttons (Back/Forward = buttons 4/5) emit OS-level events and are remappable; DPI/profile
buttons are handled onboard and never reach macOS.

- Actions: passthrough, **keystroke** (preset shortcuts or a **custom recorder** that
 captures any combo), **mouse** (middle/double click), **media** (play/next/prev/volume/mute).
- Mappings persist to UserDefaults. Needs **Accessibility** permission (banner + Open
 Settings / Re-check in the UI).
- Shown in the dashboard's Buttons column.

### 6.5 Privacy
Serpentine makes no network requests of its own. There are no usage stats, no update checks
and no report uploads; earlier versions of the original project had all three, and this fork
removed them. Settings and battery history stay in the app's preferences and its Application
Support folder. Links in About and in the Help menu open in the browser when clicked.

---

## 7. Permissions & code signing

| Permission | Why | How |
|---|---|---|
| **Input Monitoring** | Razer mice enumerate as keyboard/mouse HID; macOS gates opening them. | Requested at launch via `IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)`; in-app banner + settings link. |
| **Accessibility** | The `CGEvent` tap for button remapping. | `AXIsProcessTrustedWithOptions`; banner + Open-Settings/Re-check in the remap view. |

**Signing matters for permissions.** TCC binds a grant to the app's code identity. The
build is **ad-hoc signed by default, so every rebuild changes the identity and breaks the
grant** (the toggle looks on but doesn't apply). Fixes:
- `Scripts/setup-signing.sh` creates a **stable self-signed identity** ("Razer Cobra
 Self-Signed"); `build-app.sh` auto-uses it. Grant persists across rebuilds.
- Or just develop with `swift run Serpentine`, which inherits the Terminal's grants.
- `tccutil reset ListenEvent io.github.fn-milans.serpentine` clears a stale Input Monitoring grant.

For distribution to other users: every user still grants Input Monitoring once (unavoidable
macOS security). Self-signed = works but Gatekeeper warns ("unidentified developer", one-time
right-click->Open). A clean install needs Developer ID + notarization (paid Apple account).

---

## 8. Extending to other Razer mice

Detection + name display already work for any Razer mouse (read-only, via the USB product
string). The CLI probes (§9) gather what the steps below need. To make the **controls**
verified for another model:
1. Add its PID/name to `RazerDevices.known` with `fullySupported: true` and the right
 `hasBattery` / `hasLighting` / `maxDPI`. If its brightness answers on a group other than
 `LOGO_LED`, set `brightnessLed` too.
2. Confirm its command dialect matches the Cobra Pro set (transaction id, command variants,
 max DPI, poll rates, LED layout, brightness LED). Port any per-device specifics from
 OpenRazer's `razermouse_driver.c` switch statements / `daemon/.../mouse.py` METHODS.
3. Test each control on hardware (use the CLI diagnostics, §9).

If a model uses a different dialect, add a capability field to `RazerDeviceInfo` and expose
it on `DeviceCapabilities`, which is what the app asks, rather than checking PIDs in the code.
Adding a mouse that fits the existing fields touches `Sources/RazerProtocol/RazerDevices.swift`
and nothing else; `DeviceCapabilitiesTests` is where to pin what its row promises.

### 8.1 Capability fields

Every capability is off by default, so a row that doesn't set one behaves as before. A mouse
that shares a capability with one already supported is one row; set only what was confirmed
on the mouse.

| Field | What it turns on |
|---|---|
| `supportsSleepTimeout` | The sleep timer: `BLEProtocol.Key.powerTimeoutGet` on a Bluetooth row, `0x07/0x83` and `0x07/0x03` on a cable or dongle row. |
| `supportsStageEditing` | Editing one DPI stage over Bluetooth. |
| `supportsDpiButtonBinding` | Reassigning the DPI Cycle button over Bluetooth. |
| `usesPollingRate2` | Polling through `0x00/0xC0` and `0x00/0x40` (up to 8000 Hz) instead of `0x00/0x85`; through a dongle it is sent to the mouse and then the dongle. USB only. |
| `hasWheelControls` | Wheel mode (`0x02/0xB0`, `0x02/0x30`) and Smart-Reel (`0x02/0x97`, `0x02/0x17`). USB only. |
| `hasSmartReelSensitivity` | Smart-Reel sensitivity (`0x02/0xA3`, `0x02/0x23`, levels 0-4), shown as Low, Medium and High while Smart-Reel is on. USB only. |
| `hasScrollAcceleration` | Scroll acceleration on/off (`0x02/0x96`, `0x02/0x16`) and its level (`0x02/0xA2`, `0x02/0x22`, 0-4), shown as Low, Medium and High while it is on. USB only. |
| `supportsLowBatteryThreshold` | The battery level the mouse goes into low-battery mode at (`0x07/0x82`, `0x07/0x02`). |
| `hasOnboardSlots` | Onboard profile slots (`OnboardSlots.swift`): the slots are the profiles. Settings go to the active slot, names are kept in the app (`SlotNames`), and a new or reset slot gets the factory bytes (`OnboardSlots.factorySettings`). |
| `supportsDpiModes` | The Single and Stages DPI modes, set through the stage table on every link. |
| `lightingZones` | Lighting set zone by zone (`ZonedLighting`), with the extra effects. |
| `buttonTable` | Remaps saved in the mouse, from a table in `OnboardButtons.Table`. |
| `dpiStagesCountFromOne` | The stage table's active stage and stage numbers count from 1, as OpenRazer writes them. USB only; Bluetooth always counts from 1. |

`RazerDevicesTests.testOnboardCapabilitiesAreOffUnlessARowSetsThem` checks that only the rows
that set them get them.

---

## 9. CLI diagnostics

`serpentine-cli` is its own executable. Run it from a terminal (it uses the Terminal's
permission grant). These were how each feature was verified against hardware:

```sh
swift run serpentine-cli info # list HID interfaces (find the control one)
swift run serpentine-cli battery # read battery %
swift run serpentine-cli dpi [x] [y] # read / set DPI
swift run serpentine-cli poll [125|500|1000]
swift run serpentine-cli rgb static ff0000 # or: spectrum | wave | off
swift run serpentine-cli brightness [0-100] # sweeps LOGO/SCROLL/ZERO/BACKLIGHT LEDs
swift run serpentine-cli stages [d1,d2,…] [active] # read / write the DPI stage table
swift run Serpentine icon out.png [size] [charging] [light] # render the menu bar icon
swift run Serpentine render-ui [offline|color|zones|…] out.png # a page (scenes in PreviewScene)
swift run Serpentine render-window [battery|settings] [zones] [light] [scrolled] [width] out.png # the whole window, offscreen
swift run Serpentine render-about out.png
swift run Serpentine render-remap out.png
```

(The `render-*` commands use SwiftUI `ImageRenderer`, which can't rasterize native controls —
buttons and sliders show as placeholders. Pages that need them drawn go through an
`NSHostingView` instead.)

---

## 10. File map

The package has four targets. `RazerProtocol` and `RazerDeviceKit` are libraries with no
AppKit; the app and the command-line tool build on them.

**`Sources/RazerProtocol`**: Razer's protocol, pure functions and values.

| File | Responsibility |
|---|---|
| `RazerReport.swift` | 90-byte `razer_report` struct + CRC. |
| `RazerCommands.swift` | Command builders and parsers (battery, DPI, stages, polling, lighting, wheel, power) + Razer constants. |
| `BLEProtocol.swift` | Bluetooth LE framing and `RazerReport` translation. |
| `RazerDevices.swift` | The device registry: PID to name, link and capability fields (§8). |
| `DeviceCapabilities.swift` | What a mouse can do on its link, from the registry and the link. Ask this, not the PID. |
| `SettingResidency.swift` | Where each setting lives: in the mouse, or only while the app runs. |
| `OnboardButtons.swift` | The mouse's button function table: blocks, plans, reading back, sync. |
| `OnboardSlots.swift` | The onboard profile slots' commands. |
| `ButtonFunctionTable.swift` | The table's read/write surface, which both transports implement. |
| `ButtonActions.swift` | `RemapAction`, the presets and media keys, HyperShift ids. |
| `LightingZones.swift`, `LightingEffect.swift` | Zoned lighting and the effects. |
| `HardwareButtons.swift` | Ids for buttons with no CGEvent number. |
| `RazerError.swift` | Why a command failed, on any link. |

**`Sources/RazerDeviceKit`**: talking to the hardware.

| File | Responsibility |
|---|---|
| `HIDDevice.swift` | IOKit HID open/enumerate + request/response send. |
| `HIDDeviceSelection.swift` | Which of the dongle's interfaces is the control one. |
| `HIDMonitor.swift` | IOKit service notifications for plug/unplug. |
| `HIDInputWatcher.swift` | Notices the mouse moving while it reads offline. |
| `BluetoothDevice.swift` | CoreBluetooth connection to Razer's vendor GATT service. |
| `RazerTransport.swift` | Transport protocol shared by USB and Bluetooth, plus the shared retry ladder. |
| `OnboardSlotTransport.swift` | A transport with every settings command pointed at the active slot. |
| `DeviceProbe.swift` | The probes `serpentine-cli` runs. |

**`Sources/SerpentineCLI`**: `serpentine-cli`, the hardware diagnostics (§9).

**`Sources/Serpentine`**: the app.

| File | Responsibility |
|---|---|
| `main.swift` | Entry point: no arguments launches the app; subcommands are development tools (render-*, icons). |
| `AppDelegate.swift` | App lifecycle: the window, background mode, the menu bar item, HIDMonitor wiring. |
| `BackgroundMode.swift` | Keep running in the background, and what needs it (`DriverModeUsage`). |
| `Window/` | The main window (`MainWindowController`, `MainWindowView`, `Dashboard`, `Tile`, `WindowRoute`), the menus (`AppMenu`, `ProfileMenu`) and the menu bar item (`MenuBarItem`). |
| `MouseController.swift` | The connected mouse's state, published for the UI. Its work is split by feature into `MouseController+Reads`, `+Writes`, `+Lighting`, `+Slots`, `+OnboardButtons`, `+Profiles`, `+Connection` and `+Preview`. |
| `DeviceQueue.swift` | The serial device queue, with user commands ahead of background reads. |
| `BatteryTracker.swift` | Battery history, charge cycles, discharge curve and last readings, per mouse. |
| `BatteryHistory.swift`, `ChargeCycleHistory.swift`, `DischargeCurveModel.swift` | Sample log, cycles and the learned curve behind the time-left estimate. |
| `ButtonRemapper.swift` | The remap table; the event tap, HyperShift, the DPI Cycle bridge and persistence are in `ButtonRemapper+*`. |
| `SettingsView.swift` | Serpentine's own settings, the sheet behind the cog. |
| `Preferences.swift`, `DeviceSettings.swift` | Every UserDefaults key, and the per-mouse settings store. |
| `LegacyPreferences.swift` | What older versions kept, and the move from MacRazer. |
| `Features/` | The controls the dashboard's tiles are built from: device status and notices, DPI, polling, lighting, power, quick profiles. |
| `Appearance.swift`, `Palette.swift` | Settings › Appearance, the backdrops, and the colours. |
| `ColorPickerPage.swift` | Inline hue/sat colour wheel page + shared `BackButton`. |
| `RemapView.swift` | Button-config UI (inline + window), key recorder. |
| `MenuBarIcon.swift`, `SVGPath.swift` | The serpent (menu bar, app icon) and the per-model mouse silhouettes. |
| `PreviewScenes.swift` | The pages' preview states, for `render-ui` and the snapshot tests. |

External: `reference/openrazer/` (cloned driver source, the protocol reference, gitignored)
and `reference/openrazer-pr-2583.diff` (the Cobra HyperSpeed PR).
