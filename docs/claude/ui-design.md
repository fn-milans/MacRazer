# UI design

The rules the window follows, from the rounds of design with the user (decisions D10-D19).
Change them with the user, not silently.

## Window

- One window, `MainWindowController`, opens at 1240 × 800 the first time, remembers its frame
  (`SerpentineMainWindow`), minimum 560 × 520.
- Glass background (popover material) or solid, per Settings › Appearance; light, dark or
  Razer Green. Content never scrolls under the title bar.

## Title bar

| Leading | Trailing |
|---|---|
| Window buttons, then **Serpentine** (or ‹ and the detail's title) | Status mark · Profile menu · Refresh · Settings cog |

- **Status mark**: green check "In the mouse"; amber "Not all saved" when an onboard write
  failed (hover for the error); red "Profile not applied" after a failed apply.
- **Profile menu**: label is the profile in use. Items: the profiles (the mouse's slots, or
  saved profiles) with the active one ticked, then Manage Profiles… (a sheet). Nothing else.
- No tabs, no centred items.

## Dashboard

```
┌───────────────────────────────────────────────────────────────────────────┐
│ [icon] Razer Basilisk V4 Pro                      ~3d left      ( 72% )    │  DeviceTile
│        ● 2.4 GHz wireless                         Battery History          │
└───────────────────────────────────────────────────────────────────────────┘
┌───────────────┐ ┌───────────────┐ ┌──────────────────┐
│ DPI           │ │ Polling Rate  │ │ Buttons          │   ≥ 1180 pt: two tile columns
├───────────────┤ ├───────────────┤ │ (RemapView,      │   + Buttons (400 pt)
│ Lighting      │ │ Sleep         │ │  unfolded)       │   820-1180: one tile column + Buttons
├───────────────┤ ├───────────────┤ │                  │   < 820: one column, Buttons last,
│ Low Battery   │ │ Scroll Wheel  │ │                  │   battery under the mouse's name
└───────────────┘ └───────────────┘ └──────────────────┘
```

- **Tiles** (`Tile`): a 26 pt rounded square with a white SF Symbol on a gradient of the tile's
  colour (System Settings style), the name (13 pt semibold), a residency mark at the right
  (`memorychip` = saved in the mouse, `macwindow` = needs Serpentine running, explained on
  hover), the value in 26 pt rounded semibold, then the controls. 16 pt padding, 18 pt
  continuous corners, a light fill (`primary` 5.5 %) and a hairline (`primary` 7 %).
- **Tile order and colours**: DPI (green), Polling Rate (blue), Lighting (orange), Sleep
  (indigo), Low Battery (red), Scroll Wheel (teal); Buttons (pink). Only the tiles the mouse
  has. An odd last tile spans the row.
- **Offline**: tiles stay, dimmed (55 %) and disabled, showing the last known values. No mouse
  at all: the no-mouse card under the mouse tile, no tiles.
- **Banners** above the page: Input Monitoring missing (Set Up…), and driver-mode features in
  use while background mode is off (Keep Running).
- **Details and sheets**: Battery History pushes in place with a back button. Settings,
  setup, Manage Profiles and the colour wheel are sheets.

## Menu bar item (background mode only)

The serpent glyph alone; the bolt variant while charging; 60 % opacity while the mouse is
away. Menu: `Basilisk V4 Pro — 72%`, the time left or Charging, then Open (⌘O) and Quit (⌘Q).

## Colours and type

- `razerGreen` (#44D62C) is a fill; text and icons on light use `razerGreenText` (#23891A);
  anything on a green fill uses `onRazerGreen` (dark), since white on #44D62C is ~1.9:1.
- Battery state uses system meaning colours (`batteryFull/Mid/Low`), never the brand green.
- Copy: short, plain, sentence case for descriptions, title case for tile names and menu
  items. Say what happens ("Saved in the mouse"), not how it's built.

## Checking a change

```sh
B=$(swift build --show-bin-path)/Serpentine
$B render-window zones 1400 /tmp/w-wide.png            # three columns, V4 Pro with zones
$B render-window zones 1000 /tmp/w-medium.png
$B render-window zones 600 /tmp/w-narrow.png
$B render-window light 1000 /tmp/w-light.png
$B render-window light 1000 scrolled /tmp/w-scrolled.png   # nothing under the title bar
$B render-window settings /tmp/w-settings.png
```

Offscreen the glass has nothing behind it, so it renders flat grey; that's expected. AppKit
switches and some pickers render as yellow placeholders in `render-ui`/`ImageRenderer`
renders but draw correctly in `render-window`, which hosts them in a real window.
