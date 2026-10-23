// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import Serpentine

@MainActor
final class BackgroundModeTests: XCTestCase {
    private func scratch(_ name: String = #function) -> UserDefaults {
        let suite = "SerpentineTests.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testANewInstallStartsOff() {
        let mode = BackgroundMode(defaults: scratch())
        XCTAssertFalse(mode.isEnabled)
        XCTAssertFalse(mode.hasAsked)
    }

    func testAnUpgradeFromTheMenuBarVersionStaysRunning() {
        // Someone who had the menu bar app relies on it being there.
        let defaults = scratch()
        defaults.set(Data(), forKey: Preferences.lastBatterySnapshot)
        let mode = BackgroundMode(defaults: defaults)
        XCTAssertTrue(mode.isEnabled)
        XCTAssertTrue(mode.hasAsked, "already decided for them, so never asked")
    }

    func testTheChoiceIsKept() {
        let defaults = scratch()
        let mode = BackgroundMode(defaults: defaults)
        mode.isEnabled = true
        // A battery reading appearing later doesn't re-decide it.
        defaults.set(Data(), forKey: Preferences.lastBatterySnapshot)
        XCTAssertTrue(BackgroundMode(defaults: defaults).isEnabled)
        mode.isEnabled = false
        XCTAssertFalse(BackgroundMode(defaults: defaults).isEnabled)
    }
}
