// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation
import AppKit
import CoreBluetooth
import RazerProtocol
import RazerDeviceKit

// MARK: - Previews

/// Plausible state for the `render-ui` commands; no device needed.
extension MouseController {
    /// Populate plausible state for the `render-ui` preview command (no device needed).
    /// `render-ui zones`: a Basilisk V4 Pro, its zones lit differently.
    func setPreviewZonedLighting() {
        deviceName = "Razer Basilisk V4 Pro"
        deviceID = 0x00E3
        let green = RGB(r: 0x44, g: 0xD6, b: 0x2C)
        showZoneLighting([
            .logo: ZoneLighting(effect: .staticColor, color: green, brightness: 33),
            .scrollWheel: ZoneLighting(effect: .breathing, color: RGB(r: 0xFF, g: 0, b: 0), brightness: 33),
            .underglow: ZoneLighting(effect: .spectrum, color: green, brightness: 33),
        ])
    }

    func loadPreviewState() {
        connected = true
        deviceName = "Razer Cobra HyperSpeed"
        deviceID = 0x00DB
        batteryPercent = 72
        charging = false
        dpi = 1600
        pollRate = 1000
        timeEstimate = "~3d 0h left (est.)" // matches BatteryHistory.estimateString's real format
        let now = Date()
        batterySamples = stride(from: 0, through: 28, by: 1).map {
            BatterySample(t: now.addingTimeInterval(Double($0) * -3600), pct: min(100, 2 + $0 * 4))
        }.reversed()
        // The charge before it (dimmed context on the usage chart), with a 2h charge gap.
        let previousEnd = now.addingTimeInterval(-30 * 3600)
        previousCycleSamples = stride(from: 0, through: 24, by: 1).map {
            BatterySample(t: previousEnd.addingTimeInterval(Double($0) * -3600), pct: min(100, 8 + $0 * 4))
        }.reversed()
        dischargeRatePerHour = 1.0
        cycleStartedAt = batterySamples.first?.t
        cycleStartedPercent = batterySamples.first?.pct
        pastCycles = (1...6).map { i in
            let end = now.addingTimeInterval(Double(-i) * 86400)
            return ChargeCycleSummary(start: end.addingTimeInterval(-Double(20 + i) * 3600),
                                       end: end, startPercent: 100, endPercent: 5)
        }
        averageCycleHours = 23
        let p1 = MouseProfile(name: "Work", dpi: 1600, pollRate: 1000, brightness: 60,
                               effect: LightingEffect.staticColor.rawValue, color: RGB(r: 0x44, g: 0xD6, b: 0x2C), buttonMappings: [:])
        let p2 = MouseProfile(name: "Gaming", dpi: 6400, pollRate: 1000, brightness: 100,
                               effect: LightingEffect.spectrum.rawValue, color: RGB(r: 255, g: 0, b: 0), buttonMappings: [:])
        profiles = [p1, p2]
        activeProfileID = p1.id
    }

    /// `render-ui dpi-stages` / `dpi-single`: a Basilisk V4 Pro's DPI modes.
    func setPreviewDpiModes(single: Bool) {
        deviceName = "Razer Basilisk V4 Pro"
        deviceID = 0x00E3
        dpiStages = single ? [1600] : [400, 800, 1600, 3200, 6400]
        activeDpiStage = single ? 0 : 3
        dpi = single ? 1600 : 3200
    }

    /// For the `render-ui offline` preview: keep last-known values but mark disconnected.
    func setPreviewOffline() {
        connected = false
        let readingDate = Date().addingTimeInterval(-2 * 60)
        lastBatterySnapshot = LastBatterySnapshot(
            deviceKey: "preview", productID: deviceID ?? 0x00DB,
            deviceName: deviceName ?? "Razer Mouse", percent: batteryPercent ?? 72,
            observedAt: readingDate, estimatedHoursRemaining: 39, wasCharging: false
        )
    }

    /// For the `render-ui bluetooth-connected` preview: the Cobra HyperSpeed controlled over
    /// Bluetooth, so the Bluetooth-only layout (no polling rate, no profiles) renders.
    func setPreviewBluetoothConnected() {
        deviceID = 0x00DC
        deviceIsBluetooth = true
        dpiStages = [400, 800, 1600, 3200, 6400]
        activeDpiStage = 3
        dpi = 3200
    }

    /// For the `render-ui bluetooth` preview: a Razer mouse is on Bluetooth, so no USB control
    /// (dongle present, name known, but no live battery/DPI readings).
    func setPreviewBluetooth() {
        connected = false
        batteryPercent = nil
        timeEstimate = nil
        bluetoothMouse = .needsModeSwitch(name: "Cobra HS")
    }
}
