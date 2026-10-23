// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

final class AppLocationTests: XCTestCase {
    func testInstalledAppBundlesAreStable() {
        XCTAssertTrue(AppLocation.isStableInstall("/Applications/MacRazer.app"))
        XCTAssertTrue(AppLocation.isStableInstall("/Users/me/Applications/MacRazer.app"))
        XCTAssertTrue(AppLocation.isStableInstall("/Applications/MacRazer.app/"), "trailing slash")
    }

    func testAppsOnOtherVolumesAreStableByPath() {
        // /Volumes/ used to be rejected outright to catch a mounted DMG, which also caught
        // every external drive and secondary volume people keep applications on — and told
        // them to move MacRazer to an Applications folder it was already in. A mounted image
        // is now separated from a disk by being read-only, which `installedBundleURL` checks
        // against the live filesystem; the path shape alone can't tell them apart.
        XCTAssertTrue(AppLocation.isStableInstall("/Volumes/Media/Applications/MacRazer.app"))
        XCTAssertTrue(AppLocation.isStableInstall("/Volumes/MacRazer/MacRazer.app"))
    }

    func testTranslocatedAndTemporaryCopiesAreNotInstalls() {
        XCTAssertFalse(AppLocation.isStableInstall(
            "/private/var/folders/x1/T/AppTranslocation/AB-CD/d/MacRazer.app"))
        XCTAssertFalse(AppLocation.isStableInstall("/private/var/folders/x1/T/staging/MacRazer.app"))
        XCTAssertFalse(AppLocation.isStableInstall("/tmp/MacRazer.app"))
    }

    func testNonBundlePathsAreNotInstalls() {
        // `swift run`: Bundle.main is the SwiftPM binary's directory, not an .app.
        XCTAssertFalse(AppLocation.isStableInstall("/Users/me/proj/.build/release"))
        XCTAssertFalse(AppLocation.isStableInstall("/Applications/MacRazer.app/Contents/MacOS/MacRazer"))
        XCTAssertFalse(AppLocation.isStableInstall("MacRazer.app"), "relative path")
        XCTAssertFalse(AppLocation.isStableInstall(""))
    }
}
