// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation
import RazerProtocol

/// Whether Serpentine keeps running, with a small menu bar item, once its window is closed.
///
/// Off by default: Serpentine writes what it can into the mouse, so most people set the mouse
/// up and quit. What only the app can do ("driver mode": remaps the mouse can't store, the
/// DPI Cycle bridge, low-battery alerts, battery history) needs it on. Setting one of those up
/// asks once (`AppDelegate`), listing what needs it; it never turns itself on.
@MainActor
final class BackgroundMode: ObservableObject {
    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Preferences.keepRunningInBackground) }
    }

    /// The question has been asked once; it isn't asked again.
    var hasAsked: Bool {
        get { defaults.bool(forKey: Preferences.backgroundModeAsked) }
        set { defaults.set(newValue, forKey: Preferences.backgroundModeAsked) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: Preferences.keepRunningInBackground) == nil {
            // First launch of the windowed app. Someone coming from the menu bar version had
            // Serpentine running all the time and may rely on that (the menu bar item, the
            // low-battery alert), so it stays on for them; a new install starts off.
            let upgrading = Self.ranMenuBarVersion(defaults)
            defaults.set(upgrading, forKey: Preferences.keepRunningInBackground)
            if upgrading { defaults.set(true, forKey: Preferences.backgroundModeAsked) }
        }
        isEnabled = defaults.bool(forKey: Preferences.keepRunningInBackground)
    }

    /// Evidence an earlier, menu bar only, version ran here: a battery reading, or the
    /// login-item default it applied on its first launch.
    static func ranMenuBarVersion(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: Preferences.lastBatterySnapshot) != nil
            || defaults.bool(forKey: Preferences.launchAtLoginDefaultApplied)
    }
}

/// What the user has set up that only works while Serpentine runs.
enum DriverModeUsage {
    /// One line per thing, for the background-mode question and the window's note.
    @MainActor
    static func features(controller: MouseController, remapper: ButtonRemapper) -> [String] {
        var out: [String] = []
        let caps = controller.capabilities
        let appRemaps = remapper.mappings.filter { $0.value != .passthrough }
            .filter { $0.value.residency(onButton: $0.key, of: caps) == .app }
        if !appRemaps.isEmpty {
            out.append(appRemaps.count == 1 ? "1 button remap" : "\(appRemaps.count) button remaps")
        }
        if remapper.dpiCycleSoftwareAction != nil { out.append(Setting.dpiCycleBridge.title) }
        return out
    }
}
