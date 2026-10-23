// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation
import AppKit
import CoreBluetooth
import RazerProtocol
import RazerDeviceKit

// MARK: - Settings writes

/// DPI, stages, polling rate, sleep timer, the wheel and the DPI Cycle button.
extension MouseController {
    func setSmartReel(_ on: Bool) {
        writeWheelSetting(RazerCommands.setScrollSmartReel(on)) { $0.smartReel = on }
    }

    func setSmartReelSensitivity(_ level: Int) {
        writeWheelSetting(RazerCommands.setSmartReelSensitivity(level)) { $0.smartReelSensitivity = level }
    }

    func setScrollAcceleration(_ on: Bool) {
        writeWheelSetting(RazerCommands.setScrollAcceleration(on)) { $0.scrollAcceleration = on }
    }

    func setScrollAccelerationLevel(_ level: Int) {
        writeWheelSetting(RazerCommands.setScrollAccelerationLevel(level)) { $0.scrollAccelerationLevel = level }
    }

    /// Sends one wheel setting and shows it once the mouse has taken it.
    func writeWheelSetting(_ report: RazerReport, onSuccess: @escaping @Sendable (MouseController) -> Void) {
        io.user { [weak self] in
            guard let self else { return }
            let ok = (try? self.ensureDevice().sendWithRetry(report)) != nil
            self.publish {
                guard ok else { self.lastWriteFailure = Date(); return }
                onSuccess(self)
            }
        }
    }

    /// Writes the threshold and reads it back, since the mouse keeps the nearest step of its
    /// 0-255 scale.
    func setLowBatteryThreshold(_ percent: Int) {
        io.user { [weak self] in
            guard let self else { return }
            let dev = try? self.ensureDevice()
            let readBack = dev.flatMap { dev -> Int? in
                guard (try? dev.sendWithRetry(RazerCommands.setLowBatteryThreshold(percent: percent))) != nil else { return nil }
                return (try? dev.sendWithRetry(RazerCommands.getLowBatteryThreshold())).map(RazerCommands.parseLowBatteryThreshold)
            }
            self.publish {
                guard let readBack, readBack == percent else { self.lastWriteFailure = Date(); return }
                self.lowBatteryThreshold = readBack
            }
        }
    }

    // Setters publish (and un-mark the active profile) only when the device write actually
    // succeeded — publishing optimistically would show the new value in the UI while the
    // mouse keeps its old config, and the next settings poll corrects it confusingly.

    func setDPI(_ value: Int) {
        let v = UInt16(max(100, min(value, RazerCommands.dpiCeiling)))
        io.user { [weak self] in
            guard let self else { return }
            let ok = (try? self.ensureDevice().sendWithRetry(RazerCommands.setDPI(x: v, y: v))) != nil
            self.publish {
                guard ok else { self.lastWriteFailure = Date(); return }
                self.dpi = Int(v); self.clearActiveProfileIfNeeded()
            }
        }
    }

    /// Writes the whole stage table: one value for Single mode, five for Stages, with
    /// `active` the stage in use. The table is the one place every link keeps DPI in the
    /// active slot, so this is how a mouse with DPI modes sets any DPI. Writing it moves the
    /// live DPI to the active stage (Basilisk V4 Pro, over the dongle and Bluetooth). Over
    /// USB the table is read back before anything is published; Bluetooth verifies its own
    /// write (`BluetoothDevice`).
    func setDPITable(_ values: [Int], active: Int) {
        guard supportsDpiModes, !values.isEmpty, values.count <= RazerCommands.maxDPIStages else { return }
        let table = values.map { max(100, min($0, deviceMaxDPI)) }
        let active = max(0, min(active, table.count - 1))
        isUpdatingDpiStages = true
        dpiStagesError = nil
        io.user { [weak self] in
            guard let self else { return }
            do {
                let dev = try self.ensureDevice()
                let fromOne = RazerDevices.dpiStagesCountFromOne(pid: dev.productID)
                _ = try dev.sendWithRetry(RazerCommands.setDPIStages(table, activeStage: active, countFromOne: fromOne))
                if !dev.isBluetooth {
                    let back = try dev.sendWithRetry(RazerCommands.getDPIStages())
                    guard RazerCommands.parseDPIStages(back) == table,
                          RazerCommands.parseActiveDPIStage(back, countFromOne: fromOne) == active else { throw HIDDevice.HIDError.commandFailed }
                }
                self.publish {
                    self.dpiStages = table
                    self.activeDpiStage = active
                    self.dpi = table[active]
                    self.isUpdatingDpiStages = false
                    self.dpiStagesError = nil
                    self.clearActiveProfileIfNeeded()
                }
            } catch {
                self.publish {
                    self.isUpdatingDpiStages = false
                    self.dpiStagesError = "DPI could not be verified: \(error.localizedDescription)"
                    self.lastWriteFailure = Date()
                }
            }
        }
    }

    /// Changes one stage's DPI. The table is read from the mouse right before the write, so
    /// the active stage and the other stages are whatever the mouse holds now: the published
    /// copy can be up to one settings refresh old, and writing it back would undo a press of
    /// the mouse's DPI button made in the meantime.
    func setDPIStageValue(_ value: Int, at index: Int) {
        guard capabilities.stageEditingOverBluetooth else { return }
        let dpiValue = max(100, min(value, deviceMaxDPI))
        isUpdatingDpiStages = true
        dpiStagesError = nil
        io.user { [weak self] in
            guard let self else { return }
            do {
                guard let bluetooth = try self.ensureDevice().bluetoothDevice,
                      RazerDevices.supportsStageEditing(pid: bluetooth.productID) else { throw HIDDevice.HIDError.notSupported }
                var table = try bluetooth.readDpiStages()
                guard table.values.indices.contains(index) else { throw HIDDevice.HIDError.badResponse }
                table.values[index] = dpiValue
                try bluetooth.setDpiStages(table)
                let written = table
                self.publish {
                    self.dpiStages = written.values
                    self.activeDpiStage = written.active
                    self.dpi = written.values[written.active]
                    self.isUpdatingDpiStages = false
                    self.dpiStagesError = nil
                    self.clearActiveProfileIfNeeded()
                }
            } catch {
                self.publish {
                    self.isUpdatingDpiStages = false
                    self.dpiStagesError = "DPI stages could not be verified: \(error.localizedDescription)"
                    self.lastWriteFailure = Date()
                }
            }
        }
    }

