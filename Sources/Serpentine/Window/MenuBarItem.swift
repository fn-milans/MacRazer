// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import Combine
import RazerProtocol

/// The menu bar item, there only while Serpentine keeps running in the background. The serpent
/// alone, no percentage; the bolt while the mouse charges, dimmed while it's away. Its menu
/// says how the mouse is and opens the window, where everything else is.
@MainActor
final class MenuBarItem: NSObject, NSMenuDelegate {
    private let controller: MouseController
    private let openWindow: () -> Void
    private var item: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()

    init(controller: MouseController, openWindow: @escaping () -> Void) {
        self.controller = controller
        self.openWindow = openWindow
    }

    var isShown: Bool { item != nil }

    func setShown(_ shown: Bool) {
        if shown, item == nil { install() } else if !shown, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
            cancellables.removeAll()
        }
    }

    private func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.idleIcon
        item.button?.setAccessibilityLabel("Serpentine")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        self.item = item
        // The images are drawn once each and never for the menu bar's appearance: the idle one
        // is a template macOS recolours, the charging one resolves its colours as it is drawn
        // (see `MenuBarIcon.chargingBody`). Nothing here watches `effectiveAppearance`, on
        // purpose: setting the image makes AppKit report it as changed, and a watcher that
        // sets the image in response never stops (issue #25).
        controller.$charging.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] charging in self?.item?.button?.image = charging ? Self.chargingIcon : Self.idleIcon }
            .store(in: &cancellables)
        // Dimmed, not tinted, while the mouse is away: a grey tint disappears against a dark
        // menu bar, a dimmed template reads in both.
        controller.$connected.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] connected in self?.item?.button?.alphaValue = connected ? 1 : 0.6 }
            .store(in: &cancellables)
    }

    private static let idleIcon = MenuBarIcon.serpent(pointSize: 21)
    private static let chargingIcon = MenuBarIcon.serpent(pointSize: 21, charging: true)

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for line in [headerTitle, headerDetail].compactMap({ $0 }) {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open Serpentine", action: #selector(openSerpentine), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)
        let quit = NSMenuItem(title: "Quit Serpentine", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    private var headerTitle: String {
        let name = controller.deviceName.map(MainWindowView.shortName) ?? "No mouse connected"
        guard controller.deviceHasBattery, let pct = controller.batteryPercent else { return name }
        return controller.connected ? "\(name) — \(pct)%" : "\(name) — offline"
    }

    private var headerDetail: String? {
        guard controller.connected else { return nil }
        if controller.charging { return "Charging" }
        return controller.timeEstimate
    }

    @objc private func openSerpentine() { openWindow() }
}
