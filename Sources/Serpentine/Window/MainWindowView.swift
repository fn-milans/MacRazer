// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import SwiftUI
import RazerProtocol

/// The main window: the mouse and its sections in the sidebar, the selected section's
/// controls beside it. The panes are built from the same feature views as the popover.
struct MainWindowView: View {
    @ObservedObject var controller: MouseController
    @ObservedObject var remapper: ButtonRemapper
    @ObservedObject var navigation: WindowNavigation

    /// The sections this mouse has, in sidebar order.
    private var sections: [PaneSection] {
        PaneSection.allCases.filter { $0.isAvailable(for: controller) && Self.built.contains($0) }
    }

    /// The panes that exist so far.
    static let built: Set<PaneSection> = [.overview]

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            detail
        }
        .frame(minWidth: 780, minHeight: 540)
        // A section that disappears (another mouse, a capability turning out to be missing)
        // falls back to Overview rather than leaving the detail empty.
        .onChange(of: sections) { _, available in
            if !available.contains(navigation.section) { navigation.section = .overview }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: Binding(get: { navigation.section }, set: { if let s = $0 { navigation.section = s } })) {
            Section("Devices") {
                DeviceSidebarRow(controller: controller)
                    .selectionDisabled()
            }
            Section(controller.deviceName.map(Self.shortName) ?? "Mouse") {
                ForEach(sections) { section in
                    Label(section.title, systemImage: section.symbol)
                        .tag(section)
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// "Razer Basilisk V4 Pro (Wireless)" reads as "Basilisk V4 Pro" in the sidebar heading.
    static func shortName(_ name: String) -> String {
        var short = name.hasPrefix("Razer ") ? String(name.dropFirst(6)) : name
        if let paren = short.range(of: " (") { short = String(short[..<paren.lowerBound]) }
        return short
    }

    // MARK: Detail

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                pane(navigation.section)
            }
            .padding(24)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(navigation.section.title)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    controller.refreshAll()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Read the mouse again (⌘R)")
                .disabled(controller.isRefreshing)
            }
        }
    }

    private var subtitle: String {
        guard let name = controller.deviceName ?? controller.bluetoothMouse?.name else { return "No mouse connected" }
        return controller.connected ? "\(Self.shortName(name)) · \(linkName)" : "\(Self.shortName(name)) · offline"
    }

    private var linkName: String {
        switch RazerDevices.connection(pid: controller.deviceID) {
        case .bluetooth: return "Bluetooth"
        case .wired: return "Wired"
        case .wirelessDongle: return controller.charging ? "Wired" : "2.4 GHz"
        case nil: return "USB"
        }
    }

    @ViewBuilder
    private func pane(_ section: PaneSection) -> some View {
        switch section {
        default:
            OverviewPane(controller: controller, remapper: remapper, navigation: navigation)
        }
    }
}

/// The sidebar's device row: the model, its link, and the battery.
private struct DeviceSidebarRow: View {
    @ObservedObject var controller: MouseController

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: MenuBarIcon.mouseModel(pid: controller.deviceID, pointSize: 20))
                .renderingMode(.template)
                .resizable().scaledToFit()
                .frame(width: 20, height: 20)
                .foregroundStyle(controller.connected ? Color.razerGreenText : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(controller.deviceName.map(MainWindowView.shortName) ?? "No mouse")
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Text(controller.connected ? "Connected" : (controller.deviceName == nil ? "Connect a Razer mouse" : "Offline"))
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if controller.deviceHasBattery, let pct = controller.batteryPercent {
                BatteryRing(percent: pct, charging: controller.charging)
                    .opacity(controller.connected ? 1 : 0.5)
            }
        }
        .padding(.vertical, 3)
    }
}

/// A small ring that fills with the battery level.
struct BatteryRing: View {
    let percent: Int
    let charging: Bool

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.15), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: CGFloat(percent) / 100)
                .stroke(batteryLevelColor(forPercent: percent), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if charging {
                Image(systemName: "bolt.fill").font(.system(size: 7, weight: .bold))
            }
        }
        .frame(width: 18, height: 18)
        .help(charging ? "\(percent)%, charging" : "\(percent)%")
        .accessibilityLabel("Battery \(percent)%\(charging ? ", charging" : "")")
    }
}
