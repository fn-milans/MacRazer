// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import SwiftUI
import AppKit
import RazerProtocol
import RazerDeviceKit

/// The battery: level, gauge, time left or last reading, and the way to the usage history.
struct BatteryCard: View {
    @ObservedObject var controller: MouseController
    /// The view is on screen; the offline age only re-renders then.
    var isShown: Bool
    var onShowUsage: () -> Void

    private var needsPermission: Bool { controller.needsInputMonitoring }
    private var noMouse: Bool { controller.noMouseKnown }

    var body: some View { batteryCard }

    private var batteryLevel: Double { Double(controller.batteryPercent ?? 0) / 100 }
    private var batteryColor: Color {
        // No reading yet (nil) is "unknown," not "critically low" — don't flash red before the
        // first successful poll completes.
        guard let pct = controller.batteryPercent else { return .secondary }
        return batteryLevelColor(forPercent: pct)
    }

    private var batteryCard: some View {
        card {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                batteryGauge
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(verbatim: controller.batteryPercent.map { "\($0)" } ?? "—")
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(controller.batteryPercent ?? 100 < Battery.lowThresholdPercent ? Color.batteryLow : .primary)
                        .contentTransition(.numericText())
                    Text("%").font(.system(size: 17, weight: .medium)).foregroundStyle(.secondary)
                }
                Spacer()
                usageButton
                refreshButton
            }
            // State-coloured level bar.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule().fill(batteryColor)
                        .frame(width: max(6, geo.size.width * batteryLevel))
                        .animation(.easeInOut, value: batteryLevel)
                }
            }
            .frame(height: 6)
            // Offline and on screen, re-rendered every 30 s so the "· 2 min. ago" age keeps up:
            // nothing else republishes while the mouse is away. Otherwise no timer at all, so a
            // closed popover never wakes the app.
            if isShown && !controller.connected {
                TimelineView(.periodic(from: .now, by: 30)) { _ in batterySubtitleText }
            } else {
                batterySubtitleText
            }
            // With no mouse at all, `noMouseCard` below carries this button instead.
            if needsPermission && !noMouse {
                Button {
                    AppDelegate.openInputMonitoringSettings()
                } label: {
                    Label("Grant Input Monitoring…", systemImage: "lock.shield")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.razerGreenText)
            }
        }
        }
    }

    /// Custom battery glyph whose fill is proportional to the exact charge level and
    /// coloured by state — so it visibly tracks the percentage (the SF Symbol only had 5 steps).
    private var batteryGauge: some View {
        let bodyW: CGFloat = 30, bodyH: CGFloat = 15, inset: CGFloat = 2.5
        let level = controller.batteryPercent == nil ? 0 : batteryLevel
        return HStack(spacing: 2) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.secondary.opacity(0.55), lineWidth: 1.5)
                RoundedRectangle(cornerRadius: 2)
                    .fill(batteryColor)
                    .frame(width: max(2, (bodyW - inset * 2) * level), height: bodyH - inset * 2)
                    .padding(.leading, inset)
                    .animation(.easeInOut, value: level)
            }
            .frame(width: bodyW, height: bodyH)
            .overlay {
                if controller.charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.35), radius: 0.5)
                }
            }
            // Battery terminal nub.
            Capsule()
                .fill(Color.secondary.opacity(0.55))
                .frame(width: 2.5, height: 5.5)
        }
    }

    private var batterySubtitleText: some View {
        Text(batterySubtitle).font(.system(size: 11)).foregroundStyle(.secondary)
    }

    private var batterySubtitle: String {
        if !controller.connected {
            if let snapshot = controller.lastBatterySnapshot {
                let age = LastBatterySnapshot.relativeAgeFormatter.localizedString(for: snapshot.observedAt, relativeTo: Date())
                if snapshot.wasCharging { return "Last reading: \(snapshot.percent)% · charging · \(age)" }
                if let estimate = snapshot.shortEstimateText {
                    return "\(estimate) · \(age)"
                }
                return "Last reading: \(snapshot.percent)% · \(age) · no estimate yet"
            }
            switch controller.bluetoothMouse {
            case .needsModeSwitch: return "On Bluetooth. Use 2.4 GHz or USB-C"
            case .connecting: return "On Bluetooth. Connecting…"
            case .accessDenied: return "On Bluetooth. Needs Bluetooth access"
            case nil: break
            }
            if needsPermission { return "Needs Input Monitoring permission" }
            return "Disconnected. Wake the mouse and refresh"
        }
        if controller.charging { return "Charging" }
        if let est = controller.timeEstimate { return est }
        if controller.batteryPercent != nil { return "Estimating time remaining…" }
        return "Reading battery…"
    }

    private var usageButton: some View {
        Button { onShowUsage() } label: {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("View battery usage history")
        .accessibilityLabel("Battery usage history")
    }

    private var refreshButton: some View {
        Button {
            controller.refreshAll()
        } label: {
            ZStack {
                if controller.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .medium))
                }
            }
            .frame(width: 16, height: 16)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(controller.supportsPollRate ? "Refresh battery, DPI and polling rate (⌘R)" : "Refresh battery and DPI (⌘R)")
        .accessibilityLabel("Refresh")
        .disabled(controller.isRefreshing)
    }

}
