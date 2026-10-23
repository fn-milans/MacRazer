// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import Serpentine

final class LegacyPreferencesTests: XCTestCase {
    func testRemovesWhatRemovedFeaturesKeptAndNothingElse() {
        let name = "SerpentineTests.\(#function)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("4f1c…", forKey: "usageStats.id")
        defaults.set("granted", forKey: "usageStats.consent")
        defaults.set(Data([1, 2, 3]), forKey: "cachedReleases")
        defaults.set(Date(), forKey: "lastUpdateCheckDate")
        defaults.set(true, forKey: "connectionSoundsEnabled")
        LegacyPreferences.remove(from: defaults)
        XCTAssertNil(defaults.object(forKey: "usageStats.id"), "the ID made from the hardware UUID")
        XCTAssertNil(defaults.object(forKey: "usageStats.consent"))
        XCTAssertNil(defaults.object(forKey: "cachedReleases"))
        XCTAssertNil(defaults.object(forKey: "lastUpdateCheckDate"))
        XCTAssertEqual(defaults.object(forKey: "connectionSoundsEnabled") as? Bool, true, "a setting still in use stays")
    }

    func testImportsTheOldPreferencesWithoutOverwritingNewOnes() {
        let name = "SerpentineTests.\(#function)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "connectionSoundsEnabled")
        LegacyInstall.importPreferences(into: defaults, from: [
            "connectionSoundsEnabled": true,
            "lowBatteryThreshold": 15,
        ])
        XCTAssertEqual(defaults.object(forKey: "connectionSoundsEnabled") as? Bool, false, "set since the rename")
        XCTAssertEqual(defaults.integer(forKey: "lowBatteryThreshold"), 15)
    }

    func testMovesTheOldDataDirectoryOnlyWhenThereIsNoNewOne() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("SerpentineTests-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let old = root.appendingPathComponent(LegacyInstall.directoryName)
        let new = root.appendingPathComponent(StoreDirectory.name)
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: old.appendingPathComponent("battery-history.json"))

        LegacyInstall.moveDirectory(in: root)
        XCTAssertTrue(fm.fileExists(atPath: new.appendingPathComponent("battery-history.json").path))
        XCTAssertFalse(fm.fileExists(atPath: old.path))

        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        LegacyInstall.moveDirectory(in: root)
        XCTAssertTrue(fm.fileExists(atPath: old.path), "Serpentine's own data wins")
    }

    func testMigratesOnce() {
        let name = "SerpentineTests.\(#function)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        LegacyInstall.migrate(defaults: defaults, applicationSupport: root)
        XCTAssertTrue(defaults.bool(forKey: LegacyInstall.migratedKey))
    }
}
