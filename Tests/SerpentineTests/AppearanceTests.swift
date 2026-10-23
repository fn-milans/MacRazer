// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
import AppKit
@testable import Serpentine

final class AppearanceTests: XCTestCase {
    /// Every theme × glass × system mode, against the table the mockups were approved from.
    func testEveryCombinationResolvesToTheApprovedLook() {
        let expected: [(AppearanceTheme, Bool, Bool, AppearanceLook)] = [
            (.system, true, false, .lightGlass),
            (.system, true, true, .darkGlass),
            (.system, false, false, .solidLight),
            (.system, false, true, .solidDark),
            (.dark, true, false, .darkGlass),
            (.dark, true, true, .darkGlass),
            (.dark, false, false, .solidDark),
            (.dark, false, true, .solidDark),
            (.light, true, false, .lightGlass),
            (.light, true, true, .lightGlass),
            (.light, false, false, .solidLight),
            (.light, false, true, .solidLight),
            // Razer Green stays dark on a light Mac.
            (.razerGreen, true, false, .greenGlass),
            (.razerGreen, true, true, .greenGlass),
            (.razerGreen, false, false, .solidGreen),
            (.razerGreen, false, true, .solidGreen),
        ]
        XCTAssertEqual(expected.count, AppearanceTheme.allCases.count * 2 * 2)
        for (theme, glass, systemIsDark, look) in expected {
            XCTAssertEqual(AppearanceLook.resolve(theme: theme, glass: glass, systemIsDark: systemIsDark), look,
                           "\(theme), glass \(glass), system dark \(systemIsDark)")
        }
    }

    func testLookProperties() {
        for look in AppearanceLook.allCases {
            XCTAssertEqual(look.appearanceName, look.isDark ? .darkAqua : .aqua)
            // Plain glass keeps the native material; everything else paints over it.
            let plainGlass = look == .lightGlass || look == .darkGlass
            XCTAssertEqual(look.backdropColor == nil, plainGlass, "\(look)")
            // A solid look must actually be solid, or the material shows through.
            if !look.isGlass { XCTAssertEqual(look.backdropColor?.alphaComponent, 1, "\(look)") }
        }
        XCTAssertFalse(AppearanceLook.lightGlass.isDark)
        XCTAssertFalse(AppearanceLook.solidLight.isDark)
        XCTAssertTrue(AppearanceLook.solidGreen.isDark)
    }

    @MainActor
    func testSettingsDefaultAndPersist() throws {
        let suite = "AppearanceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppearanceSettings(defaults: defaults)
        XCTAssertEqual(settings.theme, .system)
        XCTAssertTrue(settings.glass)

        settings.theme = .razerGreen
        settings.glass = false
        let reloaded = AppearanceSettings(defaults: defaults)
        XCTAssertEqual(reloaded.theme, .razerGreen)
        XCTAssertFalse(reloaded.glass)
        XCTAssertEqual(reloaded.look(systemIsDark: false), .solidGreen)
    }

    @MainActor
    func testUnknownStoredThemeFallsBackToSystem() throws {
        let suite = "AppearanceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("neon", forKey: AppearanceSettings.themeKey)
        XCTAssertEqual(AppearanceSettings(defaults: defaults).theme, .system)
    }

    @MainActor
    func testTrackedWindowsGetTheFullLook() throws {
        let suite = "AppearanceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppearanceSettings(defaults: defaults)
        settings.applyToWindows(.solidLight)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = NSView()
        // A window opened later takes the look the others already have.
        settings.track(window)
        XCTAssertEqual(window.appearance?.name, .aqua)
        XCTAssertTrue(window.isOpaque)
        XCTAssertEqual(window.backgroundColor, AppearanceLook.solidLight.backdropColor)

        settings.applyToWindows(.greenGlass)
        XCTAssertEqual(window.appearance?.name, .darkAqua)
        XCTAssertFalse(window.isOpaque)
        XCTAssertEqual(window.backgroundColor, .clear)
        let frameView = try XCTUnwrap(window.contentView?.superview)
        let glass = try XCTUnwrap(frameView.subviews.compactMap { $0 as? NSVisualEffectView }.first)
        XCTAssertFalse(glass.isHidden)
        let tint = try XCTUnwrap(frameView.subviews.compactMap { $0 as? BackdropTintView }.first)
        XCTAssertEqual(tint.fill, AppearanceLook.greenGlass.backdropColor)

        // Applying again reuses the same views rather than stacking new ones.
        settings.applyToWindows(.solidDark)
        XCTAssertEqual(frameView.subviews.compactMap { $0 as? NSVisualEffectView }.count, 1)
        XCTAssertTrue(glass.isHidden)
        XCTAssertNil(tint.fill)
        XCTAssertEqual(window.backgroundColor, AppearanceLook.solidDark.backdropColor)
    }
}
