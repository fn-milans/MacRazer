// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

// Entry point. No arguments launches the menu bar app; subcommands are development tools:
// render-* commands that draw UI pages and icons to PNGs for visual inspection without a
// device, and login-item. The hardware diagnostics are `serpentine-cli` (Sources/SerpentineCLI).

import AppKit
import ServiceManagement
import SwiftUI
import RazerProtocol
import RazerDeviceKit

let args = Array(CommandLine.arguments.dropFirst())

// No arguments → launch the menu bar app. Subcommands → the development tools below.
if args.isEmpty {
    // Before AppDelegate, whose stores read preferences and files as they are created.
    LegacyInstall.migrate()
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular) // a normal app: Dock icon, menus, a window
    app.run()
    exit(0)
}

let command = args.first!

/// Shared by the render-* commands: draw a SwiftUI view at 2x on the app's dark backdrop
/// and write it to a PNG.
@MainActor func writeViewPNG<V: View>(_ view: V, to path: String) {
    // Rendered in the Dark theme, to match the dark backdrop below. The app itself follows
    // Settings › Appearance; without this `.secondary`/`.tertiary` resolve for light mode and
    // render as near-black text on that backdrop, which made every preview look like it had
    // a contrast bug it doesn't have.
    let renderer = ImageRenderer(
        content: view.environment(\.colorScheme, .dark).padding(1).background(Color(white: 0.13)))
    renderer.scale = 2
    if let img = renderer.nsImage,
       let tiff = img.tiffRepresentation,
       let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: path))
        print("Wrote \(path)")
    } else {
        print("Render failed")
    }
}

/// Renders through a real `NSHostingView` instead of `ImageRenderer`.
///
/// `ImageRenderer` draws a `ScrollView` as an empty box — its content is laid out lazily and
/// never makes it into the snapshot — so a page whose body is a scroll view has to be hosted
/// in a view hierarchy and captured from there.
///
/// `size` is optional: a view that sizes itself, like a window's content, is measured with
/// `fittingSize`. Only a scroll view has to be told how much room it has, because it will
/// take whatever it is given.
@MainActor func writeHostedPNG<V: View>(_ view: V, size: CGSize? = nil, to path: String) {
    // The dark backdrop every surface here stands in for. `cacheDisplay` captures no window
    // background, and the dark scheme's primary text is white — without this the whole thing
    // renders white on white.
    let hosted = view.environment(\.colorScheme, .dark).background(Color(white: 0.13))
    let host = NSHostingView(rootView: AnyView(hosted))
    host.appearance = NSAppearance(named: .darkAqua)
    let frameSize = size ?? host.fittingSize
    // A view with no intrinsic size measures as zero, and the capture below then fails with
    // nothing to say about why. Name the cause instead.
    guard frameSize.width > 0, frameSize.height > 0 else {
        print("Render failed: the view has no size of its own. Pass an explicit size.")
        return
    }
    host.frame = CGRect(origin: .zero, size: frameSize)
    host.layoutSubtreeIfNeeded()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
        print("Render failed")
        return
    }
    host.cacheDisplay(in: host.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        print("Render failed")
        return
    }
    try? png.write(to: URL(fileURLWithPath: path))
    print("Wrote \(path)")
}

/// The output path for a `render-*` command: the first argument that names a PNG.
///
/// Flags are bare words and the path is positional, so "the first argument" wrote a file
/// literally named `update` or `charging`. Keeping a list of known flags per command only
/// moves the bug — a flag added later and forgotten in the list becomes the filename again.
/// Asking what the argument *is* needs no list to keep in sync.
func outputPath(_ args: ArraySlice<String>, default fallback: String) -> String {
    args.first { $0.lowercased().hasSuffix(".png") } ?? fallback
}

