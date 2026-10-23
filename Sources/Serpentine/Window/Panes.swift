// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import SwiftUI
import RazerProtocol

// The main window's panes, one per sidebar section, built from the feature views.

/// Where a pane's settings live: in the mouse, or only while Serpentine runs.
struct ResidencyBadge: View {
    let residency: SettingResidency
    /// For `.app`: whether Serpentine keeps running when its window is closed.
    var keepsRunning = true

    var body: some View {
        Label(text, systemImage: residency == .mouse ? "memorychip" : "macwindow")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(tint.opacity(0.14), in: Capsule())
            .help(help)
    }

    private var text: String {
        residency == .mouse ? "Saved in the mouse" : "Needs Serpentine running"
    }

    private var tint: Color {
        residency == .mouse ? .razerGreenText : (keepsRunning ? .secondary : .batteryMid)
    }

    private var help: String {
        residency == .mouse
            ? "Written to the mouse's own memory: it keeps working with Serpentine closed, on any link and any computer."
            : keepsRunning
                ? "Done by Serpentine, which keeps running in the background."
                : "Done by Serpentine: it stops when you close the window, unless Serpentine keeps running in the background (Settings)."
    }
}

/// One line under the pane's title: what it is for, and where its settings live.
struct PaneIntro: View {
    let text: String
    var residency: SettingResidency?
    var keepsRunning = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(text).font(.system(size: 12.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let residency { ResidencyBadge(residency: residency, keepsRunning: keepsRunning) }
        }
    }
}

/// A titled group of controls on a pane.
struct PaneGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold)).tracking(0.5)
                .foregroundStyle(.secondary)
            content
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

/// Shown on a pane while the mouse is away: its settings are the last known ones.
private struct OfflineNote: View {
    @ObservedObject var controller: MouseController

    var body: some View {
        if !controller.connected {
            Label(controller.deviceName == nil
                  ? "No mouse connected."
                  : "The mouse is offline. These are its last known settings; wake it to change them.",
                  systemImage: "moon.zzz")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
    }
}

// MARK: Performance

struct PerformancePane: View {
    @ObservedObject var controller: MouseController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PaneIntro(text: "How fast the pointer moves, and how often the mouse reports.", residency: .mouse)
            OfflineNote(controller: controller)
            DPICard(controller: controller)
                .disabled(!controller.connected)
            if controller.supportsPollRate {
                PaneGroup(title: "Polling rate") {
                    PollingRateControls(controller: controller)
                }
                .disabled(!controller.connected)
            }
        }
    }
}

// MARK: Lighting

struct LightingPane: View {
    @ObservedObject var controller: MouseController
    @State private var brightness: Double = 100
    @State private var color: Color = .razerGreen
    @State private var pickingColor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PaneIntro(text: "Brightness, effect and colour\(controller.lightingZones.isEmpty ? "" : ", zone by zone").",
                      residency: .mouse)
            OfflineNote(controller: controller)
            PaneGroup(title: LightingControls.summary(controller, brightness: brightness)) {
                LightingControls(controller: controller, brightnessValue: $brightness, color: $color,
                                 onPickColor: { pickingColor = true })
            }
            .disabled(!controller.connected)
        }
        .onAppear {
            brightness = Double(controller.brightness)
            color = controller.lightingColor.swiftUIColor
        }
        .onChange(of: controller.brightness) { _, new in brightness = Double(new) }
        .onChange(of: controller.lightingColor) { _, new in color = new.swiftUIColor }
        .onChange(of: controller.lastWriteFailure) { _, _ in brightness = Double(controller.brightness) }
        .sheet(isPresented: $pickingColor) {
            ColorPickerPage(color: $color, onBack: { pickingColor = false }) { rgb in
                controller.setStaticColor(rgb)
            }
            .frame(width: 320)
        }
    }
}

// MARK: Buttons

