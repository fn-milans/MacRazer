// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import SwiftUI

/// The popover's states as previews, with no mouse needed: what `render-ui` draws to a PNG
/// and what the snapshot tests render. One list, so a state the tests cover is one a person
/// can look at, and the other way round.
enum PreviewScene: String, CaseIterable {
    case main, offline, bluetooth
    case bluetoothConnected = "bluetooth-connected"
    case dpiStages = "dpi-stages"
    case dpiSingle = "dpi-single"
    case zones, usage, profiles, color

    /// Segmented controls only draw when hosted in a view hierarchy.
    var needsHosting: Bool { [.zones, .dpiStages, .dpiSingle].contains(self) }

    /// The scene's view. `zones` opens the Lighting row, which the popover keeps in the user's
    /// defaults: `defaults` is where that goes.
    @MainActor
    func makeView(defaults: UserDefaults = .standard) -> AnyView {
        let controller = MouseController()
        controller.loadPreviewState()
        switch self {
        case .offline: controller.setPreviewOffline()
        case .bluetooth: controller.setPreviewBluetooth()
        case .bluetoothConnected: controller.setPreviewBluetoothConnected()
        case .dpiStages: controller.setPreviewDpiModes(single: false)
        case .dpiSingle: controller.setPreviewDpiModes(single: true)
        case .zones:
            // The Basilisk V4 Pro's lighting zones, with the Lighting row open.
            controller.setPreviewZonedLighting()
            defaults.set("lighting", forKey: Preferences.popoverExpandedSections)
        case .main, .usage, .profiles, .color: break
        }
        let launchAtLogin = LaunchAtLogin()
        launchAtLogin.loadPreviewState()
        switch self {
        case .color:
            return AnyView(ColorPickerPage(color: .constant(.blue), onBack: {}, onApply: { _ in }))
        case .usage:
            return AnyView(UsageGraphView(controller: controller, onBack: {}))
        case .profiles:
            return AnyView(ProfilesView(controller: controller, remapper: ButtonRemapper(), onBack: {}))
        default:
            return AnyView(PopoverView(controller: controller, remapper: ButtonRemapper(),
                                       launchAtLogin: launchAtLogin, appearance: AppearanceSettings.shared,
                                       onOpenSettings: {})) // no windows in a render
        }
    }
}
