// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import SwiftUI

/// The sections of the main window's sidebar, one pane each, in sidebar order.
enum PaneSection: String, CaseIterable, Identifiable {
    case overview, performance, lighting, buttons, profiles, scroll, power, battery

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .performance: return "Performance"
        case .lighting: return "Lighting"
        case .buttons: return "Buttons"
        case .profiles: return "Profiles"
        case .scroll: return "Scroll"
        case .power: return "Power"
        case .battery: return "Battery"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .performance: return "gauge.with.dots.needle.67percent"
        case .lighting: return "light.max"
        case .buttons: return "computermouse"
        case .profiles: return "person.crop.square.on.square.angled"
        case .scroll: return "arrow.up.and.down"
        case .power: return "moon.zzz"
        case .battery: return "battery.75percent"
        }
    }

    /// ⌘1 to ⌘8, by sidebar position.
    var shortcut: KeyEquivalent { KeyEquivalent(Character(String((Self.allCases.firstIndex(of: self) ?? 0) + 1))) }

    /// Whether the connected (or last-known) mouse has anything to show here.
    @MainActor
    func isAvailable(for controller: MouseController) -> Bool {
        switch self {
        case .overview, .performance, .buttons: return true
        case .lighting: return controller.deviceHasLighting
        case .profiles: return controller.supportsProfiles || controller.onboardSlotsUnread
        case .scroll: return controller.smartReel != nil || controller.scrollAcceleration != nil
        case .power: return controller.supportsSleepTimeout || controller.lowBatteryThreshold != nil
        case .battery: return controller.deviceHasBattery
        }
    }
}

/// Which pane the main window shows, shared with the menu bar's Go menu.
@MainActor
final class WindowNavigation: ObservableObject {
    @Published var section: PaneSection = .overview {
        didSet { UserDefaults.standard.set(section.rawValue, forKey: Preferences.mainWindowSection) }
    }

    init() {
        section = UserDefaults.standard.string(forKey: Preferences.mainWindowSection)
            .flatMap(PaneSection.init(rawValue:)) ?? .overview
    }
}
