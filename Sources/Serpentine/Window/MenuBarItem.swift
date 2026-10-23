// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import Combine
import RazerProtocol

/// The menu bar item, there only while Serpentine keeps running in the background. The serpent
/// alone, no percentage; the bolt while the mouse charges, dimmed while it's away. Its menu
/// says how the mouse is, switches its DPI stage and profile, and opens the window.
@MainActor
final class MenuBarItem: NSObject, NSMenuDelegate {
    private let controller: MouseController
    private let remapper: ButtonRemapper
    private let openWindow: () -> Void
    private let openSettings: () -> Void
    private var item: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()

    init(controller: MouseController, remapper: ButtonRemapper,
         openWindow: @escaping () -> Void, openSettings: @escaping () -> Void) {
        self.controller = controller
        self.remapper = remapper
        self.openWindow = openWindow
        self.openSettings = openSettings
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
        let header = NSMenuItem(title: headerTitle, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if let detail = headerDetail {
            let line = NSMenuItem(title: detail, action: nil, keyEquivalent: "")
            line.isEnabled = false
            menu.addItem(line)
        }
        menu.addItem(.separator())
        if controller.connected, controller.dpiStages.count > 1 {
            menu.addItem(submenu("DPI Stage", items: controller.dpiStages.enumerated().map { index, value in
                let i = NSMenuItem(title: "\(value) DPI", action: #selector(selectStage(_:)), keyEquivalent: "")
                i.target = self
                i.tag = index
                let active = controller.activeDpiStage.map { $0 == index } ?? (controller.dpi == value)
                i.state = active ? .on : .off
                return i
            }))
        }
        if controller.connected, let profiles = profileItems() {
            menu.addItem(submenu("Profile", items: profiles))
        }
        if controller.connected { menu.addItem(.separator()) }
        menu.addItem(action("Open Serpentine", #selector(open), "o"))
        menu.addItem(action("Settings…", #selector(settings), ","))
        menu.addItem(.separator())
        menu.addItem(action("Quit Serpentine", #selector(NSApplication.terminate(_:)), "q", target: NSApp))
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

    private func profileItems() -> [NSMenuItem]? {
        if controller.usesSlotProfiles {
            return controller.onboardSlotList.map { slot in
                let i = NSMenuItem(title: controller.slotName(slot), action: #selector(selectSlot(_:)), keyEquivalent: "")
                i.target = self
                i.tag = slot
                i.state = controller.activeOnboardSlot == slot ? .on : .off
                return i
            }
        }
        guard controller.supportsProfiles, !controller.profiles.isEmpty else { return nil }
        return controller.profiles.enumerated().map { index, profile in
            let i = NSMenuItem(title: profile.name, action: #selector(selectProfile(_:)), keyEquivalent: "")
            i.target = self
            i.tag = index
            i.state = controller.activeProfileID == profile.id ? .on : .off
            return i
        }
    }

    private func submenu(_ title: String, items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu()
        items.forEach(menu.addItem)
        item.submenu = menu
        return item
    }

    private func action(_ title: String, _ selector: Selector, _ key: String, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = target ?? self
        return item
    }

    /// A mouse with DPI modes makes the stage active; others are set to its value, as the
    /// popover's stage chips do.
    @objc private func selectStage(_ sender: NSMenuItem) {
        guard controller.dpiStages.indices.contains(sender.tag) else { return }
        if controller.supportsDpiModes {
            controller.setDPITable(controller.dpiStages, active: sender.tag)
        } else {
            controller.setDPI(controller.dpiStages[sender.tag])
        }
    }

    @objc private func selectSlot(_ sender: NSMenuItem) { controller.switchToSlot(sender.tag) }

    @objc private func selectProfile(_ sender: NSMenuItem) {
        guard controller.profiles.indices.contains(sender.tag) else { return }
        controller.applyProfile(controller.profiles[sender.tag], remapper: remapper)
    }

    @objc private func open() { openWindow() }
    @objc private func settings() { openSettings() }
}
