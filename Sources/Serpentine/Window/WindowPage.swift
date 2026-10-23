// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import SwiftUI

/// The main window's pages: the mouse's settings, one under the other; its buttons, which need
/// the room of their own; and Serpentine's own settings.
enum WindowPage: String, CaseIterable, Identifiable {
    case mouse, buttons, settings

    var id: Self { self }

    var title: String {
        switch self {
        case .mouse: return "Mouse"
        case .buttons: return "Buttons"
        case .settings: return "Settings"
        }
    }

    /// ⌘1 to ⌘3, in order. (Settings also takes ⌘, from the Serpentine menu.)
    var shortcut: KeyEquivalent { KeyEquivalent(Character(String((Self.allCases.firstIndex(of: self) ?? 0) + 1))) }
}

/// What the main window shows, shared with the menus.
@MainActor
final class WindowNavigation: ObservableObject {
    @Published var page: WindowPage = .mouse {
        didSet { UserDefaults.standard.set(page.rawValue, forKey: Preferences.mainWindowSection) }
    }
    /// The setup sheet (Input Monitoring and Accessibility) is up.
    @Published var showingSetup = false
    /// The battery usage history is up.
    @Published var showingUsage = false

    init() {
        // An earlier build kept one of several sections here; those are all on the mouse page
        // now.
        page = UserDefaults.standard.string(forKey: Preferences.mainWindowSection)
            .flatMap(WindowPage.init(rawValue:)) ?? .mouse
    }
}
