// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

final class LegacyPreferencesTests: XCTestCase {
    func testRemovesWhatRemovedFeaturesKeptAndNothingElse() {
        let name = "MacRazerTests.\(#function)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("4f1c…", forKey: "usageStats.id")
        defaults.set("granted", forKey: "usageStats.consent")
        defaults.set(Data([1, 2, 3]), forKey: "cachedReleases")
        defaults.set(Date(), forKey: "lastUpdateCheckDate")
        defaults.set(true, forKey: "showPercentInMenuBar")
        LegacyPreferences.remove(from: defaults)
        XCTAssertNil(defaults.object(forKey: "usageStats.id"), "the ID made from the hardware UUID")
        XCTAssertNil(defaults.object(forKey: "usageStats.consent"))
        XCTAssertNil(defaults.object(forKey: "cachedReleases"))
        XCTAssertNil(defaults.object(forKey: "lastUpdateCheckDate"))
        XCTAssertEqual(defaults.object(forKey: "showPercentInMenuBar") as? Bool, true, "a setting still in use stays")
    }
}