struct ButtonsPane: View {
    @ObservedObject var controller: MouseController
    @ObservedObject var remapper: ButtonRemapper
    var keepsRunning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PaneIntro(text: intro, residency: residency, keepsRunning: keepsRunning)
            RemapView(remapper: remapper, controller: controller)
        }
    }

    private var intro: String {
        remapper.mappingsLiveInMouse
            ? "What each button does. Remaps are written to the mouse; the few it can't store are done by Serpentine."
            : "What each button does. Serpentine does the remaps on this mouse, while it runs."
    }

    /// In the mouse when every remap is; otherwise the app, which then has work to do. A mouse
    /// whose table Serpentine doesn't know has every remap done by the app.
    private var residency: SettingResidency {
        guard remapper.mappingsLiveInMouse else { return .app }
        let caps = controller.capabilities
        return remapper.mappings.contains { $0.value.residency(onButton: $0.key, of: caps) == .app } ? .app : .mouse
    }
}

// MARK: Profiles

struct ProfilesPane: View {
    @ObservedObject var controller: MouseController
    @ObservedObject var remapper: ButtonRemapper
    @State private var adding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if controller.usesSlotProfiles || controller.onboardSlotsUnread {
                PaneIntro(text: "The profiles kept in the mouse. Switch with a click, or with a profile button on the mouse.",
                          residency: .mouse)
                OfflineNote(controller: controller)
                PaneGroup(title: "Profiles in the mouse") {
                    QuickProfiles(controller: controller, remapper: remapper, isAddingProfile: $adding, onManage: nil)
                }
            } else {
                PaneIntro(text: "Saved setups of DPI, polling rate, lighting and remaps. Applying one writes it to the mouse.",
                          residency: .mouse)
                OfflineNote(controller: controller)
                PaneGroup(title: "Switch") {
                    QuickProfiles(controller: controller, remapper: remapper, isAddingProfile: $adding, onManage: nil)
                }
                if !controller.profiles.isEmpty {
                    ProfilesView(controller: controller, remapper: remapper)
                }
            }
        }
    }
}

// MARK: Scroll

struct ScrollPane: View {
    @ObservedObject var controller: MouseController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PaneIntro(text: "How the wheel behaves when you flick it.", residency: .mouse)
            OfflineNote(controller: controller)
            MouseSwitchesSection(controller: controller)
                .disabled(!controller.connected)
        }
    }
}

// MARK: Power

struct PowerPane: View {
    @ObservedObject var controller: MouseController
    @State private var sleepTimeout: Double = 300
    @State private var lowBattery: Double = 33

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PaneIntro(text: "When the mouse goes to sleep, and when it goes into its own low-battery mode.",
                      residency: .mouse)
            OfflineNote(controller: controller)
            PaneGroup(title: controller.supportsSleepTimeout
                      ? "Sleep after " + PowerControls.sleepTimeoutSummary(controller, value: sleepTimeout)
                      : PowerControls.lowBatterySummary(controller, value: lowBattery)) {
                PowerControls(controller: controller, sleepTimeoutValue: $sleepTimeout, lowBatteryValue: $lowBattery)
            }
            .disabled(!controller.connected)
        }
        .onAppear(perform: sync)
        .onChange(of: controller.sleepTimeout) { _, _ in sync() }
        .onChange(of: controller.lowBatteryThreshold) { _, _ in sync() }
        .onChange(of: controller.lastWriteFailure) { _, _ in sync() }
    }

    private func sync() {
        if let timeout = controller.sleepTimeout { sleepTimeout = Double(timeout) }
        if let threshold = controller.lowBatteryThreshold { lowBattery = Double(threshold) }
    }
}

// MARK: Battery

struct BatteryPane: View {
    @ObservedObject var controller: MouseController
    var keepsRunning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PaneIntro(text: "How long a charge lasts, learned from the readings Serpentine takes.",
                      residency: .app, keepsRunning: keepsRunning)
            BatteryCard(controller: controller, isShown: true, onShowUsage: nil)
                .opacity(controller.connected ? 1 : 0.55)
            UsageGraphView(controller: controller)
        }
    }
}
