// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import SwiftUI

/// The main window's pages in their preview states, with no mouse needed: what `render-ui`
/// draws to a PNG and what the snapshot tests render. One list, so a state the tests cover is
/// one a person can look at, and the other way round. (`render-window` draws the whole window.)
enum PreviewScene: String, CaseIterable {
    case main, offline, bluetooth
    case bluetoothConnected = "bluetooth-connected"
    case dpiStages = "dpi-stages"
    case dpiSingle = "dpi-single"
    case zones, buttons, usage, profiles, settings, color

    /// Segmented controls only draw when hosted in a view hierarchy.
    var needsHosting: Bool { [.main, .zones, .dpiStages, .dpiSingle, .bluetoothConnected, .settings].contains(self) }

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
        case .main, .buttons, .usage, .profiles, .settings, .color: break
        }
        let remapper = ButtonRemapper()
        let view: AnyView
        switch self {
        case .main, .offline, .bluetooth, .bluetoothConnected, .dpiStages, .dpiSingle, .zones:
            view = AnyView(Dashboard(controller: controller, remapper: remapper, navigation: WindowNavigation()))
        case .buttons:
            view = AnyView(RemapView(remapper: remapper, controller: controller).padding(18).tileBackground())
        case .usage:
            view = AnyView(UsageGraphView(controller: controller))
        case .profiles:
            view = AnyView(ProfilesView(controller: controller, remapper: remapper))
        case .settings:
            let launchAtLogin = LaunchAtLogin()
            launchAtLogin.loadPreviewState()
            view = AnyView(SettingsView(controller: controller, launchAtLogin: launchAtLogin,
                                        background: BackgroundMode(defaults: UserDefaults(suiteName: "SerpentinePreview")!)))
        case .color:
            return AnyView(ColorPickerPage(color: .constant(.blue), onBack: {}, onApply: { _ in }).frame(width: 320))
        }
        // A page at the window's width.
        return AnyView(view.padding(20).frame(width: 920, alignment: .topLeading))
    }
}
