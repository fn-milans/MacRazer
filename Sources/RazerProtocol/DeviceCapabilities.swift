// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// How a mouse is connected. The cable and the 2.4 GHz dongle speak the same USB HID reports;
/// Bluetooth goes through Razer's GATT service (`BLEProtocol`), which reaches fewer settings.
public enum DeviceLink: Sendable, Equatable {
    case usb
    case bluetooth
}

/// What a connected mouse can do on the link it is on, worked out once from the registry
/// (`RazerDevices`) and the link. Ask this rather than the product id: it is where the rules
/// like "no polling rate over Bluetooth" live, once.
///
/// What depends on the mouse's state rather than its model (which onboard slot is active, what
/// it reported) is not here.
public struct DeviceCapabilities: Sendable, Equatable {
    /// nil when no mouse is connected.
    public let pid: Int?
    public let link: DeviceLink

    public init(pid: Int?, link: DeviceLink) {
        self.pid = pid
        self.link = link
    }

    /// No mouse: the defaults the UI shows before one connects.
    public static let none = DeviceCapabilities(pid: nil, link: .usb)

    private var info: RazerDeviceInfo? { pid.flatMap(RazerDevices.info(pid:)) }
    private var usb: Bool { link == .usb }

    public var isBluetooth: Bool { link == .bluetooth }
    /// In the registry and tested; otherwise its controls are attempted with OpenRazer's values.
    public var fullySupported: Bool { info?.fullySupported ?? false }
    public var hasBattery: Bool { info?.hasBattery ?? true }
    public var hasLighting: Bool { info?.hasLighting ?? true }
    public var maxDPI: Int { info?.maxDPI ?? 26000 }

    // MARK: Performance

    /// Bluetooth has no known polling rate command.
    public var pollRate: Bool { usb }
    /// Over Bluetooth DPI moves only between the mouse's own stages.
    public var freeDPI: Bool { usb }
    /// Single and Stages modes, the same on every link.
    public var dpiModes: Bool { info?.supportsDpiModes ?? false }
    /// Editing a stage's value over Bluetooth (USB always can).
    public var stageEditingOverBluetooth: Bool { isBluetooth && (info?.supportsStageEditing ?? false) }
    /// The rates the picker offers. Over Bluetooth, where the rate can't be set, the classic three.
    public var pollingRates: [Int] { usb ? RazerCommands.supportedPollingRates(pid: pid) : RazerCommands.supportedPollingRates }

    // MARK: Lighting

    /// The mouse's lighting zones (`ZonedLighting`); empty when it is lit as one.
    public var lightingZones: [LightingZone] { RazerDevices.lightingZones(pid: pid) }
    /// Bluetooth sets only a static colour, except on mice with zones, which take every effect.
    public var lightingEffects: Bool { usb || !lightingZones.isEmpty }
    public var effects: [LightingEffect] { lightingZones.isEmpty ? LightingEffect.classic : ZonedLighting.effects }

    // MARK: Power and scroll

    public var sleepTimeout: Bool { info?.supportsSleepTimeout ?? false }
    public var lowBatteryThreshold: Bool { info?.supportsLowBatteryThreshold ?? false }
    /// Wheel mode and Smart-Reel. Not over Bluetooth.
    public var wheelControls: Bool { usb && (info?.hasWheelControls ?? false) }
    public var smartReelSensitivity: Bool { usb && (info?.hasSmartReelSensitivity ?? false) }
    public var scrollAcceleration: Bool { usb && (info?.hasScrollAcceleration ?? false) }

    // MARK: Onboard memory

    public var onboardSlots: Bool { info?.hasOnboardSlots ?? false }
    /// The mouse's button function table, when Serpentine knows it: remaps are then written
    /// into the mouse (`OnboardButtons`).
    public var buttonTable: OnboardButtons.Table? { info?.buttonTable }
    public var onboardRemaps: Bool { buttonTable != nil }
    /// The Basilisk V3 X HyperSpeed's DPI Cycle assignment, which the F20 bridge relies on.
    public var dpiButtonBinding: Bool { info?.supportsDpiButtonBinding ?? false }
}
