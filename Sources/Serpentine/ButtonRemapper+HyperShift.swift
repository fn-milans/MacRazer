// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import Combine
import ApplicationServices
import CoreGraphics
import RazerProtocol

// MARK: - HyperShift

/// The HyperShift layer: a held button that switches every other button to its second mapping.
extension ButtonRemapper {
    static var hyperShiftOffset: Int { RemapCatalog.hyperShiftOffset }

    static func hyperShiftKey(_ button: Int) -> Int { RemapCatalog.hyperShiftKey(button) }

    static func isHyperShiftKey(_ key: Int) -> Bool { RemapCatalog.isHyperShiftKey(key) }

    /// Whether any button is the HyperShift key, so the remap window offers the second layer.
    /// A mouse with an onboard HyperShift layer (`OnboardButtons.shiftedPlan`) always has
    /// one: its side trigger.
    var hasHyperShiftKey: Bool { mappingsLiveInMouse || mappings.values.contains(.hyperShift) }

    /// What a button does right now: its HyperShift mapping while HyperShift is held (when
    /// it has one), otherwise its normal one. Nil means its own default behaviour.
    func activeAction(for button: Int) -> RemapAction? {
        if hyperShiftHeld, mappings[button] != .hyperShift,
           let shifted = mappings[Self.hyperShiftKey(button)], shifted != .passthrough {
            return shifted
        }
        guard let action = mappings[button], action != .passthrough else { return nil }
        return action
    }

    /// What a mapping slot does: its remap, or what the button does without one
    /// (`defaultLabel`).
    func actionLabel(for button: Int) -> String {
        guard let action = mappings[button], action != .passthrough else { return defaultLabel(for: button) }
        return action.label
    }

    /// What a slot does with no remap. A mouse that keeps its remaps runs the control's
    /// factory function on both layers (`OnboardButtons.shiftedPlan`); with the event tap, a
    /// HyperShift slot falls back to the button's standard mapping.
    func defaultLabel(for button: Int) -> String {
        if Self.isHyperShiftKey(button) {
            let standard = button - Self.hyperShiftOffset
            return mappingsLiveInMouse ? defaultLabel(for: standard) : actionLabel(for: standard)
        }
        if let control = onboardLayout?.first(where: { $0.button == button }) { return OnboardButtons.factoryLabel(control) }
        switch button {
        case -1: return "DPI Cycle"
        case 2: return "Middle Click"
        case 3: return "Back"
        case 4: return "Forward"
        default: return "Default"
        }
    }

    /// Whether a slot does something other than its default: a remap that isn't what the
    /// control does from the factory anyway (Left Index set to Cycle Up Profile isn't).
    func isRemapped(_ button: Int) -> Bool {
        guard let action = mappings[button], action != .passthrough else { return false }
        let control = Self.isHyperShiftKey(button) ? button - Self.hyperShiftOffset : button
        if let factory = onboardLayout?.first(where: { $0.button == control })?.factory,
           OnboardButtons.nativeBlock(for: action) == factory { return false }
        return true
    }

    /// Whether the active mouse has a known function table (`OnboardButtons.layout`).
    var hasHardwareButtonLayout: Bool { onboardLayout != nil }

    /// `label(for:)`, with the active mouse's own names for its side buttons where they're known.
    func displayLabel(for button: Int) -> String {
        if Self.isHyperShiftKey(button) { return "HyperShift + " + displayLabel(for: button - Self.hyperShiftOffset) }
        if hasHardwareButtonLayout {
            switch button {
            case 1: return "Right Click"
            case 2: return "Scroll Click"
            case 3: return "Side Back"
            case 4: return "Side Middle"
            default: break
            }
        }
        return Self.label(for: button)
    }

    /// Friendly, compact label for a raw CGEvent button number.
    static func label(for button: Int) -> String {
        if let hardware = HardwareButton(rawValue: button) { return hardware.label }
        switch button {
        case -1: return "DPI Cycle"
        case 2: return "Wheel Click"
        case 3: return "Back (4)"
        case 4: return "Forward (5)"
        default: return "Button \(button + 1)"
        }
    }

    /// Mock state for the `render-remap` preview command; `pid` previews that mouse's own list.
    func loadPreviewState(pid: Int? = nil) {
        accessibilityGranted = true
        eventTapAvailable = true
        if let pid {
            activeKey = "preview"
            activeDeviceID = pid
        }
        seenButtons = pid == nil ? [2, 3, 4, 5] : []
        mappings = [3: .keystroke(keyCode: 8, modifiers: CGEventFlags.maskCommand.rawValue, name: "Copy  ⌘C")]
    }
}
