// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import SwiftUI

/// The main window's panes in their preview states, with no mouse needed: what `render-ui`
/// draws to a PNG and what the snapshot tests render. One list, so a state the tests cover is
/// one a person can look at, and the other way round. (`render-window` draws the whole window.)
enum PreviewScene: String, CaseIterable {
    case main, offline, bluetooth
    case bluetoothConnected = "bluetooth-connected"
    case dpiStages = "dpi-stages"
    case dpiSingle = "dpi-single"
    case zones, buttons, usage, profiles, color

    /// Segmented controls only draw when hosted in a view hierarchy.
    var needsHosting: Bool { [.zones, .dpiStages, .dpiSingle, .bluetoothConnected].contains(self) }

    @MainActor
    func makeView() -> AnyView {
        let controller = MouseController()
        controller.loadPreviewState()
        switch self {
        case .offline: controller.setPreviewOffline()
        case .bluetooth: controller.setPreviewBluetooth()
        case .bluetoothConnected: controller.setPreviewBluetoothConnected()
        case .dpiStages: controller.setPreviewDpiModes(single: false)
        case .dpiSingle: controller.setPreviewDpiModes(single: true)
        case .zones: controller.setPreviewZonedLighting()
        case .main, .buttons, .usage, .profiles, .color: break
        }
        let remapper = ButtonRemapper()
        let view: AnyView
        switch self {
        case .main, .offline, .bluetooth:
            view = AnyView(OverviewPane(controller: controller, remapper: remapper, navigation: WindowNavigation()))
        case .bluetoothConnected, .dpiStages, .dpiSingle:
            view = AnyView(PerformancePane(controller: controller))
        case .zones:
            view = AnyView(LightingPane(controller: controller))
        case .buttons:
            view = AnyView(ButtonsPane(controller: controller, remapper: remapper, keepsRunning: false))
        case .usage:
            view = AnyView(BatteryPane(controller: controller, keepsRunning: true))
        case .profiles:
            view = AnyView(ProfilesPane(controller: controller, remapper: remapper))
        case .color:
            return AnyView(ColorPickerPage(color: .constant(.blue), onBack: {}, onApply: { _ in }).frame(width: 320))
        }
        // A pane at the window's reading width.
        return AnyView(view.padding(24).frame(width: 640, alignment: .topLeading))
    }
}
