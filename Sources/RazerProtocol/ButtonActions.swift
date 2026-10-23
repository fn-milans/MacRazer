// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import CoreGraphics
import Foundation

/// What a remapped button does. `.passthrough` lets the original event through; `.keystroke`
/// suppresses the button and posts a key combo instead.
public enum RemapAction: Codable, Equatable, Sendable {
    case passthrough
    case keystroke(keyCode: UInt16, modifiers: UInt64, name: String)
    case mouseButton(button: Int, name: String)
    case doubleClick
    case mediaKey(code: Int, name: String)
    /// Held, it switches every other button to its HyperShift mapping
    /// (`RemapCatalog.hyperShiftKey`), like Synapse's HyperShift. Does nothing by itself.
    case hyperShift
    /// Moves the mouse to its next (or previous) onboard profile slot (`OnboardSlots`).
    /// The mouse does it itself; on mice without slots it is never offered.
    case cycleProfile(up: Bool)
    // The rest are done by the mouse itself and only offered on a mouse that keeps its
    // remaps (`OnboardButtons.nativeBlock`).
    /// A mouse button (0 left ... 4 forward) clicked over and over while held, every
    /// `intervalMs`.
    case turboClick(button: Int, intervalMs: Int, name: String)
    /// A key or combination pressed over and over while held, every `intervalMs`.
    case turboKey(keyCode: UInt16, modifiers: UInt64, name: String, intervalMs: Int)
    /// The mouse runs at `dpi` while held, then goes back (Synapse's Sensitivity Clutch).
    case dpiClutch(dpi: Int)
    /// Cycles the wheel's modes, the wheel-mode button's factory job.
    case cycleScrollMode
    /// A wheel step, once per press or `repeating` while held. Sideways the mouse only
    /// repeats (`OnboardButtons.scrollBlock`).
    case scroll(direction: ScrollDirection, repeating: Bool)
    /// One DPI stage up or down, stopping at the ends.
    case dpiStage(up: Bool)
    /// The button does nothing.
    case disabled

    public var label: String {
        switch self {
        case .passthrough: return "None"
        case .keystroke(_, _, let name), .mouseButton(_, let name), .mediaKey(_, let name): return name
        case .doubleClick: return "Double Click"
        case .hyperShift: return "HyperShift"
        case .cycleProfile(let up): return up ? "Cycle Up Profile" : "Cycle Down Profile"
        case .turboClick(_, let ms, let name): return "Turbo \(name) (\(Self.perSecond(ms))/s)"
        case .turboKey(_, _, let name, let ms): return "Turbo \(name) (\(Self.perSecond(ms))/s)"
        case .dpiClutch(let dpi): return "DPI Clutch \(dpi)"
        case .cycleScrollMode: return "Cycle Scroll Mode"
        case .scroll(let direction, let repeating):
            return (repeating && direction.isVertical ? "Repeat " : "") + direction.label
        case .dpiStage(let up): return up ? "DPI Stage Up" : "DPI Stage Down"
        case .disabled: return "Disabled"
        }
    }

    /// The turbo rates the remap menu offers, as presses per second.
    public static let turboRates = [5, 10, 20]
    /// The DPI values the remap menu offers for the clutch.
    public static let clutchDPIs = [400, 800, 1200, 1600]

    public static func intervalMs(perSecond rate: Int) -> Int { 1000 / rate }
    public static func perSecond(_ intervalMs: Int) -> Int { intervalMs > 0 ? 1000 / intervalMs : 0 }
}

/// Which way a `.scroll` remap scrolls.
public enum ScrollDirection: String, Codable, CaseIterable, Sendable {
    case up, down, left, right

    public var label: String { "Scroll " + rawValue.capitalized }
    public var isVertical: Bool { self == .up || self == .down }
}

/// A curated shortcut a button can be bound to (keeps v1 simple — no key recorder yet).
public struct RemapPreset: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let keyCode: UInt16
    public let flags: CGEventFlags

    public init(id: String, name: String, keyCode: UInt16, flags: CGEventFlags) {
        self.id = id
        self.name = name
        self.keyCode = keyCode
        self.flags = flags
    }

    public var action: RemapAction { .keystroke(keyCode: keyCode, modifiers: flags.rawValue, name: name) }
}

