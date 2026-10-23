// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// Where a setting lives, which is what Serpentine is about: everything it can, it writes into
/// the mouse, so the mouse behaves the same with the app closed, on any link and on any
/// computer. The rest ("driver mode") works only while Serpentine runs.
public enum SettingResidency: Sendable, Equatable {
    /// Written to the mouse's onboard memory.
    case mouse
    /// Done by Serpentine while it runs.
    case app
}

/// Every setting the app offers, with where it lives.
public enum Setting: CaseIterable, Sendable {
    case dpi, dpiStages, pollingRate
    case lighting, brightness
    case sleepTimer, lowBatteryLevel
    case wheelMode, smartReel, scrollAcceleration
    case onboardProfiles
    case lowBatteryAlerts, batteryHistory, connectionSounds
    /// The Basilisk V3 X HyperSpeed's DPI Cycle button bridged to a software action (F20).
    case dpiCycleBridge

    public var residency: SettingResidency {
        switch self {
        case .dpi, .dpiStages, .pollingRate, .lighting, .brightness, .sleepTimer, .lowBatteryLevel,
             .wheelMode, .smartReel, .scrollAcceleration, .onboardProfiles:
            return .mouse
        case .lowBatteryAlerts, .batteryHistory, .connectionSounds, .dpiCycleBridge:
            return .app
        }
    }

    /// How the app names it when it lists what needs Serpentine running.
    public var title: String {
        switch self {
        case .dpi: return "DPI"
        case .dpiStages: return "DPI stages"
        case .pollingRate: return "Polling rate"
        case .lighting: return "Lighting"
        case .brightness: return "Brightness"
        case .sleepTimer: return "Sleep timer"
        case .lowBatteryLevel: return "Low-battery level"
        case .wheelMode: return "Wheel mode"
        case .smartReel: return "Smart-Reel"
        case .scrollAcceleration: return "Scroll acceleration"
        case .onboardProfiles: return "Onboard profiles"
        case .lowBatteryAlerts: return "Low-battery alerts"
        case .batteryHistory: return "Battery history and time left"
        case .connectionSounds: return "Connection sounds"
        case .dpiCycleBridge: return "DPI Cycle button action"
        }
    }
}

extension RemapAction {
    /// Where this action lives when it is put on `button` of a mouse with these capabilities.
    /// On a mouse whose function table Serpentine knows, everything the mouse can store is
    /// written there (`OnboardButtons.placement`); the rest, and every remap on other mice, is
    /// done by the event tap while the app runs. No remap at all is the mouse's own function.
    public func residency(onButton button: Int, of capabilities: DeviceCapabilities) -> SettingResidency {
        if self == .passthrough { return .mouse }
        // A HyperShift-layer remap is kept under its button's id plus an offset, and the mouse
        // stores that layer too.
        let base = RemapCatalog.isHyperShiftKey(button) ? button - RemapCatalog.hyperShiftOffset : button
        guard let pid = capabilities.pid, capabilities.onboardRemaps,
              let control = OnboardButtons.layout(pid: pid)?.first(where: { $0.button == base })
        else { return .app }
        switch OnboardButtons.placement(for: control, mappings: [base: self]) {
        case .factory, .mouse: return .mouse
        case .app: return .app
        }
    }
}
