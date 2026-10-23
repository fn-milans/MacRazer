// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// What earlier versions kept for features this fork removed: the usage stats (including the
/// ID derived from the Mac's hardware UUID), the updater's cached releases and its dates, the
/// crash report and device test windows, the menu bar percentage. Nothing reads these any more, so without this they
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
        // The menu bar popover: the percentage beside its item, the sections left open.
        "showPercentInMenuBar", "popoverExpandedSections",
        // The window's tabs, before it became a dashboard.
        "mainWindow.section",
    ]

    /// Removes them; cheap enough to run on every launch, so an install that skips a version
    /// is cleaned up all the same.
    static func remove(from defaults: UserDefaults = .standard) {
        for key in keys { defaults.removeObject(forKey: key) }
    }
}

/// What an install from before the rename left behind. The app used to be MacRazer, with the
/// bundle id `com.macrazer.menubar` and its data in `Application Support/MacRazer`; a new
/// bundle id starts with empty preferences, so without this every setting, remap and battery
/// history would be lost on the first launch of Serpentine. Runs before anything reads either.
///
/// Copies, never deletes: the old preferences stay where they were, so going back to an old
/// build still finds them. The macOS permissions can't be carried over: they belong to the
/// bundle id, so Input Monitoring and Accessibility are asked for again.
enum LegacyInstall {
    static let bundleID = "com.macrazer.menubar"
    static let directoryName = "MacRazer"
    static let migratedKey = Preferences.migratedFromLegacyInstall
    /// The login item belonged to the old bundle id and went with it, so Serpentine's
    /// first-run default has to apply again rather than be recorded as done.
    static let notImported: Set<String> = [Preferences.launchAtLoginDefaultApplied]

    static func migrate(defaults: UserDefaults = .standard,
                        applicationSupport: URL = FileManager.default
                            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]) {
        guard !defaults.bool(forKey: migratedKey) else { return }
        importPreferences(into: defaults)
        moveDirectory(in: applicationSupport)
        defaults.set(true, forKey: migratedKey)
    }

    /// Only keys Serpentine doesn't have yet, so a setting changed since is never overwritten.
    static func importPreferences(into defaults: UserDefaults,
                                  from legacy: [String: Any]? = nil) {
        guard let old = legacy ?? defaults.persistentDomain(forName: bundleID) else { return }
        for (key, value) in old where defaults.object(forKey: key) == nil && !notImported.contains(key) {
            defaults.set(value, forKey: key)
        }
    }

    /// Moved rather than copied: the files are large and only one app should write them.
    /// Left alone when Serpentine already has its own directory.
    static func moveDirectory(in applicationSupport: URL) {
        let fm = FileManager.default
        let old = applicationSupport.appendingPathComponent(directoryName, isDirectory: true)
        let new = applicationSupport.appendingPathComponent(StoreDirectory.name, isDirectory: true)
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return }
        try? fm.moveItem(at: old, to: new)
    }
}
