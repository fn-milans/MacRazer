// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import SwiftUI
import RazerProtocol

/// The mouse at a glance: what needs attention, the battery, and the current settings, each a
/// way into its pane.
struct OverviewPane: View {
    @ObservedObject var controller: MouseController
    @ObservedObject var remapper: ButtonRemapper
    @ObservedObject var navigation: WindowNavigation

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if controller.bluetoothMouse != nil && !controller.connected {
                BluetoothNoticeCard(controller: controller)
            }
            if controller.noMouseKnown {
                if controller.lastBatterySnapshot != nil { battery.opacity(0.55) }
                NoMouseCard(controller: controller)
            } else {
                if controller.deviceHasBattery { battery.opacity(controller.connected ? 1 : 0.55) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                    tile(.performance, title: "DPI", value: controller.dpi == 0 ? "…" : "\(controller.dpi)")
                    if controller.supportsPollRate {
                        tile(.performance, title: "Polling rate", value: "\(controller.displayedPollRate) Hz")
                    }
                    if controller.deviceHasLighting {
                        tile(.lighting, title: "Lighting", value: lightingValue)
                    }
                    if controller.supportsProfiles {
                        tile(.profiles, title: "Profile", value: profileValue)
                    }
                    tile(.buttons, title: "Buttons", value: buttonsValue)
                }
                .opacity(controller.connected ? 1 : 0.55)
            }
        }
    }

    private var battery: some View {
        BatteryCard(controller: controller, isShown: true, onShowUsage: { navigation.section = .battery })
    }

    private var lightingValue: String {
        LightingControls.summary(controller, brightness: Double(controller.brightness))
    }

    private var profileValue: String {
        if controller.usesSlotProfiles { return controller.activeOnboardSlot.map(controller.slotName) ?? "…" }
        return controller.profiles.first { $0.id == controller.activeProfileID }?.name
            ?? (controller.profiles.isEmpty ? "None saved" : "None active")
    }

    private var buttonsValue: String {
        // Resetting a button to "Default" stores `.passthrough` rather than removing it.
        let count = remapper.mappings.values.filter { $0 != .passthrough }.count
        return count == 0 ? "Factory" : "\(count) remapped"
    }

    private func tile(_ section: PaneSection, title: String, value: String) -> some View {
        Button {
            navigation.section = section
        } label: {
            HStack(spacing: 10) {
                Image(systemName: section.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.razerGreenText)
                    .frame(width: 28, height: 28)
                    .background(Color.razerGreen.opacity(0.15), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(value).font(.system(size: 14, weight: .semibold)).monospacedDigit().lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            .hoverHighlight(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
}
