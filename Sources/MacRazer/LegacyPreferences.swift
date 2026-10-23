// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// What earlier versions kept for features this fork removed: the usage stats (including the
/// ID derived from the Mac's hardware UUID), the updater's cached releases and its dates, the
/// crash report and device test windows. Nothing reads these any more, so without this they
/// would sit in the preferences of every install that ran one of those versions.
enum LegacyPreferences {
    static let keys = [
        // Usage stats.
        "usageStats.consent", "usageStats.id", "usageStats.lastReportedVersion",
        "usageStats.lastSentAt", "usageStats.pendingDeletion", "usageStats.reportedMice",
        // The updater and its "What's new" notes.
        "autoInstallUpdates", "cachedReleases", "dismissedUpdateAnnouncement",
        "dismissedUpdateVersion", "lastFoundUpdateNotes", "lastFoundUpdateVersion",
        "lastRunVersion", "lastUpdateCheckDate", "notesCheckedForVersion",
        "pendingUpdateAnnouncement", "updatedFromVersion",
        // The crash report and device test windows.
        "crashReportsHandledThrough", "offerCrashReports", "deviceTest.resumeAfterRelaunch",
    ]

    /// Removes them; cheap enough to run on every launch, so an install that skips a version
    /// is cleaned up all the same.
    static func remove(from defaults: UserDefaults = .standard) {
        for key in keys { defaults.removeObject(forKey: key) }
    }
}
