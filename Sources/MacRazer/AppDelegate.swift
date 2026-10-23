// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import SwiftUI
import Combine
import UserNotifications

/// Menu bar (accessory) app: an NSStatusItem showing battery %, click opens an NSPopover
/// hosting the SwiftUI controls. Mirrors the pattern macOS's own Bluetooth/Battery menus use.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let controller = MouseController()
    private var cancellables = Set<AnyCancellable>()
    private var monitor: HIDMonitor?
    private var bluetoothMonitor: HIDMonitor?
    private let remapper = ButtonRemapper()
    private lazy var remapWindow = RemapWindowController(remapper: remapper, controller: controller)
    private lazy var permissions = PermissionsModel(remapper: remapper, controller: controller)
    private lazy var permissionsWindow = PermissionsWindowController(model: permissions, controller: controller)
    private let launchAtLogin = LaunchAtLogin()
    private let appearance = AppearanceSettings.shared
    /// The solid colour or green tint behind the popover; see `PopoverBackdropView`.
    private let popoverBackdrop = PopoverBackdropView()
    private lazy var aboutWindow = AboutWindowController()
    private lazy var settingsWindow = SettingsWindowController(
        controller: controller, launchAtLogin: launchAtLogin)
    /// The app the user was in when the popover opened, so closing it can hand focus back.
    /// See `PopoverFocusReturn` for when it does.
    private var appBeforePopover: NSRunningApplication?
    /// Set whenever one of the app's windows is asked for; cleared when the popover opens.
    /// Catches a window that was already open behind another app being brought back, which
    /// `windowsBeforePopover` alone cannot see.
    private var windowRequested = false
    /// Every window, including system panels, already on screen when the popover opened, so
    /// its close can tell whether it led somewhere new. The colour picker's panel is the case
    /// that needs it: it is not one of the app's windows and does not go through `present`.
    private var windowsBeforePopover: Set<ObjectIdentifier> = []
    /// True while the right-click menu is being tracked.
    private var appMenuOpen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // What earlier versions kept for the usage stats, the updater and the report windows.
        LegacyPreferences.remove()
        // Razer HID devices enumerate as a keyboard/mouse, so macOS gates opening them behind
        // Input Monitoring — without it the app can't read anything. Show the setup window
        // whenever that required permission is missing (and stop the moment it's granted), so a
        // user without it is always walked through it rather than left with a silently-dead app.
        // Button remapping additionally needs Accessibility (optional; surfaced in the same window).
        // A mouse MacRazer controls over Bluetooth needs neither, so it doesn't trigger the window.
        permissions.recheck()
        // Explicit, not a side effect of constructing the model — see the doc comment there.
        launchAtLogin.applyDefaultOnFirstRun()
        LowBatteryNotifier.configureNotifications(delegate: self)
        // A manual button-remap edit (outside applying a profile) means the live config no
        // longer matches whichever profile was last applied — let MouseController know so it
        // can drop the stale "active" highlight.
        remapper.onManualChange = { [weak controller] in controller?.clearActiveProfileIfManuallyChanged() }
        if !permissions.allRequiredGranted {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.present(self.permissionsWindow)
            }
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = menuBarIcon(charging: false)
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.imageHugsTitle = true
        statusItem.button?.title = " …"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        // Receive both clicks so we can branch: left → popover, right → app menu.
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        popover.behavior = .transient
        popover.delegate = self
        popover.animates = false // open immediately, no slide animation
        // Light or dark, glass or solid, per Settings › Appearance. Re-applied whenever the
        // setting changes or macOS switches between light and dark, including while the
        // popover is open. The popover's appearance is always set explicitly, never left nil:
        // a nil one would follow the menu bar, which macOS tints from the wallpaper rather
        // than the system's light or dark mode.
        Publishers.CombineLatest3(appearance.$theme, appearance.$glass,
                                  NSApp.publisher(for: \.effectiveAppearance))
            .sink { [weak self] theme, glass, system in
                self?.applyAppearance(theme: theme, glass: glass, systemIsDark: system.isDark)
            }
            .store(in: &cancellables)
        let hosting = NSHostingController(rootView: PopoverView(
            controller: controller, remapper: remapper,
            launchAtLogin: launchAtLogin, appearance: appearance,
            onOpenSettings: { [weak self] in
                // Close first: the popover is transient and would dismiss itself the moment
                // the window takes focus, which looks like the click did two things.
                guard let self else { return }
                self.popover.performClose(nil)
                self.present(self.settingsWindow)
            }))
        hosting.sizingOptions = [.preferredContentSize] // popover auto-fits the SwiftUI content
        popover.contentViewController = hosting

        // Pre-warm: force the SwiftUI hierarchy (incl. the AppKit-backed slider/pickers/colour
        // picker) to build and lay out now, so the first click opens instantly instead of
        // paying that cost on the first show.
        let warm = hosting.view
        warm.frame = NSRect(x: 0, y: 0, width: 300, height: 520)
        warm.layoutSubtreeIfNeeded()
        if let rep = warm.bitmapImageRepForCachingDisplay(in: warm.bounds) {
            warm.cacheDisplay(in: warm.bounds, to: rep)
        }

        // Mirror the controller's status text onto the menu bar title.
        controller.$statusText
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] text in self?.statusItem.button?.title = text }
            .store(in: &cancellables)

        // Swap the mark for its bolt variant while the mouse is on the charger — the same
        // at-a-glance cue macOS gives for its own battery, without needing the popover.
        // Only the two states exist, so the images are cached rather than redrawn per event.
        controller.$charging
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] charging in
                self?.statusItem.button?.image = self?.menuBarIcon(charging: charging)
            }
            .store(in: &cancellables)

        // When disconnected, keep the icon's normal adaptive (template) colour but dim it via
        // opacity — a fixed grey tint disappears against a dark menu bar, whereas a dimmed
        // white/black reads as a clearly-visible lighter grey in both light and dark.
        controller.$connected
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] connected in
                self?.statusItem.button?.contentTintColor = nil
                self?.statusItem.button?.alphaValue = connected ? 1.0 : 0.6
            }
            .store(in: &cancellables)

        controller.start()

        // Instant plug/unplug detection via IOKit; polling remains the fallback for the
        // wireless-sleep case where the dongle stays present.
        let ctrl = controller
        monitor = HIDMonitor(
            vendorId: Razer.vendorId,
            // Small settle delay on appear so the dongle has re-probed before the first read
            // (avoids a transient 0% right after reconnect).
            onAppear: { _ in DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { ctrl.forceCheck(immediateOffline: false) } },
            onRemove: { pids in
                // Only the connected device's removal is definitive. Matching is vendor-wide,
                // so unplugging a Razer keyboard (or a different-model mouse) fires this too —
                // that must not bypass the offline debounce, or a coincidental wireless
                // timeout at that moment flaps the mouse to "offline" with the disconnect
                // sound. PID granularity can't tell two units of the same model apart, and
                // unknown PIDs (property read failed) are treated as ours — both err on the
                // conservative side (a spurious immediate check self-corrects next poll).
                let mine = ctrl.deviceID.map { pids.isEmpty || pids.contains($0) } ?? false
                ctrl.forceCheck(immediateOffline: mine)
            }
        )

        // A Basilisk on Bluetooth enumerates under Razer's BLE vendor id (0x068E), not the
        // USB id above. An appearance starts recovery but keeps a healthy GATT session;
        // only an observed removal invalidates it before the next probe.
        bluetoothMonitor = HIDMonitor(
            vendorId: BLEProtocol.vendorId,
            onAppear: { pids in
                guard pids.isEmpty || pids.contains(where: RazerDevices.bluetoothPIDs.contains) else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    ctrl.beginBluetoothWakeRecovery()
                }
            },
            onRemove: { pids in
                guard pids.contains(where: RazerDevices.bluetoothPIDs.contains) else { return }
                DispatchQueue.main.async { ctrl.beginBluetoothWakeRecovery(discardBluetoothSession: true) }
            }
        )

        remapper.start()
        remapper.observeDpiCycle(controller: controller)

        // Load the connected mouse's own button mappings when the device changes (per-unit key).
        controller.$deviceKey
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] key in self?.remapper.setActiveDevice(key) }
            .store(in: &cancellables)

        // Pause remapping while the mouse is offline (powered off, asleep, dongle pulled) —
        // the tap can't tell devices apart, so an offline mouse's mappings would otherwise
        // keep firing for matching buttons on other pointing devices.
        controller.$connected
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] connected in self?.remapper.remappingPaused = !connected }
            .store(in: &cancellables)
        // A mapped button pressed while paused usually means the mouse just woke. Check now
        // rather than at the next poll, so its mappings come back straight away.
        remapper.onPressWhilePaused = { [weak controller] in controller?.checkIfOffline() }

        // Remaps saved in the mouse (`OnboardButtons`): each change of the remap table, or of
        // the connected mouse, is written into the mouse. Debounced, and read at the time it
        // fires, so the brief empty table of a mouse switch is never written.
        // The mouse switched profiles by itself: its remaps come along.
        controller.onSlotProfileFollowed = { [weak self] profile in self?.remapper.setMappings(profile.buttonMappings) }
        // The remaps read from the mouse on connecting (set on another computer, or before
        // this install) replace the ones shown, when they are still that mouse's.
        controller.onOnboardMappingsRead = { [weak self] deviceKey, mappings in
            guard let self, self.remapper.activeDeviceKey == deviceKey else { return }
            self.remapper.setMappings(mappings)
        }
        remapper.$mappings
            .combineLatest(controller.$deviceID)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _, _ in
                guard let self else { return }
                self.controller.setOnboardMappings(self.remapper.mappings, deviceKey: self.remapper.activeDeviceKey)
            }
            .store(in: &cancellables)
    }

    // MARK: - Click handling

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        if isRightClick {
            showAppMenu()
        } else {
            togglePopover()
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // Remember where focus came from, so closing can hand it back. Not overwritten when
            // MacRazer is already frontmost: "Open Controls" from the right-click menu reopens
            // the popover mid-session, and the app to go back to is still the earlier one.
            if let front = NSWorkspace.shared.frontmostApplication,
               front.processIdentifier != NSRunningApplication.current.processIdentifier {
                appBeforePopover = front
            }
            windowRequested = false
            windowsBeforePopover = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
            // Show first (instant), then kick off the refresh so the open never waits on IO.
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // The frame view the backdrop lives in only exists once the popover is shown.
            installPopoverBackdrop()
            // Activate, not just make key. This app has no Dock icon, so clicking the menu bar
            // item does not make it the active application, and a control in an inactive app's
            // window does not respond to the first click the way it looks like it should. Every
            // other window here already does this; the popover was the one that did not.
            // The cost is that the app keeps focus once the popover closes, which
            // `returnFocusAfterPopover` gives back.
            NSApp.activate(ignoringOtherApps: true)
            popover.contentViewController?.view.window?.makeKey()
            controller.refreshAll()
        }
    }

    // MARK: - App menu (right-click)

    private func showAppMenu() {
        // Held for the whole of the tracking below, so a popover closing on the way here does
        // not hand focus to another app, which would dismiss this menu. See
        // `returnFocusAfterPopover`.
        appMenuOpen = true
        if popover.isShown { popover.performClose(nil) }

        let menu = NSMenu()

        // First, where macOS puts About in an app menu — above the device header, which is a
        // title for the items below it rather than an item itself.
        let about = NSMenuItem(title: "About MacRazer", action: #selector(openAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        menu.addItem(.separator())

        let status = NSMenuItem(title: appMenuStatusTitle(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let open = NSMenuItem(title: "Open Controls", action: #selector(togglePopover), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        let configure = NSMenuItem(title: "Configure Buttons…", action: #selector(openRemap), keyEquivalent: "")
        configure.target = self
        configure.isEnabled = controller.connected // remapping is for a connected mouse
        menu.addItem(configure)

        let setup = NSMenuItem(title: "Setup & Permissions…", action: #selector(openPermissions), keyEquivalent: "")
        setup.target = self
        menu.addItem(setup)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit MacRazer", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        // Pop the menu just below the status item.
        if let button = statusItem.button {
            let origin = NSPoint(x: 0, y: button.bounds.height + 5)
            menu.popUp(positioning: nil, at: origin, in: button)
        }
        appMenuOpen = false
        // Tracking is over, so the choice is made: reopening the popover, opening a window, or
        // nothing. Deferred a turn for the same reason as `popoverDidClose`: the answer is read
        // after the chosen item has acted, rather than raced against it.
        DispatchQueue.main.async { [weak self] in self?.returnFocusAfterPopover() }
    }

    private func appMenuStatusTitle() -> String {
        let name = controller.deviceName ?? "No mouse connected"
        guard controller.connected, let pct = controller.batteryPercent else {
            return name
        }
        return "\(name) · \(pct)%" + (controller.charging ? " (charging)" : "")
    }

    @objc private func refreshNow() { controller.refreshAll() }
    @objc private func openRemap() { present(remapWindow) }
    @objc private func openSettings() { present(settingsWindow) }
    @objc private func openAbout() { present(aboutWindow) }

    /// Every way the app opens one of its windows goes through here. Marks the request, so a
    /// popover closing on the way to the window keeps focus instead of handing it back.
    private func present(_ window: AppWindowPresenter) {
        windowRequested = true
        window.show()
    }

    @objc private func openPermissions() { present(permissionsWindow) }
    @objc private func quit() { NSApplication.shared.terminate(nil) }

    // MARK: - Appearance

    private func applyAppearance(theme: PopoverTheme, glass: Bool, systemIsDark: Bool) {
        let look = PopoverLook.resolve(theme: theme, glass: glass, systemIsDark: systemIsDark)
        popover.appearance = NSAppearance(named: look.appearanceName)
        popoverBackdrop.fill = look.backdropColor
        appearance.applyToWindows(look)
    }

    /// Puts the backdrop into the popover's frame view, just under the content: above the
    /// native material, so a solid colour hides it, and filling the arrow too. NSPopover
    /// keeps its frame view between shows, so this only does work the first time.
    private func installPopoverBackdrop() {
        guard let content = popover.contentViewController?.view,
              let frameView = content.superview,
              popoverBackdrop.superview !== frameView else { return }
        popoverBackdrop.frame = frameView.bounds
        popoverBackdrop.autoresizingMask = [.width, .height]
        frameView.addSubview(popoverBackdrop, positioned: .below, relativeTo: content)
    }

    // MARK: - NSPopoverDelegate

    func popoverDidShow(_ notification: Notification) { controller.setPopoverVisible(true) }
    func popoverDidClose(_ notification: Notification) {
        controller.setPopoverVisible(false)
        // Deferred a turn so the answer is a fact rather than a race: by the next runloop turn
        // the window the close was for has come up, or it has not.
        DispatchQueue.main.async { [weak self] in self?.returnFocusAfterPopover() }
    }

    // MARK: - Popover focus

    /// Hands keyboard focus back to the app the user was in, when the popover session is over
    /// and nothing says to stay. Called a turn after each way that session can end: the popover
    /// closing, and the right-click menu finishing. See `PopoverFocusReturn` for the rules.
    private func returnFocusAfterPopover() {
        let previous = appBeforePopover.flatMap { $0.isTerminated ? nil : $0 }
        let popoverWindow = popover.contentViewController?.view.window
        let somethingNewOnScreen = NSApp.windows.contains {
            $0.isVisible && $0 !== popoverWindow && !windowsBeforePopover.contains(ObjectIdentifier($0))
        }
        let verdict = PopoverFocusReturn.verdict(.init(
            appMenuOpen: appMenuOpen,
            popoverShown: popover.isShown,
            windowOpened: windowRequested || somethingNewOnScreen,
            appIsActive: NSApp.isActive,
            hasPreviousApp: previous != nil))
        switch verdict {
        case .wait:
            return
        case .stay:
            appBeforePopover = nil
        case .returnFocus:
            appBeforePopover = nil
            guard let previous else { return }
            // Cooperative activation, the way macOS 14 expects it: the active app yields, and
            // the target takes activation from it.
            NSApp.yieldActivation(to: previous)
            _ = previous.activate(from: .current, options: [])
        }
    }

    // MARK: - Foreground

    /// Re-check permissions when the app returns to the foreground — e.g. the user just toggled
    /// a grant in System Settings and switched back, so the setup window reflects it live.
    func applicationDidBecomeActive(_ notification: Notification) {
        permissions.recheck()
        // Same reason as the permission recheck: the user may have just flipped the
        // Notifications switch — or MacRazer's Login Items entry — in System Settings and
        // come back.
        controller.refreshNotificationAuthorization()
        launchAtLogin.refresh()
    }

    /// Another app took focus. A hand-back still pending from the popover must not take it
    /// back: whatever the user just moved to wins.
    func applicationDidResignActive(_ notification: Notification) {
        appBeforePopover = nil
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.invalidate()
        controller.flushHistoryToDisk()
    }

    // MARK: - Menu bar mark

    /// The status-item marks, drawn once each. Neither has to be redrawn for the menu bar's
    /// appearance: the idle one is a template image macOS recolours itself, and the charging
    /// one resolves its colours whenever it is drawn (see `MenuBarIcon.chargingBody`).
    ///
    /// So nothing here watches `effectiveAppearance`, on purpose. Setting the image makes
    /// AppKit report that property as changed whether or not it did, and a watcher that sets
    /// the image in response never stops (issue #25).
    private static let idleIcon = MenuBarIcon.mouse(pointSize: 21, razerCutout: false)
    private static let chargingIcon = MenuBarIcon.mouse(pointSize: 21, razerCutout: false, charging: true)

    private func menuBarIcon(charging: Bool) -> NSImage {
        charging ? Self.chargingIcon : Self.idleIcon
    }

    // MARK: - Notifications

    /// Present the low-battery banner even while MacRazer is frontmost (the default is to
    /// suppress it, which would silently swallow the alert).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    // MARK: - Input Monitoring permission

    static func openInputMonitoringSettings() { SystemSettingsPanes.openInputMonitoring() }
}
