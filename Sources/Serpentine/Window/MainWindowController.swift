// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import SwiftUI

/// The main window. One of it: there is one mouse view, so a second window would only show the
/// same thing twice. Built on first use and kept, so its page and scroll position survive
/// closing it.
@MainActor
final class MainWindowController: NSObject, AppWindowPresenter, NSWindowDelegate {
    private var window: NSWindow?
    private let controller: MouseController
    private let remapper: ButtonRemapper
    private let permissions: PermissionsModel
    private let background: BackgroundMode
    private let launchAtLogin: LaunchAtLogin
    let navigation = WindowNavigation()
    /// Called after the window closes.
    var onClose: (() -> Void)?

    init(controller: MouseController, remapper: ButtonRemapper, permissions: PermissionsModel,
         background: BackgroundMode, launchAtLogin: LaunchAtLogin) {
        self.controller = controller
        self.remapper = remapper
        self.permissions = permissions
        self.background = background
        self.launchAtLogin = launchAtLogin
    }

    var isVisible: Bool { window?.isVisible ?? false }
    var nsWindow: NSWindow? { window }

    func show() {
        if window == nil { window = makeWindow() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        // While the window is open, what a button on the mouse changes is checked every couple
        // of seconds, so it shows at once.
        controller.setLiveChecks(true)
    }

    private func makeWindow() -> NSWindow {
        let w = Self.hostWindow(MainWindowView(
            controller: controller, remapper: remapper, navigation: navigation, permissions: permissions,
            background: background, launchAtLogin: launchAtLogin))
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.tabbingMode = .disallowed
        // Remembered between launches; the first time, a comfortable size in the middle.
        if !w.setFrameUsingName(Self.frameName) {
            w.setContentSize(NSSize(width: 1240, height: 800))
            w.center()
        }
        w.setFrameAutosaveName(Self.frameName)
        return w
    }

    private static let frameName = "SerpentineMainWindow"

    /// The window around the main view, shared with `render-window` so a render looks like
    /// the app.
    static func hostWindow<V: View>(_ view: V) -> NSWindow {
        let hosting = NSHostingController(rootView: view)
        // The SwiftUI view sets the minimum; the window keeps the size the user gave it.
        hosting.sizingOptions = [.minSize]
        // The panes' titles and toolbar items go in the window's own title bar.
        hosting.sceneBridgingOptions = [.title, .toolbars]
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800),
                         // Full-size content keeps the title and the toolbar items on one row;
                         // the pages are clipped below the toolbar (`MainWindowView.page`).
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.contentViewController = hosting
        w.title = "Serpentine"
        w.toolbarStyle = .unified
        // No hairline under the title bar: the cards float on the glass.
        w.titlebarSeparatorStyle = .none
        // The popover's glass (or a solid colour), per Settings › Appearance, title bar included.
        AppearanceSettings.shared.track(w)
        return w
    }

    func windowWillClose(_ notification: Notification) {
        controller.setLiveChecks(false)
        // After the close has happened, so `isVisible` already says so.
        DispatchQueue.main.async { [weak self] in self?.onClose?() }
    }
}
