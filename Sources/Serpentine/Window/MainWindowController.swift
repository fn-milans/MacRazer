// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import SwiftUI

/// The main window. One of it: there is one mouse view, so a second window would only show the
/// same thing twice. Built on first use and kept, so its pane and scroll position survive
/// closing it.
@MainActor
final class MainWindowController: NSObject, AppWindowPresenter, NSWindowDelegate {
    private var window: NSWindow?
    private let controller: MouseController
    private let remapper: ButtonRemapper
    private let permissions: PermissionsModel
    let navigation = WindowNavigation()
    /// Called after the window closes.
    var onClose: (() -> Void)?

    init(controller: MouseController, remapper: ButtonRemapper, permissions: PermissionsModel) {
        self.controller = controller
        self.remapper = remapper
        self.permissions = permissions
    }

    var isVisible: Bool { window?.isVisible ?? false }
    var nsWindow: NSWindow? { window }

    func show() {
        if window == nil { window = makeWindow() }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        // While the window is open, what a button on the mouse changes is checked every couple
        // of seconds, so it shows at once.
        controller.setLiveChecks(true)
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: MainWindowView(
            controller: controller, remapper: remapper, navigation: navigation, permissions: permissions))
        // The SwiftUI view sets the minimum; the window keeps the size the user gave it.
        hosting.sizingOptions = [.minSize]
        // The panes' titles and toolbar items go in the window's own title bar.
        hosting.sceneBridgingOptions = [.title, .toolbars]
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.contentViewController = hosting
        w.title = "Serpentine"
        w.toolbarStyle = .unified
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.tabbingMode = .disallowed
        // Remembered between launches; the first time, a comfortable size in the middle.
        if !w.setFrameUsingName(Self.frameName) {
            w.setContentSize(NSSize(width: 960, height: 640))
            w.center()
        }
        w.setFrameAutosaveName(Self.frameName)
        AppearanceSettings.shared.trackAppearance(w)
        return w
    }

    private static let frameName = "SerpentineMainWindow"

    func windowWillClose(_ notification: Notification) {
        controller.setLiveChecks(false)
        // After the close has happened, so `isVisible` already says so.
        DispatchQueue.main.async { [weak self] in self?.onClose?() }
    }
}
