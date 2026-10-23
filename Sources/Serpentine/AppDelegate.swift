// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import SwiftUI
import Combine
import UserNotifications
import RazerProtocol
import RazerDeviceKit

/// A windowed app. The main window shows the mouse; closing it quits, unless Serpentine keeps
/// running in the background (`BackgroundMode`), when a menu bar item stays and the app leaves
/// the Dock until the window is opened again.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let controller = MouseController()
    private var cancellables = Set<AnyCancellable>()
    private var monitor: HIDMonitor?
    private var bluetoothMonitor: HIDMonitor?
    private let remapper = ButtonRemapper()
    private lazy var permissions = PermissionsModel(remapper: remapper, controller: controller)
    private let launchAtLogin = LaunchAtLogin()
    private let appearance = AppearanceSettings.shared
    private let background = BackgroundMode()
    private lazy var aboutWindow = AboutWindowController()
    private lazy var mainWindow = MainWindowController(controller: controller, remapper: remapper,
                                                       permissions: permissions, background: background,
                                                       launchAtLogin: launchAtLogin)
    private lazy var menuBarItem = MenuBarItem(
        controller: controller, openWindow: { [weak self] in self?.showMainWindow() })
    private lazy var appMenu = AppMenu(actions: .init(
        about: { [weak self] in self.map { $0.present($0.aboutWindow) } },
        settings: { [weak self] in
            self?.showMainWindow()
            self?.mainWindow.navigation.showingSettings = true
        },
        showMainWindow: { [weak self] in self?.showMainWindow() },
        refresh: { [weak self] in self?.controller.refreshAll() },
        go: { [weak self] route in
            self?.mainWindow.navigation.go(to: route)
            self?.showMainWindow()
        }))
    /// macOS started Serpentine as a login item: it starts in the menu bar, with no window.
    private var launchedAsLoginItem = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The open-application event says whether this launch is a login item's. It is only
        // there while launching, so it is read here rather than once launched.
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAsLoginItem = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // What earlier versions kept for the usage stats, the updater and the report windows.
        LegacyPreferences.remove()
        // Razer HID devices enumerate as a keyboard/mouse, so macOS gates opening them behind
        // Input Monitoring — without it the app can't read anything. The window's setup sheet
        // walks the user through it whenever it is missing. Button remapping additionally
        // needs Accessibility (optional; in the same sheet). A mouse Serpentine controls over
        // Bluetooth needs neither.
        permissions.recheck()
        // Starting at login only makes sense for an app that keeps running; the default is
        // applied only then. Explicit, not a side effect of constructing the model.
        if background.isEnabled { launchAtLogin.applyDefaultOnFirstRun() }
        LowBatteryNotifier.configureNotifications(delegate: self)
        // A manual button-remap edit (outside applying a profile) means the live config no
        // longer matches whichever profile was last applied — let MouseController know so it
        // can drop the stale "active" highlight.
        remapper.onManualChange = { [weak controller] in controller?.clearActiveProfileIfManuallyChanged() }

        // Light or dark per Settings › Appearance, re-applied when the setting or macOS's own
        // mode changes.
        Publishers.CombineLatest3(appearance.$theme, appearance.$glass,
                                  NSApp.publisher(for: \.effectiveAppearance))
            .sink { [weak self] theme, glass, system in
                let look = AppearanceLook.resolve(theme: theme, glass: glass, systemIsDark: system.isDark)
                self?.appearance.applyToWindows(look)
            }
            .store(in: &cancellables)

        // The menu bar item is there exactly while Serpentine keeps running in the background,
        // and so is the login item: starting at login is for an app that stays.
        background.$isEnabled.removeDuplicates()
            .sink { [weak self] on in
                guard let self else { return }
                self.menuBarItem.setShown(on)
                if !on, self.launchAtLogin.isEnabled { self.launchAtLogin.setEnabled(false) }
            }
            .store(in: &cancellables)

        controller.start()
        appMenu.install()
        mainWindow.onClose = { [weak self] in self?.mainWindowClosed() }
        if launchedAsLoginItem && background.isEnabled {
            NSApp.setActivationPolicy(.accessory)
        } else {
            if !permissions.allRequiredGranted { mainWindow.navigation.showingSetup = true }
            showMainWindow()
        }

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

        // The first time something only the app can do is set up, ask once whether to keep
        // running in the background. Read after the change settles, so a mouse switching (its
        // remaps loading) isn't mistaken for the user setting one up.
        remapper.$mappings.map { _ in () }
            .merge(with: remapper.$dpiCycleSoftwareAction.map { _ in () })
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] in self?.askAboutBackgroundIfNeeded() }
            .store(in: &cancellables)
    }

    // MARK: - Main window

    @objc func showMainWindow() { present(mainWindow) }

    /// Every way the app opens one of its windows goes through here. A window needs the app in
    /// the Dock, so a background app comes back to it.
    private func present(_ window: AppWindowPresenter) {
        NSApp.setActivationPolicy(.regular)
        window.show()
    }

    /// Clicking the Dock icon with no window open brings the main window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !mainWindow.isVisible { showMainWindow() }
        return true
    }

    /// Closing the last window quits, unless Serpentine keeps running in the background.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !background.isEnabled
    }

    /// Kept running: the app leaves the Dock, and the menu bar item is the way back.
    private func mainWindowClosed() {
        guard background.isEnabled,
              !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - Background mode

    private func askAboutBackgroundIfNeeded() {
        guard !background.isEnabled, !background.hasAsked else { return }
        let features = DriverModeUsage.features(controller: controller, remapper: remapper)
        guard !features.isEmpty else { return }
        background.hasAsked = true
        let alert = NSAlert()
        alert.messageText = "Keep Serpentine running in the background?"
        alert.informativeText = "Your mouse keeps most settings itself, but these only work while Serpentine "
            + "runs:\n\n• " + features.joined(separator: "\n• ")
            + "\n\nIn the background Serpentine has a small menu bar item and no window. "
            + "You can change this in Settings."
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "Not Now")
        let answer: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            if response == .alertFirstButtonReturn { self?.background.isEnabled = true }
        }
        if let window = mainWindow.nsWindow, window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: answer)
        } else {
            answer(alert.runModal())
        }
    }

    // MARK: - Foreground

    /// Re-check permissions when the app returns to the foreground — e.g. the user just toggled
    /// a grant in System Settings and switched back, so the setup sheet reflects it live.
    func applicationDidBecomeActive(_ notification: Notification) {
        permissions.recheck()
        // Same reason as the permission recheck: the user may have just flipped the
        // Notifications switch — or Serpentine's Login Items entry — in System Settings and
        // come back.
        controller.refreshNotificationAuthorization()
        launchAtLogin.refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.invalidate()
        controller.flushHistoryToDisk()
    }

    // MARK: - Notifications

    /// Present the low-battery banner even while Serpentine is frontmost (the default is to
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
