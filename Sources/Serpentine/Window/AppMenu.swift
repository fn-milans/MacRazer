// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit

/// The menu bar menus of a normal Mac app: Serpentine (Settings… opens the settings sheet),
/// Edit (text fields need it for copy and paste), View, Go (the dashboard and what opens from
/// it, ⌘1 to ⌘3), Window and Help.
@MainActor
final class AppMenu: NSObject {
    struct Actions {
        var about: () -> Void
        var settings: () -> Void
        var showMainWindow: () -> Void
        var refresh: () -> Void
        /// The dashboard with nil, or one of its detail views.
        var go: (WindowRoute?) -> Void
    }

    private let actions: Actions

    init(actions: Actions) {
        self.actions = actions
    }

    func install() {
        let main = NSMenu()
        main.addItem(submenu("Serpentine", appMenu()))
        main.addItem(submenu("Edit", editMenu()))
        main.addItem(submenu("View", viewMenu()))
        main.addItem(submenu("Go", goMenu()))
        let window = windowMenu()
        main.addItem(submenu("Window", window))
        let help = helpMenu()
        main.addItem(submenu("Help", help))
        NSApp.mainMenu = main
        NSApp.windowsMenu = window
        NSApp.helpMenu = help
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        menu.title = title
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private func item(_ title: String, _ action: Selector, _ key: String = "",
                      modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        return item
    }

    private func appMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(item("About Serpentine", #selector(about), target: self))
        m.addItem(.separator())
        m.addItem(item("Settings…", #selector(settings), ",", target: self))
        m.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu()
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        m.addItem(services)
        m.addItem(.separator())
        m.addItem(item("Hide Serpentine", #selector(NSApplication.hide(_:)), "h"))
        m.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", modifiers: [.command, .option]))
        m.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        m.addItem(.separator())
        m.addItem(item("Quit Serpentine", #selector(NSApplication.terminate(_:)), "q"))
        return m
    }

    private func editMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(item("Undo", Selector(("undo:")), "z"))
        m.addItem(item("Redo", Selector(("redo:")), "z", modifiers: [.command, .shift]))
        m.addItem(.separator())
        m.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        m.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        m.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        m.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        return m
    }

    private func viewMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(item("Refresh", #selector(refresh), "r", target: self))
        m.addItem(.separator())
        m.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", modifiers: [.command, .control]))
        return m
    }

    private func goMenu() -> NSMenu {
        let m = NSMenu()
        let home = item("Dashboard", #selector(go(_:)), "1", target: self)
        m.addItem(home)
        for (index, route) in WindowRoute.allCases.enumerated() {
            let i = item(route.title, #selector(go(_:)), String(index + 2), target: self)
            i.representedObject = route.rawValue
            m.addItem(i)
        }
        return m
    }

    private func windowMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        m.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        m.addItem(.separator())
        m.addItem(item("Serpentine", #selector(showMainWindow), "0", target: self))
        m.addItem(.separator())
        m.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return m
    }

    private func helpMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(item("Serpentine on GitHub", #selector(openRepo), target: self))
        m.addItem(item("Report an Issue", #selector(openIssues), target: self))
        return m
    }

    @objc private func about() { actions.about() }
    @objc private func settings() { actions.settings() }
    @objc private func showMainWindow() { actions.showMainWindow() }
    @objc private func refresh() { actions.refresh() }
    @objc private func go(_ sender: NSMenuItem) {
        actions.go((sender.representedObject as? String).flatMap(WindowRoute.init(rawValue:)))
    }
    @objc private func openRepo() { NSWorkspace.shared.open(ProjectLinks.repo) }
    @objc private func openIssues() { NSWorkspace.shared.open(ProjectLinks.issues) }
}
