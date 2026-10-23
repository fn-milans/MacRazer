// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import SwiftUI

/// Settings for Serpentine itself, the sheet behind the main window's cog: set once and rarely
/// revisited, with room to explain themselves (why the login item is unavailable from a
/// mounted disk image).
struct SettingsView: View {
    @ObservedObject var controller: MouseController
    var launchAtLogin: LaunchAtLogin
    @ObservedObject var background: BackgroundMode
    @ObservedObject var appearance: AppearanceSettings = .shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            titledSection("General") {
                backgroundRow
                launchAtLoginRow
                connectionSoundsRow
            }
            titledSection("Appearance") {
                themeRow
                glassRow
            }
        }
        // The login switch mirrors the system's registration, which the user can change in
        // System Settings while the window sits open in the background.
        .onAppear { launchAtLogin.refresh() }
    }

    // MARK: Rows

    private var backgroundRow: some View {
        settingRow(
            title: "Keep running in the background",
            detail: "Closing the window leaves Serpentine in the menu bar, so what only it can do keeps "
                + "working: remaps the mouse can't store, the DPI Cycle action, low-battery alerts and "
                + "battery history. Off, closing the window quits; the mouse keeps its own settings.",
            isOn: $background.isEnabled
        )
    }

    private var launchAtLoginRow: some View {
        settingRow(
            title: "Start Serpentine at login",
            detail: "Starts in the menu bar after a restart, without a window. Needs Serpentine to keep running in the background.",
            isOn: Binding(get: { launchAtLogin.isEnabled }, set: { launchAtLogin.setEnabled($0) }),
            enabled: launchAtLogin.isSupported && background.isEnabled
        ) {
            // Shown rather than hidden when unavailable: running straight from the disk image
            // is a real thing people do, and "why is this switch dead" deserves an answer.
            if !launchAtLogin.isSupported {
                sectionNote("Move Serpentine to your Applications folder to use this. A login item "
                     + "pointing into a disk image stops working the moment it's ejected.")
            } else if let error = launchAtLogin.lastError {
                sectionNote(error, color: .batteryLow)
            } else if launchAtLogin.needsApproval {
                Button("Approve Serpentine in Login Items…") { launchAtLogin.openLoginItemsSettings() }
                    .buttonStyle(.plain).font(.system(size: 11))
                    .foregroundStyle(Color.razerGreenText)
            }
        }
    }

    private var connectionSoundsRow: some View {
        settingRow(
            title: "Connection sounds",
            detail: "Play a sound when the mouse connects or disconnects.",
            isOn: Binding(get: { controller.connectionSoundsEnabled },
                          set: { controller.connectionSoundsEnabled = $0 })
        )
    }

    private var themeRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Theme").font(.system(size: 12.5, weight: .medium))
                Spacer(minLength: 12)
                Picker("Theme", selection: $appearance.theme) {
                    ForEach(AppearanceTheme.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            sectionNote("System follows macOS. Razer Green is always dark.")
        }
    }

    private var glassRow: some View {
        settingRow(
            title: "Glass effect",
            detail: "The window lets the desktop show through. Turn it off for a solid "
                + "background, which is easier to read over busy windows.",
            isOn: $appearance.glass
        )
    }

    // MARK: Building blocks

    /// A labelled switch with its explanation underneath, plus an optional slot for a caption
    /// that only appears in some states (unavailable, needs approval, failed).
    private func settingRow<Extra: View>(
        title: String, detail: String, isOn: Binding<Bool>, enabled: Bool = true,
        @ViewBuilder extra: () -> Extra = { EmptyView() }
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: isOn) {
                Text(title).font(.system(size: 12.5, weight: .medium))
            }
            .toggleStyle(.switch)
            .tint(.razerGreen)
            .controlSize(.small)
            .disabled(!enabled)
            sectionNote(detail)
            extra()
        }
        .opacity(enabled ? 1 : 0.55)
    }
}
