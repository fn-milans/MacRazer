// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// Every key the app stores in `UserDefaults`, in one list. The values themselves are read and
/// written where they're used; this only names them, so what the app keeps is visible in one
/// place and a key can't be spelled two ways. (`LegacyPreferences` and `LegacyInstall` list
/// what older versions kept, which is not read any more.)
enum Preferences {
    // MARK: App-wide

    static let connectionSoundsEnabled = "connectionSoundsEnabled"
    static let appearanceTheme = "appearance.theme"
    static let appearanceGlass = "appearance.glass"
    static let launchAtLoginDefaultApplied = "launchAtLoginDefaultApplied"
    /// The popover sections left open, comma-separated.
    static let popoverExpandedSections = "popoverExpandedSections"
    /// The last battery reading of every mouse, so the menu bar has a value before the first poll.
    static let lastBatterySnapshot = "lastBatterySnapshot.v1"
    /// Which onboard button entries Serpentine wrote, per mouse serial (`OnboardOwnership`).
    static let onboardButtonsOwned = "onboardButtonsOwned"
    static let migratedFromLegacyInstall = "migratedFromLegacyInstall"
    /// Serpentine keeps running, with a menu bar item, once its window closes (`BackgroundMode`).
    static let keepRunningInBackground = "keepRunningInBackground"
    /// Whether to keep running has been asked once, when a driver-mode feature was set up.
    static let backgroundModeAsked = "backgroundModeAsked"
    /// The main window's selected pane (`PaneSection`).
    static let mainWindowSection = "mainWindow.section"

    // MARK: Per mouse

    /// Keys for one mouse, by its device key (serial, or PID when it has none).
    enum Device {
        static let buttonMappingsPrefix = "buttonMappings-"
        static let customDPIPrefix = "customDPI-"
        static let dpiCycleSoftwareActionPrefix = "dpiCycleSoftwareAction-"
        static let learnedDischargeRatePrefix = "learnedDischargeRate-"
        static let profilesPrefix = "profiles-"
        static let activeProfileIDPrefix = "activeProfileID-"
        static let slotNamesPrefix = "slotNames-"

        static func buttonMappings(_ key: String) -> String { buttonMappingsPrefix + key }
        static func customDPI(_ key: String) -> String { customDPIPrefix + key }
        static func dpiCycleSoftwareAction(_ key: String) -> String { dpiCycleSoftwareActionPrefix + key }
        static func learnedDischargeRate(_ key: String) -> String { learnedDischargeRatePrefix + key }
        static func profiles(_ key: String) -> String { profilesPrefix + key }
        static func activeProfileID(_ key: String) -> String { activeProfileIDPrefix + key }
        static func slotNames(_ key: String) -> String { slotNamesPrefix + key }
        /// Where the five DPI stages wait while an onboard slot is in Single mode.
        static func rememberedDpiStages(_ key: String, slot: Int) -> String { "dpiStages-\(key)-slot\(slot)" }

        /// The keys `MouseController.migratePerDeviceData` hole-fills from one device key to
        /// another. Profiles are merged separately.
        static let migratedPrefixes = [
            learnedDischargeRatePrefix, buttonMappingsPrefix, customDPIPrefix, dpiCycleSoftwareActionPrefix,
        ]
    }
}
