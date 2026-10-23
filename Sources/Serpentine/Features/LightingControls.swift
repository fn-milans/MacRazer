// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import SwiftUI
import AppKit
import RazerProtocol
import RazerDeviceKit

/// Brightness, effect and colour, per zone on mice lit zone by zone. The brightness and the
/// colour are the popover's: the collapsed row shows the one, the colour page edits the other.
struct LightingControls: View {
    @ObservedObject var controller: MouseController
    @Binding var brightnessValue: Double
    @Binding var color: Color
    var onPickColor: () -> Void

    var body: some View { lightingContent }

    // Distinct hues with a true red (SwiftUI .red is a warm orange-red; .green duplicated razerGreen).
    // Each carries its spoken/tooltip name.
    private let swatches: [(name: String, color: Color)] = [
        ("Red", Color(red: 1.0, green: 0.0, blue: 0.0)),
        ("Orange", Color(red: 1.0, green: 0.5, blue: 0.0)),
        ("Yellow", Color(red: 1.0, green: 0.85, blue: 0.0)),
        ("Green", .razerGreen),
        ("Cyan", Color(red: 0.0, green: 0.8, blue: 1.0)),
        ("Blue", Color(red: 0.15, green: 0.35, blue: 1.0)),
        ("Purple", Color(red: 0.6, green: 0.2, blue: 1.0)),
        ("Pink", Color(red: 1.0, green: 0.2, blue: 0.65)),
    ]

    /// The Lighting row's expanded content; the row itself shows the effect and brightness.
    private var lightingContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Which part of the mouse the controls below change, on mice lit zone by zone.
            if !controller.lightingZones.isEmpty {
                Picker("", selection: Binding(get: { controller.selectedLightingZone },
                                              set: { controller.selectLightingZone($0) })) {
                    Text("All").tag(LightingZone?.none)
                    ForEach(controller.lightingZones) { Text($0.name).tag(LightingZone?.some($0)) }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .labelsHidden()
            }
            // Brightness.
            HStack(spacing: 6) {
                Image(systemName: "sun.min.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                Slider(value: snapped($brightnessValue, to: 1), in: 0...100) { editing in
                    if !editing { controller.setBrightness(Int(brightnessValue)) }
                }
                .tint(.razerGreen)
                .controlSize(.small)
                Image(systemName: "sun.max.fill").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            // Bound straight to the controller: setEffect publishes only on a successful
            // device write, so a failed change snaps the picker back by itself — no local
            // state, no suppression flags.
            if controller.supportsLightingEffects {
                Picker("", selection: Binding(get: { controller.effect },
                                              set: { controller.setEffect($0) })) {
                    ForEach(controller.lightingEffects) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .labelsHidden()
            }

            if controller.effect.usesColor || !controller.supportsLightingEffects {
                HStack(spacing: 7) {
                    ForEach(swatches.indices, id: \.self) { i in
                        swatch(swatches[i].color, name: swatches[i].name)
                    }
                    customColorWell
                    Spacer(minLength: 0)
                }
                .transition(.opacity)
            }

            if showsLightingBatteryHint {
                Label("Bright lighting drains the battery faster. Around \(Battery.lightingHintBrightnessPercent)% "
                      + "or lower lasts noticeably longer.", systemImage: "leaf")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
    }

    /// What the collapsed Lighting row says: the effect and brightness, or just the brightness
    /// where effects can't be read (Bluetooth), or "Off".
    static func summary(_ controller: MouseController, brightness brightnessValue: Double) -> String {
        // 0% draws nothing whatever the effect, the same rule `showsLightingBatteryHint` uses.
        if Int(brightnessValue) == 0 { return "Off" }
        if !controller.supportsLightingEffects { return "\(Int(brightnessValue))%" }
        // All zones selected but lit differently: no one effect describes them.
        if controller.selectedLightingZone == nil, !controller.zonesMatch { return "Per zone" }
        if controller.effect == .off { return "Off" }
        return "\(controller.effect.rawValue) · \(Int(brightnessValue))%"
    }

    /// Reads the local slider value, not `controller.brightness`, so the hint tracks the
    /// thumb while it's dragged rather than appearing only after the write lands. Skipped
    /// while charging (the drain doesn't matter then) and with lighting off (0% or `.off`
    /// both mean the LEDs draw nothing, whatever the slider says).
    private var showsLightingBatteryHint: Bool {
        // Bluetooth can't set or read an effect, only a colour, so `effect` there is left
        // over from USB and says nothing about whether the lights are on.
        controller.deviceHasBattery && !controller.charging
            && (controller.effect != .off || !controller.supportsLightingEffects)
            && Int(brightnessValue) > Battery.lightingHintBrightnessPercent
    }

    /// A real button rather than a tap gesture on a circle, so it reaches VoiceOver and
    /// keyboard navigation, and greys out with the rest of the card while disconnected.
    private func swatch(_ sw: Color, name: String) -> some View {
        Button { controller.setStaticColor(sw.rgb) } label: {
            Circle()
                .fill(sw)
                .frame(width: 18, height: 18)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
                .overlay(Circle().inset(by: -2.5).stroke(Color.primary, lineWidth: isSelected(sw) ? 1.5 : 0))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected(sw) ? .isSelected : [])
    }

    /// Circular "custom colour" well — a rainbow ring that opens the system colour panel.
    /// Uses a real button + NSColorPanel bridge (the hidden-ColorPicker trick didn't register
    /// clicks).
    private var customColorWell: some View {
        Button {
            onPickColor()
        } label: {
            ZStack {
                Circle().fill(AngularGradient(
                    gradient: Gradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red]),
                    center: .center))
                Image(systemName: "eyedropper").font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(radius: 1)
            }
            .frame(width: 18, height: 18)
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help("Pick any colour")
        .accessibilityLabel("Custom colour")
    }

    private func isSelected(_ sw: Color) -> Bool {
        let a = sw.rgb, b = color.rgb
        return a.r == b.r && a.g == b.g && a.b == b.b
    }

}
