// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import CoreGraphics
import XCTest
@testable import Serpentine

final class SVGPathTests: XCTestCase {
    private func assertBox(_ d: String, _ expected: CGRect, accuracy: CGFloat = 0.01,
                           file: StaticString = #filePath, line: UInt = #line) {
        let box = SVGPath.parse(d).boundingBoxOfPath
        XCTAssertEqual(box.minX, expected.minX, accuracy: accuracy, "minX", file: file, line: line)
        XCTAssertEqual(box.minY, expected.minY, accuracy: accuracy, "minY", file: file, line: line)
        XCTAssertEqual(box.maxX, expected.maxX, accuracy: accuracy, "maxX", file: file, line: line)
        XCTAssertEqual(box.maxY, expected.maxY, accuracy: accuracy, "maxY", file: file, line: line)
    }

    func testLinesAbsoluteAndRelative() {
        assertBox("M1 1 L5 1 V4 H1 Z", CGRect(x: 1, y: 1, width: 4, height: 3))
        assertBox("m1 1 l4 0 v3 h-4 z", CGRect(x: 1, y: 1, width: 4, height: 3))
        // Pairs after a moveto are linetos.
        assertBox("M0 0 10 0 10 10", CGRect(x: 0, y: 0, width: 10, height: 10))
    }

    func testCompactNumbers() {
        // "1.5.5" is two numbers, and a minus sign starts a new one.
        assertBox("M0 0l1.5.5l-.5-2", CGRect(x: 0, y: -1.5, width: 1.5, height: 2))
    }

    func testArcsBulgeTheWayTheirFlagsSay() {
        // Half circles of radius 5 between (0,0) and (10,0): sweep 1 goes through y = -5
        // (y is down in SVG, so that's above), sweep 0 through y = +5.
        assertBox("M0 0A5 5 0 0 1 10 0", CGRect(x: 0, y: -5, width: 10, height: 5), accuracy: 0.05)
        assertBox("M0 0a5 5 0 0 0 10 0", CGRect(x: 0, y: 0, width: 10, height: 5), accuracy: 0.05)
        // A full circle as two arcs, flags written with no spaces.
        assertBox("M0 5a5 5 0 1 1 10 0a5 5 0 1 1-10 0", CGRect(x: 0, y: 0, width: 10, height: 10), accuracy: 0.05)
    }

    func testRadiiTooSmallAreScaledUp() {
        assertBox("M0 0A1 1 0 0 1 10 0", CGRect(x: 0, y: -5, width: 10, height: 5), accuracy: 0.05)
    }

    func testTheSerpentFitsItsGrid() {
        let box = SVGPath.parse(MenuBarIcon.serpentPathData).boundingBoxOfPath
        let grid = CGRect(x: 0, y: 0, width: MenuBarIcon.serpentGrid, height: MenuBarIcon.serpentGrid)
        XCTAssertTrue(grid.contains(box), "\(box)")
        XCTAssertGreaterThan(box.width, MenuBarIcon.serpentGrid * 0.7, "parsed all of it, not just the start")
    }
}
