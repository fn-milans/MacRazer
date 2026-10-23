// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import SwiftUI
import RazerProtocol

/// One setting on the dashboard: a coloured symbol and a name, where the setting lives, the
/// current value large, and the controls under it.
struct Tile<Content: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    var residency: SettingResidency? = .mouse
    /// Shown large under the heading; nil when the controls show the value themselves.
    var value: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                TileSymbol(symbol: symbol, tint: tint)
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                if let residency { ResidencyMark(residency: residency) }
            }
            if let value {
                Text(value)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tileBackground()
    }
}

extension View {
    /// A tile's surface: a light fill on the window's glass, a hairline, generous corners.
    func tileBackground() -> some View {
        background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
    }
}

/// A tile's symbol, white on a coloured rounded square, the way System Settings marks its panes.
struct TileSymbol: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 26

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
    }
}

/// Where a tile's setting lives, as a small mark with the reason on hover.
struct ResidencyMark: View {
    let residency: SettingResidency

    var body: some View {
        Image(systemName: residency == .mouse ? "memorychip" : "macwindow")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .help(residency == .mouse
                  ? "Saved in the mouse: it keeps working with Serpentine closed, on any link and any computer."
                  : "Done by Serpentine: it works while Serpentine runs.")
            .accessibilityLabel(residency == .mouse ? "Saved in the mouse" : "Needs Serpentine running")
    }
}
