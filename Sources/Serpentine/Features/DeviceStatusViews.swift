// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import SwiftUI
import AppKit
import RazerProtocol
import RazerDeviceKit

extension MouseController {
    /// No mouse is known at all: never seen this session, or unplugged (which forgets its
    /// name). Not a sleeping or out-of-range one, which keeps its name and its dimmed
    /// controls.
    var noMouseKnown: Bool { !connected && deviceName == nil && bluetoothMouse == nil }

    /// The last failure was macOS refusing HID access: Input Monitoring isn't granted.
    var needsInputMonitoring: Bool {
        guard !connected, let err = lastError else { return false }
        return HIDDevice.errorLooksPermissionDenied(err)
    }
}

/// The mouse's name, link and connection state.
struct DeviceHeaderCard: View {
    @ObservedObject var controller: MouseController

    var body: some View { headerCard }

    var headerCard: some View {
        card {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9).fill(Color.razerGreenBright.opacity(0.20))
                    Image(nsImage: MenuBarIcon.mouseModel(pid: controller.deviceID, pointSize: 20))
                        .renderingMode(.template)
                        .resizable().scaledToFit()
                        .frame(width: 19, height: 19)
                        .foregroundStyle(Color.razerGreenBright)
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(controller.deviceName ?? controller.bluetoothMouse?.name
                         ?? controller.lastBatterySnapshot?.deviceName ?? "No mouse connected")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Text(headerSubtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        if let ct = connectionType { connectionChip(ct) }
                    }
                }
                Spacer()
                Circle()
                    .fill(controller.connected ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel(controller.connected ? "Connected" : "Not connected")
            }
        }
    }

    var headerSubtitle: String {
        switch controller.bluetoothRecoveryState {
        case .reconnecting where !controller.connected: return "Reconnecting…"
        default: break
        }
        if controller.connected { return controller.deviceSupported ? "Connected" : "Connected · limited support" }
        if controller.bluetoothMouse != nil { return "On Bluetooth" }
        if controller.deviceName != nil { return "Offline" }
        return "Connect a Razer mouse"
    }

    /// The active control transport, shown as a small chip beside "Connected". Resolved from
    /// the registry — the PID identifies the link (wireless models enumerate under a
    /// different PID when cabled). The old `charging ⇒ wired` heuristic mislabeled every
    /// wired-only mouse as "2.4 GHz", since a wired mouse never reports charging.
    /// Bluetooth only reads "Connected" for models with Bluetooth control; any other Razer
    /// mouse on Bluetooth is surfaced separately (`bluetoothNotice`).
    var connectionType: ConnectionChip? {
        guard controller.connected else { return nil }
        switch RazerDevices.connection(pid: controller.deviceID) {
        case .bluetooth:
            // Blue, the colour macOS and the mouse itself use for Bluetooth, so the link
            // reads at a glance as different from the green USB ones. A stronger fill than
            // theirs, or the blue is hard to read on the dark background.
            return ConnectionChip(symbol: "dot.radiowaves.left.and.right", label: "Bluetooth",
                                  tint: .bluetoothBlue, fillOpacity: 0.3)
        case .wired:
            return ConnectionChip(symbol: "cable.connector", label: "Wired")
        case .wirelessDongle:
            // `charging` implies a USB-C cable is attached, even though control still
            // flows through the dongle's PID.
            return controller.charging
                ? ConnectionChip(symbol: "cable.connector", label: "Wired")
                : ConnectionChip(symbol: "antenna.radiowaves.left.and.right", label: "2.4 GHz")
        case nil:
            // Unknown model: "USB" is true for both a cable and a dongle.
            return ConnectionChip(symbol: "cable.connector", label: "USB")
        }
    }

    /// How a link's chip looks: green for the USB links, blue for Bluetooth.
    struct ConnectionChip {
        let symbol: String
        let label: String
        var tint: Color = .razerGreenText
        var fillOpacity: Double = 0.15
    }

    func connectionChip(_ ct: ConnectionChip) -> some View {
        HStack(spacing: 3) {
            Image(systemName: ct.symbol).font(.system(size: 8.5, weight: .bold))
            Text(ct.label).font(.system(size: 9.5, weight: .semibold))
        }
        .foregroundStyle(ct.tint)
        .padding(.horizontal, 5).padding(.vertical, 1.5)
        .background(ct.tint.opacity(ct.fillOpacity), in: Capsule())
    }

}

/// Shown when a Razer mouse is on Bluetooth but not under control: either a model with no
/// Bluetooth control (switch modes), or a supported one Serpentine can't reach right now.
struct BluetoothNoticeCard: View {
    @ObservedObject var controller: MouseController

    var body: some View { bluetoothNotice }

    /// Shown when a Razer mouse is on Bluetooth but not under control: either a model with no
    /// Bluetooth control (switch modes), or a supported one Serpentine can't reach right now.
    var bluetoothNoticeText: String {
        switch controller.bluetoothMouse {
        case .accessDenied(let name):
            return "\(name) can be controlled over Bluetooth, but Serpentine isn't allowed to use Bluetooth. Turn it on in System Settings → Privacy & Security → Bluetooth."
        case .connecting(let name):
            return "Serpentine couldn't reach \(name) over Bluetooth yet. It will keep trying."
        case .needsModeSwitch(let name):
            return "\(name) only reports battery, DPI and lighting over the 2.4 GHz dongle or USB-C, not over Bluetooth. Switch its mode to use Serpentine."
        case nil:
            return ""
        }
    }

    var bluetoothNotice: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .foregroundStyle(Color.batteryMid)
                .font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text("Connected via Bluetooth").font(.system(size: 12, weight: .semibold))
                Text(bluetoothNoticeText)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.batteryMid.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
    }

}

/// With no model to describe, the mouse controls would be placeholders for a mouse that isn't
/// there, so the page shows one card that says what to do, the way Control Center's Bluetooth
/// module does with nothing paired.
struct NoMouseCard: View {
    @ObservedObject var controller: MouseController

    private var needsPermission: Bool { controller.needsInputMonitoring }

    var body: some View { noMouseCard }

    var noMouseCard: some View {
        card {
            VStack(spacing: 8) {
                Image(systemName: "computermouse")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(needsPermission ? "Serpentine can't see your mouse yet" : "No Razer mouse found")
                    .font(.system(size: 12.5, weight: .semibold))
                Text(needsPermission
                     ? "It needs Input Monitoring permission to talk to the mouse."
                     : "Plug in the wireless dongle or a USB cable, or move the mouse to wake it.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if needsPermission {
                    Button {
                        AppDelegate.openInputMonitoringSettings()
                    } label: {
                        Label("Grant Input Monitoring…", systemImage: "lock.shield")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.razerGreenText)
                } else {
                    Button {
                        controller.refreshAll()
                    } label: {
                        Text(controller.isRefreshing ? "Looking…" : "Look Again")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(controller.isRefreshing)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
    }

}
