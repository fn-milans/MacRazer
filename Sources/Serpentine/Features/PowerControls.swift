// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import SwiftUI
import AppKit
import RazerProtocol
import RazerDeviceKit

/// The mouse's sleep timer and its low-battery level. The values are the owner's, which
/// shows them in the collapsed row.
struct PowerControls: View {
    @ObservedObject var controller: MouseController
    @Binding var sleepTimeoutValue: Double
    @Binding var lowBatteryValue: Double
    /// Which of the two to show; the dashboard gives each its own tile.
    var parts: Parts = .all

    enum Parts { case all, sleep, lowBattery }

    var body: some View { powerManagementContent }

    /// The Power Management row's expanded content: the sleep timer, then the
    /// mouse's low-battery threshold. The row shows the first of the two.
    private var powerManagementContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if parts != .lowBattery, controller.supportsSleepTimeout { sleepTimeoutControls }
            if parts != .sleep, controller.lowBatteryThreshold != nil { lowBatteryControls }
        }
    }

    /// Where the mouse goes into its own low-battery mode, 5% to 50%; the factory 33% is in
    /// the presets.
    private var lowBatteryControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "battery.25").font(.system(size: 10)).foregroundStyle(.secondary)
                Text("Low battery at").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(lowBatteryValue))%").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: snapped($lowBatteryValue, to: 1, from: 5), in: 5...50) { editing in
                if !editing { controller.setLowBatteryThreshold(Int(lowBatteryValue)) }
            }
            .tint(.razerGreen)
            .controlSize(.small)
            HStack(spacing: 5) {
                ForEach([5, 10, 20, 33, 50], id: \.self) { value in
                    Button {
                        lowBatteryValue = Double(value)
                        controller.setLowBatteryThreshold(value)
                    } label: {
                        Text("\(value)%")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 9.5, weight: Int(lowBatteryValue) == value ? .semibold : .regular).monospacedDigit())
                    .foregroundStyle(Int(lowBatteryValue) == value ? Color.onRazerGreen : Color.secondary)
                    .frame(maxWidth: .infinity).frame(height: 23)
                    .background(Int(lowBatteryValue) == value ? Color.razerGreen : Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    .hoverHighlight(RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel("Low battery at \(value)%")
                }
            }
        }
        .help("The battery level at which the mouse goes into its own low-battery mode. Saved in the mouse.")
    }

    private var sleepTimeoutControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "moon.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                Slider(value: snapped($sleepTimeoutValue, to: 15, from: 60), in: 60...900) { editing in
                    if !editing { controller.setSleepTimeout(Int(sleepTimeoutValue)) }
                }
                .tint(.razerGreen)
                .controlSize(.small)
            }
            .disabled(controller.sleepTimeout == nil)
            HStack(spacing: 5) {
                ForEach([60, 120, 300, 600, 900], id: \.self) { value in
                    Button {
                        sleepTimeoutValue = Double(value)
                        controller.setSleepTimeout(value)
                    } label: {
                        Text(Self.formatSleepTimeout(value, compact: true))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 9.5, weight: Int(sleepTimeoutValue) == value ? .semibold : .regular).monospacedDigit())
                    .foregroundStyle(Int(sleepTimeoutValue) == value ? Color.onRazerGreen : Color.secondary)
                    .frame(maxWidth: .infinity).frame(height: 23)
                    .background(Int(sleepTimeoutValue) == value ? Color.razerGreen : Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    .hoverHighlight(RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel("Sleep after \(Self.formatSleepTimeout(value))")
                }
            }
            .disabled(controller.sleepTimeout == nil)
            if let error = controller.sleepTimeoutError {
                Text(error).font(.system(size: 10.5)).foregroundStyle(Color.batteryLow)
            }
        }
    }

    /// Nothing to show until the mouse has reported its value: the slider's starting position
    /// is a placeholder, not the mouse's setting.
    ///
    /// A failed write turns the value red (see the row) rather than replacing it: the mouse's
    /// last confirmed timeout is still the useful thing to show, and the error itself is in
    /// the expanded controls.
    static func sleepTimeoutSummary(_ controller: MouseController, value: Double) -> String {
        controller.sleepTimeout == nil ? "…" : formatSleepTimeout(Int(value))
    }

    static func lowBatterySummary(_ controller: MouseController, value: Double) -> String {
        controller.lowBatteryThreshold == nil ? "…" : "Low at \(Int(value))%"
    }

    /// "5 min" or "4 min 45 s", the way System Settings words its sleep timers, instead of
    /// "5m 00s". `compact` is for the preset chips, five to a row: "5m".
    static func formatSleepTimeout(_ seconds: Int, compact: Bool = false) -> String {
        let minutes = seconds / 60, rest = seconds % 60
        if compact { return rest == 0 ? "\(minutes)m" : "\(minutes)m\(rest)s" }
        return rest == 0 ? "\(minutes) min" : "\(minutes) min \(rest) s"
    }

}
