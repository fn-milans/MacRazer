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

/// Shown when a Razer mouse is on Bluetooth but not under control: either a model with no
/// Bluetooth control (switch modes), or a supported one Serpentine can't reach right now.
struct BluetoothNoticeCard: View {
    @ObservedObject var controller: MouseController

    var body: some View { bluetoothNotice }

    /// The notice, by why the mouse isn't under control.
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

extension MouseController {
    /// The battery's state in a line: time left, charging, or the last reading while away.
    @MainActor var batteryStatusLine: String {
        if !connected {
            if let snapshot = lastBatterySnapshot {
                let age = LastBatterySnapshot.relativeAgeFormatter.localizedString(for: snapshot.observedAt, relativeTo: Date())
                if snapshot.wasCharging { return "Last reading: \(snapshot.percent)% · charging · \(age)" }
                if let estimate = snapshot.shortEstimateText {
                    return "\(estimate) · \(age)"
                }
                return "Last reading: \(snapshot.percent)% · \(age) · no estimate yet"
            }
            switch bluetoothMouse {
            case .needsModeSwitch: return "On Bluetooth. Use 2.4 GHz or USB-C"
            case .connecting: return "On Bluetooth. Connecting…"
            case .accessDenied: return "On Bluetooth. Needs Bluetooth access"
            case nil: break
            }
            if needsInputMonitoring { return "Needs Input Monitoring permission" }
            return "Disconnected. Wake the mouse and refresh"
        }
        if charging { return "Charging" }
        if let est = timeEstimate { return est }
        if batteryPercent != nil { return "Estimating time remaining…" }
        return "Reading battery…"
    }
}
