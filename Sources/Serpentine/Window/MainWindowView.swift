// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import SwiftUI
import RazerProtocol

/// The main window: one column of cards on the glass, like the menu bar popover was, with the
/// page (Mouse, Buttons, Settings) chosen in the title bar.
struct MainWindowView: View {
    @ObservedObject var controller: MouseController
    @ObservedObject var remapper: ButtonRemapper
    @ObservedObject var navigation: WindowNavigation
    var permissions: PermissionsModel
    @ObservedObject var background: BackgroundMode
    var launchAtLogin: LaunchAtLogin

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if !permissions.allRequiredGranted { setupBanner }
                if navigation.page != .settings, !background.isEnabled, !driverModeFeatures.isEmpty {
                    driverModeBanner
                }
                switch navigation.page {
                case .mouse:
                    MousePage(controller: controller, remapper: remapper, navigation: navigation)
                case .buttons:
                    card { RemapView(remapper: remapper, controller: controller) }
                        .disabled(!controller.connected)
                case .settings:
                    SettingsView(controller: controller, launchAtLogin: launchAtLogin, background: background)
                }
            }
            .padding(16)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 480, minHeight: 520)
        .navigationTitle("Serpentine")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Page", selection: $navigation.page) {
                    ForEach(WindowPage.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            // One group at the trailing edge: the status, the profile, Refresh.
            ToolbarItemGroup(placement: .primaryAction) {
                syncStatus
                profileMenu
                Button {
                    controller.refreshAll()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Read the mouse again (⌘R)")
                .disabled(controller.isRefreshing)
            }
        }
        .sheet(isPresented: $navigation.showingSetup) {
            PermissionsView(model: permissions, controller: controller,
                            onDone: { navigation.showingSetup = false })
        }
    }

    /// "Razer Basilisk V4 Pro (Wireless)" reads as "Basilisk V4 Pro" in the menu bar item.
    static func shortName(_ name: String) -> String {
        var short = name.hasPrefix("Razer ") ? String(name.dropFirst(6)) : name
        if let paren = short.range(of: " (") { short = String(short[..<paren.lowerBound]) }
        return short
    }

    // MARK: Toolbar

    /// Whether what was last changed reached the mouse.
    @ViewBuilder
    private var syncStatus: some View {
        if controller.connected {
            if let error = controller.onboardWriteError {
                Label("Not all saved", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.batteryMid)
                    .help(error)
            } else {
                Label("In the mouse", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.razerGreenText)
                    .help("The mouse holds these settings itself.")
            }
        }
    }

    /// The profile in use, and the others to switch to: the mouse's slots, or saved profiles.
    @ViewBuilder
    private var profileMenu: some View {
        if controller.usesSlotProfiles {
            Menu {
                ForEach(controller.onboardSlotList, id: \.self) { slot in
                    Toggle(controller.slotName(slot), isOn: Binding(
                        get: { controller.activeOnboardSlot == slot },
                        set: { if $0 { controller.switchToSlot(slot) } }))
                }
            } label: {
                Label(controller.activeOnboardSlot.map(controller.slotName) ?? "Profile",
                      systemImage: "person.crop.square")
            }
            .labelStyle(.titleAndIcon)
            .help("Switch the mouse's profile")
            .disabled(!controller.connected)
        } else if controller.supportsProfiles, !controller.profiles.isEmpty {
            Menu {
                ForEach(controller.profiles) { profile in
                    Toggle(profile.name, isOn: Binding(
                        get: { controller.activeProfileID == profile.id },
                        set: { if $0 { controller.applyProfile(profile, remapper: remapper) } }))
                }
            } label: {
                Label(controller.profiles.first { $0.id == controller.activeProfileID }?.name ?? "Profile",
                      systemImage: "person.crop.square")
            }
            .labelStyle(.titleAndIcon)
            .help("Apply a saved profile")
            .disabled(!controller.connected)
        }
    }

    // MARK: Banners

    private var setupBanner: some View {
        banner(symbol: "lock.shield", title: "Serpentine needs Input Monitoring",
               detail: "macOS asks for it before any app can talk to a mouse over USB.",
               action: "Set Up…") { navigation.showingSetup = true }
    }

    private var driverModeFeatures: [String] {
        DriverModeUsage.features(controller: controller, remapper: remapper)
    }

    /// What stops when the window closes, while Serpentine doesn't keep running.
    private var driverModeBanner: some View {
        banner(symbol: "macwindow", title: "Some settings need Serpentine running",
               detail: driverModeFeatures.joined(separator: ", ") + " stop when you close this window.",
               action: "Keep Running") { background.isEnabled = true }
    }

    private func banner(symbol: String, title: String, detail: String, action: String,
                        perform: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(Color.batteryMid)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(action, action: perform)
        }
        .padding(12)
        .background(Color.batteryMid.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
    }
}
