// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import SwiftUI
import AppKit
import RazerProtocol

/// A colour with one value for light surfaces and one for dark, picked by whatever the view is
/// drawn in. The windows can be either, depending on Settings › Appearance.
private func adaptive(light: NSColor, dark: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil) { $0.isDark ? dark : light })
}

extension Color {
    /// Razer brand green (#44D62C) — the single accent, as a fill: slider, active chip/segment,
    /// switches. The same in light and dark. For green text or icons use `razerGreenText`.
    static let razerGreen = Color(nsColor: NSColor(hex: 0x44D62C))
    /// Green for text and icons. The brand green is too light to read on a light background,
    /// so light surfaces get a darker green (#23891A).
    static let razerGreenText = adaptive(light: NSColor(hex: 0x23891A), dark: NSColor(hex: 0x44D62C))
    /// Text and icons drawn on a `razerGreen` fill. Dark in every theme: white on #44D62C is
    /// only about 1.9:1 contrast.
    static let onRazerGreen = Color(nsColor: NSColor(hex: 0x0D2B07))
    /// The logo's green: brighter than the brand green so it pops on dark, and the darker
    /// text green on light, where a bright green washes out.
    static let razerGreenBright = adaptive(light: NSColor(hex: 0x23891A), dark: NSColor(hex: 0x6BFF40))
    /// The Bluetooth chip's colour. System blue is too dark to read on a dark background,
    /// and this lighter blue too pale on a light one.
    static let bluetoothBlue = adaptive(light: NSColor(hex: 0x0A64D6), dark: NSColor(hex: 0x78B8FF))
    // Battery *state* uses Apple system colors (meaning), never the brand green.
    static let batteryFull = Color(red: 0x34 / 255, green: 0xC7 / 255, blue: 0x59 / 255)
    static let batteryMid = Color(red: 0xFF / 255, green: 0x9F / 255, blue: 0x0A / 255)
    static let batteryLow = Color(red: 0xFF / 255, green: 0x45 / 255, blue: 0x3B / 255)
}

extension Color {
    /// Convert to an 8-bit RGB triple for the device.
    var rgb: RGB {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .red
        return RGB(
            r: UInt8((ns.redComponent * 255).rounded()),
            g: UInt8((ns.greenComponent * 255).rounded()),
            b: UInt8((ns.blueComponent * 255).rounded())
        )
    }
}
extension RGB {
    /// The device triple as a SwiftUI color (inverse of `Color.rgb`).
    var swiftUIColor: Color {
        Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }
}

/// A slider's value, rounded to `step` counted from `lower`. `Slider(step:)` rounds the
/// same way, but on macOS it also draws a tick mark per step and rebuilds them each time
/// the main page appears: 999 on the Basilisk V4 Pro's DPI slider, which held up the way
/// back from Configure Buttons.
func snapped(_ value: Binding<Double>, to step: Double, from lower: Double = 0) -> Binding<Double> {
    Binding(get: { value.wrappedValue },
            set: { value.wrappedValue = lower + (($0 - lower) / step).rounded() * step })
}
