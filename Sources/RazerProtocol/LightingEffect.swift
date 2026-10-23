// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// The lighting effects the UI picker and saved profiles share. Raw values are what profiles
/// persist AND what the picker displays — renaming a case would orphan every saved profile's
/// effect (it decodes as a plain string and falls back to `.off`), so treat them as frozen.
public enum LightingEffect: String, CaseIterable, Identifiable, Sendable {
    case staticColor = "Static"
    case breathing = "Breathing"
    case spectrum = "Spectrum"
    case reactive = "Reactive"
    case wave = "Wave"
    case off = "Off"
    public var id: Self { self }

    /// The effects with a colour of their own.
    public var usesColor: Bool { [.staticColor, .breathing, .reactive].contains(self) }

    /// What mice without lighting zones offer (`ZonedLighting.effects` for the others).
    public static let classic: [LightingEffect] = [.staticColor, .spectrum, .wave, .off]
}