switch command {
case "login-item":
    // Report on (and optionally flip) the "Start Serpentine at login" registration — the one
    // piece of app state that lives in the system rather than in our own defaults, so it can't
    // be checked by reading a file. `on`/`off` drive the same `LaunchAtLogin.setEnabled` the
    // Settings switch calls, which also makes this the repair path when the GUI isn't reachable.
    // Only meaningful from the packaged .app: under `swift run` there is no bundle to register.
    let loginItem = LaunchAtLogin()
    if let arg = args.dropFirst().first {
        switch arg {
        case "on": loginItem.setEnabled(true)
        case "off": loginItem.setEnabled(false)
        default:
            print("Usage: login-item [on|off]")
            exit(64)
        }
        if let failure = loginItem.lastError { print("⚠︎ \(failure)") }
    }
    print("Bundle:   \(Bundle.main.bundleURL.path)")
    print("Eligible: \(loginItem.isSupported ? "yes" : "no — not an installed .app (see AppLocation)")")
    let status = SMAppService.mainApp.status
    let described: String
    switch status {
    case .enabled: described = "enabled — macOS will start Serpentine at login"
    case .notRegistered: described = "not registered — the switch is off"
    case .requiresApproval: described = "requires approval in System Settings › General › Login Items"
    case .notFound: described = "not found — macOS has no record of this bundle"
    @unknown default: described = "unknown (raw \(status.rawValue))"
    }
    print("Status:   \(described)")
    print("Default applied once: \(UserDefaults.standard.bool(forKey: Preferences.launchAtLoginDefaultApplied))")

case "render-ui":
    // Render a pane of the main window to a PNG for static visual inspection (no device needed).
    _ = NSApplication.shared
    let path = outputPath(args.dropFirst(), default: "ui-preview.png")
    // The scene named in the arguments, `main` when none is.
    let scene = PreviewScene.allCases.first { args.dropFirst().contains($0.rawValue) } ?? .main
    let rootView = scene.makeView()
    if scene.needsHosting { writeHostedPNG(rootView, to: path) } else { writeViewPNG(rootView, to: path) }

case "render-window":
    // The main window, offscreen, on a given page: render-window [mouse|buttons|settings] [zones] [light] out.png
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let path = outputPath(args.dropFirst(), default: "window-preview.png")
    let controller = MouseController()
    controller.loadPreviewState()
    if args.contains("zones") { controller.setPreviewZonedLighting() }
    if args.contains("offline") { controller.setPreviewOffline() }
    let remapper = ButtonRemapper()
    let navigation = WindowNavigation()
    // Set up already, unless the setup banner is what's being looked at.
    let previewPermissions = PermissionsModel()
    if !args.contains("setup") { previewPermissions.loadPreviewState() }
    navigation.page = WindowPage.allCases.first { args.dropFirst().contains($0.rawValue) } ?? .mouse
    let window = MainWindowController.hostWindow(MainWindowView(
        controller: controller, remapper: remapper, navigation: navigation, permissions: previewPermissions,
        background: BackgroundMode(), launchAtLogin: LaunchAtLogin()))
    window.appearance = NSAppearance(named: args.contains("light") ? .aqua : .darkAqua)
    AppearanceSettings.shared.applyToWindows(AppearanceSettings.shared.look(systemIsDark: !args.contains("light")))
    window.setContentSize(NSSize(width: 600, height: 820))
    // Off screen, but ordered in, so the split view and the toolbar lay out as in the app.
    window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    window.orderFrontRegardless()
    RunLoop.main.run(until: Date().addingTimeInterval(1.0))
    let frameView = window.contentView!.superview!
    guard let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { print("Render failed"); exit(1) }
    frameView.cacheDisplay(in: frameView.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    print("Wrote \(path)")

case "render-settings":
    _ = NSApplication.shared
    let settingsPath = outputPath(args.dropFirst(), default: "settings-preview.png")
    let sc = MouseController()
    sc.loadPreviewState()
    let sl = LaunchAtLogin()
    sl.loadPreviewState()
    writeViewPNG(SettingsView(controller: sc, launchAtLogin: sl, background: BackgroundMode()).padding(16).frame(width: 520),
                 to: settingsPath)

case "render-about":
    _ = NSApplication.shared
    let aboutPath = outputPath(args.dropFirst(), default: "about-preview.png")
    // Hosted rather than `ImageRenderer`: this window is mostly buttons and links, and
    // `ImageRenderer` draws every native control as a yellow placeholder — which is to say it
    // could not show the one thing an About preview is for.
    writeHostedPNG(AboutView(onDone: {}), to: aboutPath) // no window to close in a render

case "render-remap":
    _ = NSApplication.shared
    let path = outputPath(args.dropFirst(), default: "remap-preview.png")
    let r = ButtonRemapper()
    // `--v4pro` previews the Basilisk V4 Pro's list, saved in the mouse.
    r.loadPreviewState(pid: args.contains("--v4pro") ? 0x00E3 : nil)
    writeViewPNG(RemapView(remapper: r), to: path)

case "render-permissions":
    _ = NSApplication.shared
    let path = outputPath(args.dropFirst(), default: "permissions-preview.png")
    let controller = MouseController()
    controller.loadPreviewState()
    let model = PermissionsModel()
    model.loadPreviewState()
    writeViewPNG(PermissionsView(model: model, controller: controller), to: path)

case "icon":
    // Render the menu bar mark to a PNG for visual inspection.
    let iconArgs = args.dropFirst()
    let path = outputPath(iconArgs, default: "icon-preview.png")
    // Optional size, so the mark can be checked at real menu bar scale (~21pt @2x) rather
    // than judged from a downsampled 256px render. Bounded: an unbounded value makes the
    // bitmap allocation fail and the write silently do nothing.
    let size = iconArgs.compactMap { Int($0) }.first { $0 > 0 }.map { CGFloat(min($0, 2048)) } ?? 256
    guard MenuBarIcon.writePreview(to: path, size: size, charging: iconArgs.contains("charging"),
                                   lightMenuBar: iconArgs.contains("light")) else {
        print("Render failed")
        exit(1)
    }
    print("Wrote \(path)")

case "icon-models":
    // Render each per-model silhouette (header icon variants) to PNGs for visual inspection.
    let dir = args.dropFirst().first ?? "/tmp"
    let shapes: [(String, RazerMouseSilhouette)] = [
        ("cobra", .cobra), ("cobra-pro", .cobraPro), ("atheris", .atheris),
    ]
    for (name, shape) in shapes {
        let p = "\(dir)/serpentine-model-\(name).png"
        MenuBarIcon.writePreview(to: p, size: 256, silhouette: shape)
        print("Wrote \(p)")
    }

case "iconset":
    // Render the chosen app icon (dark + green) at all .iconset sizes for iconutil.
    let dir = args.dropFirst().first ?? "/tmp/Serpentine.iconset"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let bg = NSColor(white: 0.09, alpha: 1)
    let mark = NSColor(red: 0.42, green: 1.0, blue: 0.25, alpha: 1)
    let sizes: [(String, CGFloat)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256),
        ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]
    for (name, sz) in sizes {
        MenuBarIcon.writeAppIcon(to: "\(dir)/\(name).png", size: sz, bg: bg, mark: mark)
    }
    print("Wrote iconset to \(dir)")

case "info", "battery", "dpi", "stages", "poll", "brightness", "rgb":
    // The hardware diagnostics are their own executable now, which needs no AppKit.
    print("\(command) moved to the command-line tool: swift run serpentine-cli \(args.joined(separator: " "))")
    exit(64)

default:
    print("Unknown command: \(command)")
    print("Available: login-item [on|off], render-ui [variant] [out.png], render-settings, render-about, render-remap, render-permissions, icon, icon-models, iconset")
    print("Hardware diagnostics: swift run serpentine-cli")
    exit(64)
}
