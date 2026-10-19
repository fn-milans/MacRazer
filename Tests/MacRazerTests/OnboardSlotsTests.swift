// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

final class OnboardSlotsTests: XCTestCase {
    func testSettingsCommandsFollowTheSlot() {
        XCTAssertEqual(OnboardSlots.retarget(RazerCommands.getDPI(), to: 3).arguments[0], 3)
        XCTAssertEqual(OnboardSlots.retarget(RazerCommands.setButtonFunction(0x01, block: [1, 1, 1]), to: 2).arguments[0], 2)
        XCTAssertEqual(OnboardSlots.retarget(RazerCommands.getDPI(), to: 1).arguments[0], 1)
    }

    func testOtherCommandsAreLeftAlone() {
        // Battery level and the slot commands themselves carry no slot.
        XCTAssertEqual(OnboardSlots.retarget(RazerCommands.getBatteryLevel(), to: 4).arguments[0], 0)
        XCTAssertEqual(OnboardSlots.retarget(OnboardSlots.activate(1), to: 4).arguments[0], 1)
    }

    func testParsesTheSlotList() {
        var r = OnboardSlots.listSlots()
        r.dataSize = 3
        r.arguments[0] = 5; r.arguments[1] = 1; r.arguments[2] = 2
        XCTAssertEqual(OnboardSlots.parseSlots(r), [1, 2])
        r.arguments[1] = 0; r.arguments[2] = 0
        XCTAssertNil(OnboardSlots.parseSlots(r))
    }

    func testPicksASlot() {
        let a = UUID(), b = UUID(), c = UUID()
        // The first profile takes the slot the mouse is on.
        XCTAssertEqual(OnboardSlots.slot(for: a, assigned: [:], active: 1), 1)
        // Its own slot always wins.
        XCTAssertEqual(OnboardSlots.slot(for: a, assigned: [a: 3], active: 1), 3)
        // Otherwise the lowest free one.
        XCTAssertEqual(OnboardSlots.slot(for: c, assigned: [a: 1, b: 3], active: 1), 2)
        let full = Dictionary(uniqueKeysWithValues: (1...5).map { (UUID(), $0) })
        XCTAssertNil(OnboardSlots.slot(for: c, assigned: full, active: 1))
    }

    func testCycleProfileBlocks() {
        XCTAssertEqual(OnboardButtons.nativeBlock(for: .cycleProfile(up: true)), [0x07, 0x01, 0x04, 0, 0, 0, 0])
        XCTAssertEqual(OnboardButtons.nativeBlock(for: .cycleProfile(up: false)), [0x07, 0x01, 0x05, 0, 0, 0, 0])
    }
}
