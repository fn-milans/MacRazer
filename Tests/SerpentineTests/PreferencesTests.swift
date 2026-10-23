// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import Serpentine

/// The keys are what's on disk in every install. Renaming one in `Preferences` would quietly
/// drop that setting for everyone, so their spelling is pinned here.
final class PreferencesTests: XCTestCase {
    func testStoredSpellingsDontChange() {
        XCTAssertEqual(Preferences.showPercentInMenuBar, "showPercentInMenuBar")
        XCTAssertEqual(Preferences.connectionSoundsEnabled, "connectionSoundsEnabled")
        XCTAssertEqual(Preferences.appearanceTheme, "appearance.theme")
        XCTAssertEqual(Preferences.appearanceGlass, "appearance.glass")
        XCTAssertEqual(Preferences.launchAtLoginDefaultApplied, "launchAtLoginDefaultApplied")
        XCTAssertEqual(Preferences.popoverExpandedSections, "popoverExpandedSections")
        XCTAssertEqual(Preferences.lastBatterySnapshot, "lastBatterySnapshot.v1")
        XCTAssertEqual(Preferences.onboardButtonsOwned, "onboardButtonsOwned")
        XCTAssertEqual(Preferences.Device.buttonMappings("K"), "buttonMappings-K")
        XCTAssertEqual(Preferences.Device.customDPI("K"), "customDPI-K")
        XCTAssertEqual(Preferences.Device.dpiCycleSoftwareAction("K"), "dpiCycleSoftwareAction-K")
        XCTAssertEqual(Preferences.Device.learnedDischargeRate("K"), "learnedDischargeRate-K")
        XCTAssertEqual(Preferences.Device.profiles("K"), "profiles-K")
        XCTAssertEqual(Preferences.Device.activeProfileID("K"), "activeProfileID-K")
        XCTAssertEqual(Preferences.Device.slotNames("K"), "slotNames-K")
        XCTAssertEqual(Preferences.Device.rememberedDpiStages("K", slot: 2), "dpiStages-K-slot2")
    }
}
