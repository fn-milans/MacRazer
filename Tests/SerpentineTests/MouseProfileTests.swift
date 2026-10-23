// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import Serpentine

final class MouseProfileTests: XCTestCase {
    func testProfileDecodesWithoutDPIStagesField() {
        // Profiles saved before dpiStages existed must keep decoding (and apply without
        // touching the stage table).
        let legacy = """
        [{"id":"6F1C7C5C-0000-0000-0000-000000000000","name":"Old","dpi":1600,"pollRate":1000,
        "brightness":80,"effect":"Static","color":{"r":1,"g":2,"b":3},"buttonMappings":{}}]
        """
        let decoded = try? JSONDecoder().decode([MouseProfile].self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded?.count, 1)
        XCTAssertNil(decoded?[0].dpiStages)
    }
}
