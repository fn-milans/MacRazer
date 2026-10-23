// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// What the app knows about itself. One place, because four files had grown their own read of
/// `CFBundleShortVersionString` and they didn't agree on the fallback — which mattered, since
/// one of those disagreements is deliberate (see below) and the rest were accidents.
enum AppInfo {
    /// The bundle's marketing version, or nil under `swift run`, which has no bundle.
    static var version: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    static var build: String? {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String
    }

    /// For showing a human. "dev" reads as what it is.
    static var displayVersion: String { version ?? "dev" }

    static var displayBuild: String { build ?? "—" }
}

/// Every URL that identifies this project, in one place so a rename can't leave one behind.
/// Serpentine reaches none of them on its own: each opens in the browser when it is clicked.
enum ProjectLinks {
    static let repo = URL(string: "https://github.com/fn-milans/Serpentine")!
    static let issues = repo.appendingPathComponent("issues")
    static let releases = repo.appendingPathComponent("releases")

    /// The project this one was forked from, credited in the About window.
    static let original = URL(string: "https://github.com/SorcRR/MacRazer")!

    // Upstream, credited in the About window and NOTICE.md.
    static let openRazer = URL(string: "https://github.com/openrazer/openrazer")!
    static let cobraHyperSpeedPR = URL(string: "https://github.com/openrazer/openrazer/pull/2583")!
}
