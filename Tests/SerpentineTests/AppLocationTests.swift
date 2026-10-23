// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import Serpentine

final class AppLocationTests: XCTestCase {
    func testInstalledAppBundlesAreStable() {
        XCTAssertTrue(AppLocation.isStableInstall("/Applications/Serpentine.app"))
        XCTAssertTrue(AppLocation.isStableInstall("/Users/me/Applications/Serpentine.app"))
        XCTAssertTrue(AppLocation.isStableInstall("/Applications/Serpentine.app/"), "trailing slash")
    }

    func testAppsOnOtherVolumesAreStableByPath() {
        // /Volumes/ used to be rejected outright to catch a mounted DMG, which also caught
        // every external drive and secondary volume people keep applications on — and told
        // them to move Serpentine to an Applications folder it was already in. A mounted image
        // is now separated from a disk by being read-only, which `installedBundleURL` checks
        // against the live filesystem; the path shape alone can't tell them apart.
        XCTAssertTrue(AppLocation.isStableInstall("/Volumes/Media/Applications/Serpentine.app"))
        XCTAssertTrue(AppLocation.isStableInstall("/Volumes/Serpentine/Serpentine.app"))
    }

    func testTranslocatedAndTemporaryCopiesAreNotInstalls() {
        XCTAssertFalse(AppLocation.isStableInstall(
            "/private/var/folders/x1/T/AppTranslocation/AB-CD/d/Serpentine.app"))
        XCTAssertFalse(AppLocation.isStableInstall("/private/var/folders/x1/T/staging/Serpentine.app"))
        XCTAssertFalse(AppLocation.isStableInstall("/tmp/Serpentine.app"))
    }

    func testNonBundlePathsAreNotInstalls() {
        // `swift run`: Bundle.main is the SwiftPM binary's directory, not an .app.
        XCTAssertFalse(AppLocation.isStableInstall("/Users/me/proj/.build/release"))
        XCTAssertFalse(AppLocation.isStableInstall("/Applications/Serpentine.app/Contents/MacOS/Serpentine"))
        XCTAssertFalse(AppLocation.isStableInstall("Serpentine.app"), "relative path")
        XCTAssertFalse(AppLocation.isStableInstall(""))
    }
}
