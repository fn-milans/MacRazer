# Conventions

## Code

- Every Swift file starts with the SPDX header:
  ```swift
  // SPDX-License-Identifier: GPL-2.0-or-later
  // Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.
  ```
- Doc comments say **why**, or what a reader would get wrong, not what the next line does.
  The protocol code cites where a byte layout came from (OpenRazer, a capture, a test on a
  specific mouse). Keep that when you change it.
- Match the file you're in: its naming, comment density, how it lays out a view.
- `MouseController` and `ButtonRemapper` grow by feature file (`MouseController+Lighting.swift`),
  not by adding to the main file. State goes in the main file; work in the extension.
- Views that hold a setting's controls live in `Sources/Serpentine/Features/`; window
  structure (tiles, dashboard, toolbar, menus) in `Sources/Serpentine/Window/`.
- Ask `DeviceCapabilities` what a mouse can do; never compare PIDs in the app.
- Every UserDefaults key is named in `Preferences`. Removing one: delete it there, add the
  spelling to `LegacyPreferences.keys`, update `PreferencesTests`.
- Anything new that a view shows needs a preview state in `MouseController+Preview` and,
  where it's a page, a `PreviewScene`, so it can be rendered.
- No new dependencies. The package has none beyond the SDK.

## UI copy

Short and plain. Title case for tile names, menu items and buttons; sentence case for
descriptions. Say what happens for the user ("Saved in the mouse", "Needs Serpentine
running"), not how it's implemented. No battery percentage in the menu bar.

## Commits

- One coherent change per commit; the user asked for each phase to be its own commit.
- Subject: what changed, in plain words, no prefix convention (`Profile menu: switch and
  Manage Profiles only`, `Buttons unfolded in a third column; …`).
- Body: prose paragraphs on what the user will see and why, wrapped at ~80 columns. Mention
  what wasn't tested on hardware when it matters.
- End with the co-author line the session's system reminder gives.
- The same commit updates the docs it makes untrue (below).

## Docs to keep true

| When you change | Update |
|---|---|
| Anything a user would notice | `CHANGELOG.md`, Unreleased section |
| Add, move, rename, delete a source file | the file map in `docs/DOCUMENTATION.md` |
| Architecture, a decision, the UI rules | `docs/claude/` (add a decision rather than rewriting one) |
| What's done or left | `docs/claude/status.md` |
| Something on screen, a lot | the screenshots in `docs/assets/` (from `render-window`) |

## How the user works

- Milan gives design feedback in rounds, often several messages mid-turn while you're
  working. Fold each into the current change rather than finishing the old plan first, and
  make sure every one of them is handled before wrapping up.
- They judge by what it looks like. Render it and look at the PNG before saying it's done;
  check the widths and both appearances.
- They want macOS-native: HIG layout, system materials and controls, SF Symbols. Title left,
  controls right. No centred tabs, no custom chrome.
- Read requests literally and completely. "Go through all the phases" meant both plans, not
  just the refactor; doing only part of it cost a round.
- They test builds themselves (`./Scripts/build-app.sh`, signed with their Apple Development
  certificate). Push only when asked; never release without asking.
- The project's purpose is settings stored in the mouse. When a feature could live in the
  mouse or in the app, prefer the mouse, and say in the UI which one it is.
