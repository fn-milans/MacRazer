# Working on Serpentine with Claude Code

These notes are for picking the project up in a new session, human or Claude. They describe
the code as it is (late October 2026), why it is that way, and what is left.

Read in this order:

1. [status.md](status.md): where the work stands, what has never run on a mouse, what is next.
2. [architecture.md](architecture.md): the four targets, how a setting gets from a click to
   the mouse, threading, persistence, the window.
3. [decisions.md](decisions.md): the choices made and why, so they aren't undone by accident.
4. [ui-design.md](ui-design.md): the window's design rules (layout, tiles, header, glass).
5. [workflows.md](workflows.md): building, testing, looking at UI without a screen capture,
   signing, releasing, CI.
6. [conventions.md](conventions.md): code, comments, commits, docs, and how the user works.

Other documents:

- [`../DOCUMENTATION.md`](../DOCUMENTATION.md): the reference: the HID protocol, hardware
  quirks, every capability field, the file map. Keep its file map current.
- [`../../CHANGELOG.md`](../../CHANGELOG.md): user-facing history; the Unreleased section is
  everything since 0.5.0.

## The project in one paragraph

A Razer mouse is configured by 90-byte HID feature reports (ported from OpenRazer) over the
cable or the 2.4 GHz dongle, or by Razer's vendor GATT service over Bluetooth. Serpentine reads
and writes those settings and, where the mouse can keep them (DPI and stages, polling, lighting,
power, wheel, onboard profile slots, and on the Basilisk V4 Pro the button table and its
HyperShift layer), writes them into the mouse. What the mouse can't keep (some remaps, the
DPI Cycle bridge, low-battery alerts, battery history) the app does while it runs. The app is a
window with a dashboard of tiles; it can keep running in the background as a menu bar item.