    /// The mouse's own sleep timer: over Bluetooth on the mice that have one there, and over
    /// the dongle and cable (0x07/0x83), on the mice whose row says so.
    var supportsSleepTimeout: Bool { capabilities.sleepTimeout }

    func setSleepTimeout(_ seconds: Int) {
        guard supportsSleepTimeout, BLEProtocol.sleepTimeoutPayload(seconds: seconds) != nil else { return }
        isUpdatingSleepTimeout = true
        sleepTimeoutError = nil
        io.user { [weak self] in
            guard let self else { return }
            do {
                let dev = try self.ensureDevice()
                if let bluetooth = dev.bluetoothDevice {
                    guard RazerDevices.supportsSleepTimeout(pid: bluetooth.productID) else { throw HIDDevice.HIDError.notSupported }
                    try bluetooth.setSleepTimeout(seconds)
                } else {
                    guard RazerDevices.supportsSleepTimeout(pid: dev.productID) else { throw HIDDevice.HIDError.notSupported }
                    _ = try dev.sendWithRetry(RazerCommands.setIdleTime(seconds: seconds))
                    guard RazerCommands.parseIdleTime(try dev.sendWithRetry(RazerCommands.getIdleTime())) == seconds
                    else { throw HIDDevice.HIDError.commandFailed }
                }
                self.publish {
                    self.sleepTimeout = seconds
                    self.isUpdatingSleepTimeout = false
                    self.sleepTimeoutError = nil
                }
            } catch {
                self.publish {
                    self.isUpdatingSleepTimeout = false
                    self.sleepTimeoutError = "Sleep timeout could not be verified: \(error.localizedDescription)"
                    self.lastWriteFailure = Date()
                }
            }
        }
    }

    func refreshDpiCycleButtonBinding() {
        io.user { [weak self] in
            guard let self else { return }
            self.publish {
                self.isUpdatingDpiCycleButton = true
                self.dpiCycleButtonError = nil
            }
            do {
                guard let bluetooth = try self.ensureDevice().bluetoothDevice,
                      RazerDevices.supportsDpiButtonBinding(pid: bluetooth.productID) else {
                    throw HIDDevice.HIDError.notSupported
                }
                let binding = try bluetooth.readDpiCycleBinding()
                self.publish {
                    self.dpiCycleButtonBinding = binding
                    self.dpiCycleButtonError = nil
                    self.isUpdatingDpiCycleButton = false
                }
            } catch {
                self.publish {
                    self.dpiCycleButtonError = "Could not read this button over Bluetooth: \(error.localizedDescription)"
                    self.isUpdatingDpiCycleButton = false
                }
            }
        }
    }

    func setDpiCycleButtonBinding(_ binding: BLEProtocol.DPIButtonBinding,
                                  completion: @escaping @Sendable (Bool) -> Void = { _ in }) {
        io.user { [weak self] in
            guard let self else { return }
            self.publish {
                self.isUpdatingDpiCycleButton = true
                self.dpiCycleButtonError = nil
            }
            do {
                guard let bluetooth = try self.ensureDevice().bluetoothDevice,
                      RazerDevices.supportsDpiButtonBinding(pid: bluetooth.productID) else {
                    throw HIDDevice.HIDError.notSupported
                }
                // Throws unless the mouse reads back exactly this binding.
                try bluetooth.setDpiCycleBinding(binding)
                self.publish {
                    self.dpiCycleButtonBinding = binding
                    self.dpiCycleButtonError = nil
                    self.isUpdatingDpiCycleButton = false
                    completion(true)
                }
            } catch {
                self.publish {
                    self.dpiCycleButtonError = "Button assignment failed or did not read back: \(error.localizedDescription)"
                    self.isUpdatingDpiCycleButton = false
                    self.lastWriteFailure = Date()
                    completion(false)
                }
            }
        }
    }

    func setPollRate(_ hz: Int) {
        io.user { [weak self] in
            guard let self else { return }
            let ok = (try? self.ensureDevice()).map { Self.sendPollingRate(hz, to: $0) } ?? false
            self.publish {
                guard ok else { self.lastWriteFailure = Date(); return }
                self.pollRate = hz; self.clearActiveProfileIfNeeded()
            }
        }
    }

    /// io-queue only. Sets the polling rate with the command this mouse takes
    /// (`RazerCommands.setPollingRateReports`). A polling_rate2 mouse is read back, and that
    /// read decides: through the dongle the second report addresses the dongle itself, and
    /// what counts is the rate the mouse ends up at, not each report's status.
    static func sendPollingRate(_ hz: Int, to dev: any RazerTransport) -> Bool {
        guard !dev.isBluetooth, RazerDevices.usesPollingRate2(pid: dev.productID) else {
            return (try? dev.sendWithRetry(RazerCommands.setPollingRate(hz))) != nil
        }
        for report in RazerCommands.setPollingRateReports(hz, pid: dev.productID) {
            _ = try? dev.sendWithRetry(report)
        }
        let read = RazerCommands.pollingRateRead(pid: dev.productID)
        return (try? dev.sendWithRetry(read.report)).map(read.parse) == hz
    }
}
