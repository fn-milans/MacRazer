// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation
import RazerProtocol

/// Which blocks Serpentine wrote into which mouse's function table, by serial number, so only
/// those are ever put back (`OnboardButtons.step`).
struct OnboardOwnership {
    static let defaultsKey = Preferences.onboardButtonsOwned
    let defaults: UserDefaults

    /// The record of a mouse's HyperShift layer (`OnboardButtons.shiftedPlan`).
    static func shiftedKey(serial: String) -> String { serial + "#hypershift" }

    func owned(serial: String) -> [UInt8: Set<[UInt8]>] {
        guard let all = defaults.dictionary(forKey: Self.defaultsKey),
              let mouse = all[serial] as? [String: [Data]] else { return [:] }
        var out: [UInt8: Set<[UInt8]>] = [:]
        for (id, blocks) in mouse {
            guard let id = UInt8(id, radix: 16) else { continue }
            out[id] = Set(blocks.map { Array($0) })
        }
        return out
    }

    func set(_ owned: [UInt8: Set<[UInt8]>], serial: String) {
        var all = defaults.dictionary(forKey: Self.defaultsKey) ?? [:]
        let mouse = owned.filter { !$0.value.isEmpty }
        if mouse.isEmpty {
            all.removeValue(forKey: serial)
        } else {
            all[serial] = Dictionary(uniqueKeysWithValues: mouse.map { id, blocks in
                (String(format: "%02X", id), blocks.sorted { $0.lexicographicallyPrecedes($1) }.map { Data($0) })
            })
        }
        defaults.set(all, forKey: Self.defaultsKey)
    }
}
