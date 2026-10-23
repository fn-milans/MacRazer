// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// What the app keeps for one mouse that the mouse doesn't keep itself, by its device key
/// (serial, or PID when it reports none). Views read and write these through here rather than
/// `UserDefaults`. Profiles and slot names have their own stores (`ProfileStore`,
/// `SlotNames`), as do remaps (`ButtonRemapper`) and the battery history.
struct DeviceSettings {
    let deviceKey: String
    var defaults: UserDefaults = .standard

    /// The recallable custom DPI.
    var customDPI: Int? {
        get { defaults.object(forKey: Preferences.Device.customDPI(deviceKey)) as? Int }
        nonmutating set { defaults.set(newValue, forKey: Preferences.Device.customDPI(deviceKey)) }
    }

    /// The five stages an onboard slot had, kept while the slot is in Single mode, which
    /// holds only one.
    func rememberedDpiStages(slot: Int) -> [Int]? {
        defaults.array(forKey: Preferences.Device.rememberedDpiStages(deviceKey, slot: slot)) as? [Int]
    }

    func rememberDpiStages(_ stages: [Int], slot: Int) {
        defaults.set(stages, forKey: Preferences.Device.rememberedDpiStages(deviceKey, slot: slot))
    }
}
