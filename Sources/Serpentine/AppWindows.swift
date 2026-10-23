// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// A window the app can put on screen, built lazily. `AppDelegate.present` takes any of them,
/// so every window is brought forward the same way.
@MainActor
protocol AppWindowPresenter: AnyObject {
    /// Puts the window on screen and in front, building it on first use.
    func show()
}
