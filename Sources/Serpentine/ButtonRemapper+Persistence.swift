// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import Combine
import ApplicationServices
import CoreGraphics
import RazerProtocol

// MARK: - Persistence

/// Saving and loading the remap table, per mouse.
extension ButtonRemapper {
    func saveMappings() {
        // No connected device, no persistence: an edit made in a remap window that outlived
        // a disconnect would otherwise be saved under the meaningless "none" key and
        // silently dropped on reconnect.
        guard activeKey != "none" else { return }
        if let data = try? JSONEncoder().encode(mappings) {
            defaults.set(data, forKey: defaultsKey)
        }
    }

    func loadMappings() {
        // Always reset first: a device with no saved table must start empty rather than
        // inherit the previous mouse's mappings — which would both remap the new mouse with
        // the old one's bindings and, on the next edit, save the old table under the new
        // device's key. Also covers disconnect (key "none"): with no mappings the tap
        // passes everything through.
        mappings = [:]
        // Never load under the no-device key. Nothing writes it anymore (see saveMappings),
        // but pre-fix builds persisted disconnected edits there — clear that junk out so it
        // can't remap other pointing devices on every launch/disconnect forever.
        guard activeKey != "none" else {
            defaults.removeObject(forKey: defaultsKey)
            return
        }
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([Int: RemapAction].self, from: data) else { return }
        let kept = withoutUnremappable(decoded)
        mappings = kept
        seenButtons.formUnion(kept.keys)
        if kept != decoded { saveMappings() }
    }

    /// `mappings` minus remaps the active mouse can't take: on a mouse that keeps its remaps,
    /// its HyperShift layer lives in the mouse, so a HyperShift action has to be one the mouse
    /// can do. A button set to HyperShift is a clutch the mouse keeps itself, on the standard
    /// layer only.
    func withoutUnremappable(_ table: [Int: RemapAction]) -> [Int: RemapAction] {
        guard onboardLayout != nil else { return table }
        return table.filter { key, action in
            guard Self.isHyperShiftKey(key) else { return true }
            return action == .passthrough || (action != .hyperShift && OnboardButtons.nativeBlock(for: action) != nil)
        }
    }
}