/// The fixed lists the remap menus offer and the onboard table is read back into.
public enum RemapCatalog: Sendable {
    /// The Mac's virtual key codes for the modifier keys, left and right apart, as the key
    /// recorder names a lone modifier.
    public static let modifierKeyNames: [UInt16: String] = [
        59: "Left ⌃", 62: "Right ⌃", 56: "Left ⇧", 60: "Right ⇧",
        58: "Left ⌥", 61: "Right ⌥", 55: "Left ⌘", 54: "Right ⌘",
    ]

    public static let presets: [RemapPreset] = [
        .init(id: "copy", name: "Copy  ⌘C", keyCode: 8, flags: .maskCommand),
        .init(id: "paste", name: "Paste  ⌘V", keyCode: 9, flags: .maskCommand),
        .init(id: "cut", name: "Cut  ⌘X", keyCode: 7, flags: .maskCommand),
        .init(id: "undo", name: "Undo  ⌘Z", keyCode: 6, flags: .maskCommand),
        .init(id: "redo", name: "Redo  ⇧⌘Z", keyCode: 6, flags: [.maskCommand, .maskShift]),
        .init(id: "selectAll", name: "Select All  ⌘A", keyCode: 0, flags: .maskCommand),
        .init(id: "save", name: "Save  ⌘S", keyCode: 1, flags: .maskCommand),
        .init(id: "find", name: "Find  ⌘F", keyCode: 3, flags: .maskCommand),
        .init(id: "newTab", name: "New Tab  ⌘T", keyCode: 17, flags: .maskCommand),
        .init(id: "close", name: "Close  ⌘W", keyCode: 13, flags: .maskCommand),
        .init(id: "back", name: "Back  ⌘[", keyCode: 33, flags: .maskCommand),
        .init(id: "forward", name: "Forward  ⌘]", keyCode: 30, flags: .maskCommand),
        .init(id: "missionControl", name: "Mission Control  ⌃↑", keyCode: 126, flags: .maskControl),
        .init(id: "spaceLeft", name: "Space Left  ⌃←", keyCode: 123, flags: .maskControl),
        .init(id: "spaceRight", name: "Space Right  ⌃→", keyCode: 124, flags: .maskControl),
        .init(id: "screenshot", name: "Screenshot  ⇧⌘4", keyCode: 21, flags: [.maskCommand, .maskShift]),
        .init(id: "switchApp", name: "Switch App  ⌘Tab", keyCode: 48, flags: .maskCommand),
    ]

    /// Media keys (IOKit NX_KEYTYPE codes).
    public static let mediaOptions: [(code: Int, name: String)] = [
        (16, "Play / Pause"), (17, "Next Track"), (18, "Previous Track"),
        (0, "Volume Up"), (1, "Volume Down"), (7, "Mute"),
    ]

    /// HyperShift mappings live in `mappings` too, under the button's id plus this offset, so
    /// they are saved, and captured by profiles, with everything else. Button ids run from
    /// -18 (`HardwareButton`) to a few dozen (CGEvent numbers), far from it either way.
    public static let hyperShiftOffset = 100_000
    public static func hyperShiftKey(_ button: Int) -> Int { button + hyperShiftOffset }
    public static func isHyperShiftKey(_ key: Int) -> Bool { key >= hyperShiftOffset / 2 }
}

/// The modifier byte of a keyboard block in the mouse's function table.
public enum DPIShortcutModifiers: Sendable {
    public static func hidValue(from flags: CGEventFlags) -> UInt8 {
        var value: UInt8 = 0
        if flags.contains(.maskControl) { value |= 0x01 }
        if flags.contains(.maskShift) { value |= 0x02 }
        if flags.contains(.maskAlternate) { value |= 0x04 }
        if flags.contains(.maskCommand) { value |= 0x08 }
        return value
    }
}
