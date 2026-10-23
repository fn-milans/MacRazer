// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import SwiftUI

/// Hosts About MacRazer in a normal window, reached from the menu bar's right-click menu.
@MainActor
final class AboutWindowController: AppWindowPresenter {
    private var window: NSWindow?

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        if window == nil {
            let root = AboutView(onDone: { [weak self] in self?.window?.close() })
            let controller = NSHostingController(rootView: root)
            controller.sizingOptions = [.preferredContentSize]
            let w = NSWindow(contentViewController: controller)
            w.title = "About MacRazer"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            // Themed like the popover per Settings › Appearance, kept up to date when it changes.
            AppearanceSettings.shared.track(w)
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
