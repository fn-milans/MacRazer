// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import RazerProtocol

/// What the README's support table promises, checked against what the app will offer.
final class DeviceCapabilitiesTests: XCTestCase {
    private let v4ProWireless = DeviceCapabilities(pid: 0x00E3, link: .usb)
    private let v4ProBluetooth = DeviceCapabilities(pid: 0x00E4, link: .bluetooth)

    func testBasiliskV4ProOverTheDongleHasEverything() {
        let c = v4ProWireless
        XCTAssertTrue(c.pollRate)
        XCTAssertEqual(c.pollingRates.max(), 8000, "polling up to 8000 Hz")
        XCTAssertEqual(c.lightingZones, [.logo, .scrollWheel, .underglow])
        XCTAssertTrue(c.sleepTimeout)
        XCTAssertTrue(c.lowBatteryThreshold)
        XCTAssertTrue(c.wheelControls)
        XCTAssertTrue(c.smartReelSensitivity)
        XCTAssertTrue(c.scrollAcceleration)
        XCTAssertTrue(c.onboardSlots)
        XCTAssertTrue(c.onboardRemaps)
    }

    func testBasiliskV4ProOverBluetoothLacksPollingAndTheWheel() {
        // "Over Bluetooth everything but polling and the wheel settings."
        let c = v4ProBluetooth
        XCTAssertFalse(c.pollRate)
        XCTAssertFalse(c.wheelControls)
        XCTAssertFalse(c.smartReelSensitivity)
        XCTAssertFalse(c.scrollAcceleration)
        XCTAssertTrue(c.lightingEffects, "zoned mice take every effect over Bluetooth")
        XCTAssertTrue(c.sleepTimeout)
        XCTAssertTrue(c.lowBatteryThreshold)
        XCTAssertTrue(c.onboardSlots)
        XCTAssertTrue(c.onboardRemaps)
        XCTAssertTrue(c.stageEditingOverBluetooth)
    }

    func testCobraHyperSpeedOverBluetoothIsStaticColourOnly() {
        let c = DeviceCapabilities(pid: 0x00DC, link: .bluetooth)
        XCTAssertFalse(c.pollRate)
        XCTAssertFalse(c.freeDPI)
        XCTAssertFalse(c.lightingEffects)
        XCTAssertEqual(c.pollingRates, [125, 500, 1000])
    }

    func testAtherisHasNoLighting() {
        XCTAssertFalse(DeviceCapabilities(pid: 0x0062, link: .usb).hasLighting)
    }

    func testNoMouseFallsBackToTheDefaults() {
        let c = DeviceCapabilities.none
        XCTAssertNil(c.pid)
        XCTAssertTrue(c.hasBattery)
        XCTAssertEqual(c.maxDPI, 26000)
        XCTAssertFalse(c.onboardRemaps)
        XCTAssertEqual(c.effects, LightingEffect.classic)
    }

    func testRemapResidency() {
        let forward = 4
        // A key on a mouse that stores remaps: in the mouse.
        let copy = RemapAction.keystroke(keyCode: 8, modifiers: CGEventFlags.maskCommand.rawValue, name: "Copy")
        XCTAssertEqual(copy.residency(onButton: forward, of: v4ProWireless), .mouse)
        // The same remap on a mouse whose table isn't known: the event tap.
        let cobra = DeviceCapabilities(pid: 0x00DB, link: .usb)
        XCTAssertEqual(copy.residency(onButton: forward, of: cobra), .app)
        // A mouse button past the fifth can't be stored, even on the V4 Pro.
        XCTAssertEqual(RemapAction.mouseButton(button: 7, name: "Button 8").residency(onButton: forward, of: v4ProWireless), .app)
        XCTAssertEqual(RemapAction.doubleClick.residency(onButton: forward, of: v4ProWireless), .mouse)
        // No remap is the mouse's own function anywhere.
        XCTAssertEqual(RemapAction.passthrough.residency(onButton: forward, of: cobra), .mouse)
        // The HyperShift layer is stored too.
        XCTAssertEqual(copy.residency(onButton: RemapCatalog.hyperShiftKey(forward), of: v4ProWireless), .mouse)
    }

    func testDriverModeSettings() {
        let app = Setting.allCases.filter { $0.residency == .app }
        XCTAssertEqual(Set(app), [.lowBatteryAlerts, .batteryHistory, .connectionSounds, .dpiCycleBridge])
    }
}
