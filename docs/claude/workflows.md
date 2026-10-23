# Workflows

## Build and test

```sh
swift build                       # every target, debug
swift test                        # 274 tests; no mouse needed
swift test --filter PreferencesTests                  # one suite
bash Tests/Scripts/changelog-test.sh                 # CHANGELOG structure
bash Tests/Scripts/release-test.sh                   # release.sh against fixtures
bash Tests/Scripts/release-notes-test.sh             # the release-notes drafter
```

Run the changelog test after touching `CHANGELOG.md`, the other two after touching
`Scripts/release*.sh`. The tests cover the protocol (codec, builders, parsers, the BLE
translation, button tables), the device kit's retry ladder against fake transports, and the
app's models, persistence, background mode and preferences. Nothing in them talks to hardware.

## Running the app

- `swift run Serpentine` runs it with the Terminal's permissions (Input Monitoring and
  Accessibility are granted to the Terminal, not the app). Quick, but not how it ships.
- `./Scripts/build-app.sh` makes a universal `Serpentine.app` in the repo root, signed with the
  first Apple Development certificate in the keychain, else the "Serpentine Self-Signed"
  identity (`Scripts/setup-signing.sh` creates it), else ad-hoc. A stable identity keeps the
  Input Monitoring grant across rebuilds. This is what "build it with my certs" means.
- `./Scripts/build-app.sh --adhoc` signs ad-hoc whatever certificates exist, and fails if the
  signature carries one. Releases use it.
- After changing the icon (`MenuBarIcon.serpentPathData`, the `iconset` case in `main.swift`):
  `./Scripts/make-icon.sh` regenerates `Packaging/AppIcon.icns`.

## Looking at UI without a screen

This shell has no Screen Recording grant, so `screencapture` of a window fails, and
AppleScript UI scripting hangs on a permission prompt. Draw the views offscreen instead:

```sh
B=$(swift build --show-bin-path)/Serpentine
$B render-window out.png                        # the real window, dark, 1240 wide
$B render-window zones light 1000 out.png       # V4 Pro preview with zones, light, 1000 pt
$B render-window light 1000 scrolled out.png    # scrolled down: nothing under the title bar
$B render-window battery out.png                # Battery History pushed
$B render-window settings out.png               # the Settings sheet
$B render-ui <scene> out.png                    # one PreviewScene, no window chrome
SERPENTINE_SNAPSHOTS=/tmp/snaps swift test --filter SnapshotTests   # every scene as PNG
```

Pass each argument separately (zsh doesn't word-split `$v`). Then read the PNG with the Read
tool. Check 600, 1000 and 1400 pt (narrow, medium, wide layouts) in light and dark.

`render-window` uses `MainWindowController.hostWindow(_:)`, the same function the app uses,
with the controller in a preview state (`MouseController+Preview`). The glass is flat grey
offscreen. `render-ui` draws AppKit-backed controls (switches, some pickers) as yellow
placeholders; `render-window` draws them properly.

`SnapshotTests` don't compare against references; they write PNGs to look at when
`SERPENTINE_SNAPSHOTS` is set and otherwise only check every scene renders. A persisted
default (`popoverExpandedSections` was one) can change a render; reset it if two renders of
the same code differ.

## Trying it on a mouse

Only on the user's machine, with the mouse attached. `serpentine-cli` exercises the device kit
without the app:

```sh
swift run serpentine-cli info        # what's connected, link, serial, firmware
swift run serpentine-cli battery
swift run serpentine-cli dpi         # also: poll, stages, rgb, brightness
```

Then the app itself for the checklist in [status.md](status.md#never-run-on-a-mouse). The
user tests; ask them, don't claim it works.

## Releasing

Ask the user first, every time. A release publishes a DMG people download.

1. `./Scripts/release.sh 0.6.0` (or `--dry-run`): bumps the version and build number in
   `Packaging/Info.plist`, closes the Unreleased section of the changelog, builds the DMGs and
   checks the built app agrees, and drafts release notes in `dist/`. It stops before
   committing, tagging or publishing, and prints the commands for those.
2. Review the diff, commit `Release v0.6.0`, push.
3. Actions → Release → Run workflow (`gh workflow run release.yml`): tests, builds the
   ad-hoc DMGs, checks the signature and version inside, puts them on a draft release.
4. Edit the notes, `./Scripts/release-notes.sh --check`, `gh release edit`, then the user
   publishes the draft, which creates the tag.

`dist/Serpentine.dmg` must keep that name: links download it through
`/releases/latest/download/Serpentine.dmg`.

## CI

`.github/workflows/ci.yml` on every push to main and every PR, on macos-15: `bash -n` and
`shellcheck -S error` over the scripts, the three script tests, `swift build`, a universal
release build checked with `lipo`, `swift test`. Nothing in CI touches hardware.

## Git

- Work on `main` here (the user's repo, `fn-milans/Serpentine`); branch for anything risky.
- `feat/basilisk-v4-pro` is the branch of the open PR to `SorcRR/MacRazer`. Leave it alone.
- Push only when the user says so.
