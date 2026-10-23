// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import SwiftUI

/// Hosts the app's settings in a normal window, from Serpentine › Settings (⌘,) and the menu
/// bar item.
@MainActor
final class SettingsWindowController: AppWindowPresenter {
    private var window: NSWindow?
    private let controller: MouseController
    private let launchAtLogin: LaunchAtLogin
    private let background: BackgroundMode

    init(controller: MouseController, launchAtLogin: LaunchAtLogin, background: BackgroundMode) {
        self.controller = controller
        self.launchAtLogin = launchAtLogin
        self.background = background
    }

    func show() {
        if window == nil {
            let root = SettingsView(controller: controller, launchAtLogin: launchAtLogin, background: background,
                                    onDone: { [weak self] in self?.window?.close() })
            let hosting = NSHostingController(rootView: root)
            hosting.sizingOptions = [.preferredContentSize]
            let w = NSWindow(contentViewController: hosting)
            w.title = "Serpentine Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            // Themed per Settings › Appearance, kept up to date when it changes.
            AppearanceSettings.shared.track(w)
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        // Opening is the moment the login-item switch has to be right: the user may have
        // changed it in System Settings since this window was last built.
        launchAtLogin.refresh()
    }
}
