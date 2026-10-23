// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import SwiftUI
import RazerProtocol

/// The main window's home: the mouse and its battery across the top, then a tile for each of
/// its settings, two to a row, only the ones this mouse has. Buttons and the battery history
/// open from their tiles.
struct Dashboard: View {
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

    /// The setting tiles, in reading order.
    private enum Kind: Hashable { case dpi, polling, lighting, sleep, lowBattery, scroll, buttons, profiles }

    private var kinds: [Kind] {
        var out: [Kind] = [.dpi]
        if controller.supportsPollRate { out.append(.polling) }
        if controller.deviceHasLighting { out.append(.lighting) }
        if controller.supportsSleepTimeout { out.append(.sleep) }
        if controller.lowBatteryThreshold != nil { out.append(.lowBattery) }
        if controller.smartReel != nil || controller.scrollAcceleration != nil { out.append(.scroll) }
        out.append(.buttons)
        if controller.supportsProfiles || controller.onboardSlotsUnread { out.append(.profiles) }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DeviceTile(controller: controller, navigation: navigation)
            if controller.bluetoothMouse != nil && !controller.connected {
                BluetoothNoticeCard(controller: controller)
            }
            if controller.noMouseKnown {
                NoMouseCard(controller: controller)
            } else {
                Grid(horizontalSpacing: 14, verticalSpacing: 14) {
                    ForEach(rows, id: \.self) { row in
                        GridRow {
                            ForEach(row, id: \.self) { kind in
                                tile(kind)
                                    .gridCellColumns(row.count == 1 ? 2 : 1)
                            }
                        }
                    }
                }
                .opacity(controller.connected ? 1 : 0.55)
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
        .sheet(isPresented: $managingProfiles) {
            SheetPage(title: "Profiles", onDone: { managingProfiles = false }) {
                ProfilesView(controller: controller, remapper: remapper)
            }
        }
    }

    /// Two to a row; an odd one out takes the whole row.
    private var rows: [[Kind]] {
        stride(from: 0, to: kinds.count, by: 2).map { Array(kinds[$0..<min($0 + 2, kinds.count)]) }
    }

    @ViewBuilder
    private func tile(_ kind: Kind) -> some View {
        switch kind {
        case .dpi:
            Tile(title: "DPI", symbol: "scope", tint: .green) {
                DPICard(controller: controller, inTile: true)
            }
            .disabled(!controller.connected)
        case .polling:
            Tile(title: "Polling Rate", symbol: "timer", tint: .blue, value: "\(controller.displayedPollRate) Hz") {
                PollingRateControls(controller: controller)
            }
            .disabled(!controller.connected)
        case .lighting:
            Tile(title: "Lighting", symbol: "light.max", tint: .orange,
                 value: LightingControls.summary(controller, brightness: brightness)) {
                LightingControls(controller: controller, brightnessValue: $brightness, color: $color,
                                 onPickColor: { pickingColor = true })
            }
            .disabled(!controller.connected)
        case .sleep:
            Tile(title: "Sleep", symbol: "moon.zzz.fill", tint: .indigo,
                 value: PowerControls.sleepTimeoutSummary(controller, value: sleepTimeout)) {
                PowerControls(controller: controller, sleepTimeoutValue: $sleepTimeout,
                              lowBatteryValue: $lowBattery, parts: .sleep)
            }
            .disabled(!controller.connected)
        case .lowBattery:
            Tile(title: "Low Battery", symbol: "battery.25percent", tint: .red,
                 value: controller.lowBatteryThreshold == nil ? "…" : "\(Int(lowBattery))%") {
                PowerControls(controller: controller, sleepTimeoutValue: $sleepTimeout,
                              lowBatteryValue: $lowBattery, parts: .lowBattery)
            }
            .disabled(!controller.connected)
        case .scroll:
            Tile(title: "Scroll Wheel", symbol: "arrow.up.and.down.circle", tint: .teal) {
                MouseSwitchesSection(controller: controller, inTile: true)
            }
            .disabled(!controller.connected)
        case .buttons:
            buttonsTile
        case .profiles:
            profilesTile
        }
    }

    private var buttonsTile: some View {
        let count = remapper.mappings.values.filter { $0 != .passthrough }.count
        let caps = controller.capabilities
        let inMouse = remapper.mappingsLiveInMouse
            && !remapper.mappings.contains { $0.value.residency(onButton: $0.key, of: caps) == .app }
        return Tile(title: "Buttons", symbol: "computermouse.fill", tint: .pink,
                    residency: inMouse ? .mouse : .app,
                    value: count == 0 ? "Factory" : (count == 1 ? "1 remapped" : "\(count) remapped")) {
            VStack(alignment: .leading, spacing: 10) {
                Text(remapper.mappingsLiveInMouse
                     ? "Remaps are written to the mouse, the HyperShift layer too."
                     : "Remaps on this mouse are done by Serpentine while it runs.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    navigation.go(to: .buttons)
                } label: {
                    Label("Customize Buttons", systemImage: "chevron.right")
                        .labelStyle(TrailingIconLabelStyle())
                }
                .buttonStyle(RazerProminentButtonStyle())
            }
        }
    }

    private var profilesTile: some View {
        Tile(title: "Profiles", symbol: "person.crop.square.on.square.angled.fill", tint: .purple,
             value: profileValue) {
            QuickProfiles(controller: controller, remapper: remapper, isAddingProfile: $addingProfile,
                          onManage: { managingProfiles = true })
        }
    }

    private var profileValue: String? {
        if controller.usesSlotProfiles { return controller.activeOnboardSlot.map(controller.slotName) }
        return controller.profiles.first { $0.id == controller.activeProfileID }?.name
    }

    private func sync() {
        brightness = Double(controller.brightness)
        color = controller.lightingColor.swiftUIColor
        if let timeout = controller.sleepTimeout { sleepTimeout = Double(timeout) }
        if let threshold = controller.lowBatteryThreshold { lowBattery = Double(threshold) }
    }
}

/// A label with its icon after the title, for "Customize Buttons ›".
struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.title
            configuration.icon.font(.system(size: 10, weight: .bold))
        }
    }
}

