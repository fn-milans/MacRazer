// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import SwiftUI
import RazerProtocol

/// Everything about the mouse but its buttons, one card under the other, the way the menu bar
/// popover had it: the mouse, its battery, DPI, then polling, lighting, power, scroll and
/// profiles, each only when the mouse has it.
struct MousePage: View {
    @ObservedObject var controller: MouseController
    @ObservedObject var remapper: ButtonRemapper
    @ObservedObject var navigation: WindowNavigation

    @State private var brightness: Double = 100
    @State private var color: Color = .razerGreen
    @State private var sleepTimeout: Double = 300
    @State private var lowBattery: Double = 33
    @State private var addingProfile = false
    @State private var pickingColor = false
    @State private var managingProfiles = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DeviceHeaderCard(controller: controller)
            if controller.bluetoothMouse != nil && !controller.connected {
                BluetoothNoticeCard(controller: controller)
            }
            if controller.noMouseKnown {
                if controller.lastBatterySnapshot != nil { battery.opacity(0.55) }
                NoMouseCard(controller: controller)
            } else {
                if controller.deviceHasBattery { battery.opacity(controller.connected ? 1 : 0.55) }
                Group {
                    DPICard(controller: controller)
                    if controller.supportsPollRate {
                        SettingsCard(title: "Polling rate", symbol: "timer", tint: .blue) {
                            PollingRateControls(controller: controller)
                        }
                    }
                    if controller.deviceHasLighting {
                        SettingsCard(title: "Lighting", symbol: "light.max", tint: .orange,
                                     value: LightingControls.summary(controller, brightness: brightness)) {
                            LightingControls(controller: controller, brightnessValue: $brightness, color: $color,
                                             onPickColor: { pickingColor = true })
                        }
                    }
                    if controller.supportsSleepTimeout || controller.lowBatteryThreshold != nil {
                        SettingsCard(title: "Power Management", symbol: "moon.zzz", tint: .indigo) {
                            PowerControls(controller: controller, sleepTimeoutValue: $sleepTimeout,
                                          lowBatteryValue: $lowBattery)
                        }
                    }
                    if controller.smartReel != nil || controller.scrollAcceleration != nil {
                        SettingsCard(title: "Scroll Wheel", symbol: "computermouse", tint: .teal) {
                            MouseSwitchesSection(controller: controller)
                        }
                    }
                }
                .disabled(!controller.connected)
                .opacity(controller.connected ? 1 : 0.55)
                if controller.supportsProfiles || controller.onboardSlotsUnread {
                    SettingsCard(title: "Profiles", symbol: "person.crop.square.on.square.angled", tint: .purple) {
                        QuickProfiles(controller: controller, remapper: remapper, isAddingProfile: $addingProfile,
                                      onManage: { managingProfiles = true })
                    }
                    .opacity(controller.connected ? 1 : 0.55)
                }
            }
        }
        .onAppear(perform: sync)
        .onChange(of: controller.brightness) { _, new in brightness = Double(new) }
        .onChange(of: controller.lightingColor) { _, new in color = new.swiftUIColor }
        .onChange(of: controller.sleepTimeout) { _, _ in sync() }
        .onChange(of: controller.lowBatteryThreshold) { _, _ in sync() }
        // A failed device write leaves the controller's values unchanged, so no value-driven
        // onChange fires — snap the optimistic slider state back to reality explicitly.
        .onChange(of: controller.lastWriteFailure) { _, _ in sync() }
        .onChange(of: controller.supportsProfiles) { _, supported in if !supported { addingProfile = false } }
        .sheet(isPresented: $pickingColor) {
            ColorPickerPage(color: $color, onBack: { pickingColor = false }) { rgb in
                controller.setStaticColor(rgb)
            }
            .frame(width: 320)
        }
        .sheet(isPresented: $navigation.showingUsage) {
            SheetPage(title: "Battery Usage", onDone: { navigation.showingUsage = false }) {
                UsageGraphView(controller: controller)
            }
        }
        .sheet(isPresented: $managingProfiles) {
            SheetPage(title: "Profiles", onDone: { managingProfiles = false }) {
                ProfilesView(controller: controller, remapper: remapper)
            }
        }
    }

    private var battery: some View {
        BatteryCard(controller: controller, isShown: true, onShowUsage: { navigation.showingUsage = true })
    }

    private func sync() {
        brightness = Double(controller.brightness)
        color = controller.lightingColor.swiftUIColor
        if let timeout = controller.sleepTimeout { sleepTimeout = Double(timeout) }
        if let threshold = controller.lowBatteryThreshold { lowBattery = Double(threshold) }
    }
}

/// One of the mouse page's cards: a tinted icon and a name, optionally the current value, and
/// the controls under them.
struct SettingsCard<Content: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    var value: String?
    @ViewBuilder var content: Content

    var body: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 22, height: 22)
                        .background(tint.opacity(0.22), in: RoundedRectangle(cornerRadius: 6))
                    Text(title).font(.system(size: 12.5, weight: .semibold))
                    Spacer(minLength: 6)
                    if let value {
                        Text(value).font(.system(size: 11.5)).monospacedDigit()
                            .foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                content
            }
        }
    }
}

/// A sheet with a title and a Done button, for what opens from a card.
struct SheetPage<Content: View>: View {
    let title: String
    var onDone: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(RazerProminentButtonStyle())
            }
            .padding(16)
            ScrollView {
                content.padding([.horizontal, .bottom], 16)
            }
        }
        .frame(width: 520, height: 560)
    }
}
