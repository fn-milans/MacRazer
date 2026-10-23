// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import SwiftUI
import XCTest
@testable import Serpentine

/// Renders every preview scene (`PreviewScene`), so a view that stops building or lays out
/// to nothing fails here rather than in someone's menu bar. With `SERPENTINE_SNAPSHOTS` set
/// to a folder, the renders are written there as PNGs to look at:
///
///     SERPENTINE_SNAPSHOTS=/tmp/snaps swift test --filter SnapshotTests
@MainActor
final class SnapshotTests: XCTestCase {
    func testEveryPreviewSceneRenders() throws {
        _ = NSApplication.shared
        let folder = ProcessInfo.processInfo.environment["SERPENTINE_SNAPSHOTS"].map(URL.init(fileURLWithPath:))
        if let folder { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }

        for scene in PreviewScene.allCases {
            let renderer = ImageRenderer(content: scene.makeView()
                .environment(\.colorScheme, .dark)
                .background(Color(white: 0.13)))
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage, "\(scene) didn't render")
            XCTAssertGreaterThan(image.size.width, 100, "\(scene)")
            XCTAssertGreaterThan(image.size.height, 100, "\(scene)")
            if let folder, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try png.write(to: folder.appendingPathComponent("\(scene.rawValue).png"))
            }
        }
    }
}
