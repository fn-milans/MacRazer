// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import Combine
import ApplicationServices
import CoreGraphics
import RazerProtocol

// MARK: - DPI Cycle software actions

/// The Basilisk V3 X HyperSpeed's DPI Cycle button, bridged to a software action over F20.
extension ButtonRemapper {
    /// F20 is reserved only after the connected Basilisk has confirmed the corresponding
    /// onboard assignment. The event tap includes keyboard events only while this model has a
    /// saved software action; ordinary users keep a mouse-only tap.
    func observeDpiCycle(controller: MouseController) {
        dpiObservers.removeAll()
        controller.$deviceKey.combineLatest(controller.$deviceID)
            .combineLatest(controller.$deviceIsBluetooth)
            .combineLatest(controller.$connected)
            .receive(on: RunLoop.main)
            .sink { [weak self, weak controller] state in
                let (((key, deviceID), bluetooth), connected) = state
                guard let self else { return }
                self.setActiveDevice(key, deviceID: deviceID)
                self.remappingPaused = !connected
                self.installTapIfNeeded()
                if !connected {
                    self.dpiBridgeBindingConfirmed = false
                    self.dpiBridgeReadRequested = false
                    self.dpiBridgeRestoreAttempted = false
                } else if bluetooth, deviceID.map(RazerDevices.supportsDpiButtonBinding(pid:)) == true,
                          !self.dpiBridgeReadRequested {
                    self.dpiBridgeReadRequested = true
                    controller?.refreshDpiCycleButtonBinding()
                }
            }.store(in: &dpiObservers)

        controller.$wakeRecoveryCounter
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self, weak controller] _ in
                guard let self, let controller, controller.connected, controller.deviceIsBluetooth,
                      controller.deviceID.map(RazerDevices.supportsDpiButtonBinding(pid:)) == true else { return }
                // A wake can preserve the BLE session, so the connected observer above does
                // not fire. Re-read once in case firmware reset the physical assignment.
                self.dpiBridgeRestoreAttempted = false
                self.dpiBridgeReadRequested = false
                controller.refreshDpiCycleButtonBinding()
            }.store(in: &dpiObservers)

        controller.$dpiCycleButtonBinding
            .combineLatest(controller.$deviceIsBluetooth)
            .combineLatest(controller.$isUpdatingDpiCycleButton)
            .combineLatest(controller.$connected)
            .combineLatest(controller.$dpiCycleButtonError)
            .receive(on: RunLoop.main)
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self, weak controller] state in
                let (((bindingState, updating), connected), error) = state
                let (binding, bluetooth) = bindingState
                guard let self else { return }
                self.confirmDpiBridge(binding: bluetooth ? binding : nil)
                guard let controller, connected, bluetooth, self.isBasiliskV3XHyperSpeed,
                      !updating, error == nil,
                      self.shouldRestoreDpiBridge(binding: binding,
                                                  connected: connected,
                                                  bluetooth: bluetooth,
                                                  alreadyAttempted: self.dpiBridgeRestoreAttempted),
                      let action = self.dpiCycleSoftwareAction else { return }
                self.dpiBridgeRestoreAttempted = true
                self.configureDpiCycle(.softwareBridge, softwareAction: action, controller: controller)
            }.store(in: &dpiObservers)
    }

    func confirmDpiBridge(binding: BLEProtocol.DPIButtonBinding?) {
        dpiBridgeBindingConfirmed = isBasiliskV3XHyperSpeed && binding == .softwareBridge
    }

    func shouldRestoreDpiBridge(binding: BLEProtocol.DPIButtonBinding?, connected: Bool,
                                bluetooth: Bool, alreadyAttempted: Bool) -> Bool {
        // `binding` must have been read from the mouse: nil means "not known yet" (after a
        // reconnect), and restoring then would write before the fresh read.
        isBasiliskV3XHyperSpeed && connected && bluetooth && !alreadyAttempted
            && binding != nil && binding != .softwareBridge && dpiCycleSoftwareAction != nil
    }

    func configureDpiCycle(_ binding: BLEProtocol.DPIButtonBinding,
                           softwareAction: RemapAction? = nil, controller: MouseController) {
        guard softwareAction == nil || remappingPermissionsGranted else { return }
        dpiBridgeBindingConfirmed = false
        controller.setDpiCycleButtonBinding(binding) { [weak self] success in
            guard success, let self else { return }
            self.saveDpiSoftwareAction(softwareAction)
            self.confirmDpiBridge(binding: binding)
        }
    }

    func dpiCycleLabel(for binding: BLEProtocol.DPIButtonBinding) -> String {
        if binding == .softwareBridge {
            return dpiCycleSoftwareAction.map { $0.label + " (Serpentine)" } ?? "Serpentine action (choose…)"
        }
        return binding.label
    }

    func saveDpiSoftwareAction(_ action: RemapAction?) {
        guard isBasiliskV3XHyperSpeed else { return }
        let previous = dpiCycleSoftwareAction
        dpiCycleSoftwareAction = action
        let key = Preferences.Device.dpiCycleSoftwareAction(activeKey)
        if let action, let data = try? JSONEncoder().encode(action) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
        installTapIfNeeded()
        if action != previous { onManualChange?() }
    }

    func loadDpiSoftwareAction() {
        dpiCycleSoftwareAction = nil
        guard isBasiliskV3XHyperSpeed,
              let data = defaults.data(forKey: Preferences.Device.dpiCycleSoftwareAction(activeKey)) else { return }
        dpiCycleSoftwareAction = try? JSONDecoder().decode(RemapAction.self, from: data)
    }

    var dpiBridgeStatus: String {
        if !remappingPermissionsGranted { return "Input capture unavailable" }
        if !keyboardCaptureAvailable { return "Keyboard capture is blocked. Refresh Input Monitoring, then relaunch." }
        if remappingPaused { return "Waiting for mouse connection" }
        if !dpiBridgeBindingConfirmed { return "Waiting for button assignment verification" }
        return "Ready"
    }

    func handleDpiBridge(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard event.getIntegerValueField(.keyboardEventKeycode) == 90 else {
            return Unmanaged.passUnretained(event)
        }
        if type == .keyUp, bridgeKeyIsDown {
            bridgeKeyIsDown = false
            return nil
        }
        let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        guard type == .keyDown, isBasiliskV3XHyperSpeed, dpiBridgeBindingConfirmed,
              !remappingPaused, event.flags.intersection(modifiers).isEmpty,
              let action = dpiCycleSoftwareAction else { return Unmanaged.passUnretained(event) }
        if !bridgeKeyIsDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            lastDetectedButton = -1
            apply(action)
        }
        bridgeKeyIsDown = true
        return nil
    }
}
