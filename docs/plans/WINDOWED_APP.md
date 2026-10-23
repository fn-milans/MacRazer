# From menu bar app to windowed app

Written 2026-10-23. Serpentine becomes a normal Mac app with a window and a Dock icon. Its
purpose is to put every setting in the mouse's own memory, so most people open it, set up the
mouse, and quit. A few features only work while the app runs ("driver mode"); for those, the
app can keep running in the background with a small menu bar item.

Mockups and icon concepts: [`docs/design/window-design.html`](../design/window-design.html)
(also published, privately, at https://claude.ai/artifact/BqJSHi8EVsoRU3TidVjDAE) and the SVGs
in [`docs/design/icons`](../design/icons). Structural work it depends on:
[REFACTOR.md](REFACTOR.md), phases 1–4 and 6.

## What runs where

Every setting is one of two kinds, and the UI says which (`SettingResidency` in the refactor):

| Saved in the mouse (works with Serpentine closed) | Needs Serpentine running (driver mode) |
|---|---|
| DPI, DPI stages, polling rate | Software button remaps (keystrokes, media keys, double click) on mice without an onboard button table |
| Lighting, brightness | The DPI Cycle F20 bridge (Basilisk V3 X HyperSpeed) |
| Sleep timer, low-battery level | Low-battery notifications |
| Wheel mode, Smart-Reel, scroll acceleration | Battery history and the time-left estimate |
| Onboard profiles and slots | |
| Onboard button remaps and HyperShift (Basilisk V4 Pro) | Connection sounds |

When none of the right-hand column is in use, closing the window quits the app.

## App lifecycle

- **SwiftUI `App`** replaces `main.swift` + `AppDelegate` for the UI: a `Window("Serpentine",
  id: "main")` scene (single window, not `WindowGroup`, since there is one mouse view), a
  `Settings` scene for app preferences, and a `MenuBarExtra` inserted only while background
  mode is on (`MenuBarExtra(isInserted:)`). A small `NSApplicationDelegateAdaptor` keeps what
  SwiftUI has no API for (activation policy, termination, notification delegate).
- **Activation policy**: `.regular` (Dock icon, app menu) whenever the window is open. When the
  window closes:
  - background mode **off** → quit (`applicationShouldTerminateAfterLastWindowClosed` → true);
  - background mode **on** → switch to `.accessory`, keep the menu bar item, keep polling and
    the event tap. Opening the window from the menu bar item switches back to `.regular`.
- **Background mode** setting, in Settings › General and in the window's toolbar status:
  "Keep Serpentine running in the background". Off by default. When the user turns on a
  driver-mode feature, the app offers to turn it on, and names the features that need it.
- **Launch at login** only exists with background mode on, and starts hidden: no window, menu
  bar item only. A login launch is detected with `keyAELaunchedAsLogInItem` on the open-app
  Apple event; any other launch opens the window. Upgraders from the menu bar version get
  background mode turned on once, so the battery in the menu bar they rely on doesn't vanish.
- **Quit** from the menu bar item or ⌘Q quits for real, with the usual history flush.

## The window

`NavigationSplitView`, about 960×640, minimum 780×540, remembered size and position.

**Sidebar**
- *Devices*: every connected Razer mouse, with its model silhouette, link (2.4 GHz, wired,
  Bluetooth) and battery. Today's code drives one mouse; the sidebar starts with one row and
  is ready for more.
- *Sections* for the selected mouse, shown only when the mouse supports them (from
  `DeviceCapabilities`): Overview, Performance, Lighting, Buttons, Profiles, Scroll, Power,
  Battery. ⌘1…⌘8 jump between them.
- Footer: background mode status ("Running in background" / "Quits when closed").

**Toolbar**: mouse name and link; the onboard profile picker (slot colour and name, as on the
mouse); a sync status ("Saved to mouse" with a check, "Writing…", or the error); Refresh (⌘R).

**Panes** (each is one of the per-feature views from refactor phase 6):
- *Overview*: battery ring and time left, current DPI stage, polling rate, active profile,
  lighting swatch; each a shortcut into its pane. Also where the "this mouse is on Bluetooth,
  switch to the dongle for everything" notice lives.
- *Performance*: DPI slider with the model's real maximum, stage editor (the stages as an
  editable row of chips, the active one highlighted, add/remove up to the mouse's limit),
  polling rate segmented control.
- *Lighting*: per-zone list on mice with zones (Basilisk V4 Pro), effect picker, colour wheel
  inline (no sub-page), brightness.
- *Buttons*: a top-down drawing of the mouse with numbered callouts; selecting a button shows
  its action, with a Standard / HyperShift layer switch. Replaces the separate Remap window.
- *Profiles*: the mouse's slots as cards; rename, recolour, copy one slot to another, save to
  and load from a file.
- *Scroll*, *Power*: plain forms.
- *Battery*: the usage graph and charge-cycle history (today's Battery Usage page), larger.

Every control row carries a small residency mark at its trailing edge: a chip glyph for "saved
in the mouse", or an app glyph for "needs Serpentine running", with a tooltip saying so. On a
driver-mode row with background mode off, the mark is amber and says the setting stops when
the window is closed.

**Other windows fold in**: Permissions becomes a sheet on first launch (and a banner in the
window while Input Monitoring is missing); Remap becomes the Buttons pane; About becomes the
standard About panel with the credits; Settings stays a `Settings` scene (General: background
mode, launch at login, appearance, sounds; Notifications: low battery).

## The menu bar item (background mode only)

Much smaller than today's popover. Shows the serpent glyph only, no battery percentage. Its menu (a `MenuBarExtra` with `.menu` style, or `.window` style for the compact
panel below):

```
Basilisk V4 Pro — 82%  ·  2.4 GHz
───────────────
DPI stage        ▸ 400 · 800 · [1600] · 3200 · 6400
Profile          ▸ ● Default  ● FPS  ● Work …
───────────────
Open Serpentine…        ⌘O
Settings…               ⌘,
───────────────
Quit Serpentine         ⌘Q
```

## Phases

| | Work | Depends on |
|---|---|---|
| W1 | `SerpentineApp` scaffold with the window next to the existing popover, behind a hidden switch (`defaults write io.github.fn-milans.serpentine windowedUI -bool YES`). Sidebar, Overview pane. | Refactor 1–4 |
| W2 | Port the panes from the per-feature views. Buttons pane replaces the Remap window. Permissions sheet. | Refactor 6 |
| W3 | Background mode, activation policy switching, the `MenuBarExtra`, launch hidden at login, upgrade path for "Start at login". | W1 |
| W4 | Make the window the default; remove `NSPopover`, `PopoverFocusReturn`, the status item click handling and the right-click menu. Remove `LSUIElement` from Info.plist. | W2, W3 |
| W5 | Polish: keyboard navigation, VoiceOver labels, state restoration, the new icons, README screenshots. | W4 |

## Risks and decisions to make

- **Activation policy flips** can leave the app without a key window or flash the Dock icon.
  Do the switch after the window has closed, and activate explicitly when reopening.
- **`MenuBarExtra` limits**: no right-click menu and limited control over the label. With
  the glyph alone (no percentage) the label is simple; if the charging variant still renders
  badly, fall back to an `NSStatusItem` owned by the app delegate (today's code, much reduced).
- **Polling while hidden**: today the poll cadence speeds up while the popover is open
  (`setPopoverVisible`). Tie that to the window being key instead.
- **Permissions**: the bundle id changed with the rename, so every user is re-granting Input
  Monitoring anyway; the first-launch sheet should make that painless.
- **Decided (2026-10-23)**: background mode never turns itself on. The first time a
  driver-mode feature is set up, the app asks once, listing what needs it. And the menu bar
  item shows no battery percentage: the glyph only, with the percentage inside its menu.

## Icons

**Current (2026-10-23):** the app and menu bar use Health Icons' `animal-snake` (MIT, credited
in NOTICE.md) as a stand-in, drawn from its SVG path by `SVGPath`; changing it later means
replacing `MenuBarIcon.serpentPathData` and running `Scripts/make-icon.sh`. The concepts below
are for the permanent mark.

See [the design page](../design/window-design.html) for renders. Files in [`docs/design/icons`](../design/icons):

- `app-icon-a-coil.svg` (**recommended**): a green serpent forming an S on a graphite squircle.
  Reads at 16 px, and its glyph is the menu bar mark.
- `app-icon-b-mouse.svg`: a green mouse whose button split is a serpentine S.
- `app-icon-c-ouroboros.svg`: a serpent ring around a scroll wheel.
- `menubar.svg`, `menubar-charging.svg`: template glyph (black on clear, macOS tints it) and a
  charging variant with the yellow bolt, matching today's charging colours.

All are original drawings, so they carry no licence obligations. None uses the Razer
triskelion, which today's mouse mark does and which should go regardless. Implementing the
chosen one means replacing `MenuBarIcon.drawMouse` for the menu bar (the per-model silhouettes
stay for the device list) and regenerating `Packaging/AppIcon.icns` with `make-icon.sh`.

Openly licensed snake icons found online, as alternatives or references:

| Icon | Set | Licence | Notes |
|---|---|---|---|
| `iconoven:snake`, `iconoven:snake-sharp` | Iconoven | MIT | S-shaped, closest to the recommended mark |
| `game-icons:snake` | game-icons.net | CC BY 3.0 | Bold S, attribution required |
| `pinhead:rattlesnake` | Pinhead | CC0 | Line drawing, no attribution needed |
| `icon-park-outline:snake-zodiac` | IconPark (ByteDance) | Apache-2.0 | Minimal line S |
| `healthicons:animal-snake` | Health Icons | MIT | Diagonal snake, filled and outline |
| `mdi:snake` | Material Design Icons | Apache-2.0 | Coiled, upright |
| `fluent-emoji-high-contrast:snake` | Fluent Emoji (Microsoft) | MIT | Coiled, monochrome |

All available as SVG from [Iconify](https://icon-sets.iconify.design/) (e.g.
`https://api.iconify.design/iconoven/snake.svg`); check the licence in the set's own
repository before shipping one.
