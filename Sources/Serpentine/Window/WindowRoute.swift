// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import SwiftUI

/// Where the main window can go from its dashboard: the detail views behind a tile, opened in
/// place with a back button, the way System Settings drills in.
enum WindowRoute: String, CaseIterable, Hashable, Identifiable {
    case battery

    var id: Self { self }

    var title: String {
        switch self {
        case .battery: return "Battery History"
        }
    }
}

/// What the main window shows, shared with the menus.
@MainActor
final class WindowNavigation: ObservableObject {
    /// Empty is the dashboard.
    @Published var path: [WindowRoute] = []
    /// Serpentine's own settings, from the cog.
    @Published var showingSettings = false
    /// The setup sheet (Input Monitoring and Accessibility) is up.
    @Published var showingSetup = false

    /// Opens a detail view from the dashboard, or the dashboard itself with nil.
    func go(to route: WindowRoute?) {
        path = route.map { [$0] } ?? []
    }
}