/// The mouse across the top of the dashboard: what it is, how it's connected, and its battery.
struct DeviceTile: View {
    @ObservedObject var controller: MouseController
    @ObservedObject var navigation: WindowNavigation

    var body: some View {
        HStack(spacing: 16) {
            Image(nsImage: MenuBarIcon.mouseModel(pid: controller.deviceID, pointSize: 30))
                .renderingMode(.template)
                .resizable().scaledToFit()
                .frame(width: 30, height: 30)
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background((controller.connected ? Color.green : Color.gray).gradient,
                            in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(controller.deviceName ?? controller.bluetoothMouse?.name ?? "No mouse connected")
                    .font(.system(size: 20, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Circle().fill(controller.connected ? Color.green : Color.secondary).frame(width: 7, height: 7)
                    Text(statusText).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            if controller.deviceHasBattery, controller.deviceName != nil || controller.lastBatterySnapshot != nil {
                battery
            }
        }
        .padding(18)
        .tileBackground()
    }

    private var statusText: String {
        if controller.bluetoothRecoveryState == .reconnecting && !controller.connected { return "Reconnecting…" }
        if controller.connected {
            return linkName + (controller.deviceSupported ? "" : " · limited support")
        }
        if controller.bluetoothMouse != nil { return "On Bluetooth" }
        return controller.deviceName == nil ? "Connect a Razer mouse with its dongle or a cable" : "Offline"
    }

    private var linkName: String {
        switch RazerDevices.connection(pid: controller.deviceID) {
        case .bluetooth: return "Bluetooth"
        case .wired: return "Wired"
        case .wirelessDongle: return controller.charging ? "Wired" : "2.4 GHz wireless"
        case nil: return "USB"
        }
    }

    private var battery: some View {
        HStack(spacing: 14) {
            VStack(alignment: .trailing, spacing: 4) {
                Text(controller.batteryStatusLine)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                Button("Battery History") { navigation.go(to: .battery) }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
            }
            BatteryGauge(percent: controller.batteryPercent ?? controller.lastBatterySnapshot?.percent,
                         charging: controller.charging)
                .opacity(controller.connected ? 1 : 0.55)
        }
    }
}

/// The battery as a ring with the percentage inside.
struct BatteryGauge: View {
    let percent: Int?
    let charging: Bool

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: 5)
            Circle()
                .trim(from: 0, to: CGFloat(percent ?? 0) / 100)
                .stroke(percent.map(batteryLevelColor(forPercent:)) ?? .secondary,
                        style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut, value: percent)
            VStack(spacing: 0) {
                if charging { Image(systemName: "bolt.fill").font(.system(size: 9, weight: .bold)) }
                Text(percent.map { "\($0)%" } ?? "—")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        }
        .frame(width: 62, height: 62)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(percent.map { "Battery \($0)%\(charging ? ", charging" : "")" } ?? "Battery unknown")
    }
}

/// A sheet with a title and a Done button, for what opens from a tile.
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
