// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import IOKit.hid
import XCTest
@testable import MacRazer

final class ButtonProbeTests: XCTestCase {
    func testDeviceModeCommandsMatchOpenRazer() {
        let get = RazerCommands.getDeviceMode()
        XCTAssertEqual([get.commandClass, get.commandId, get.dataSize], [0x00, 0x84, 0x02])
        let set = RazerCommands.setDeviceMode(RazerCommands.deviceModeDriver)
        XCTAssertEqual([set.commandClass, set.commandId, set.dataSize], [0x00, 0x04, 0x02])
        XCTAssertEqual(Array(set.arguments.prefix(2)), [0x03, 0x00])
    }

    func testFactoryModeIsNeverSent() {
        // OpenRazer blocks mode 0x02 (a factory test mode); so does the builder.
        XCTAssertEqual(RazerCommands.setDeviceMode(0x02).arguments[0], 0x00)
    }

    func testScrollReadsMatchOpenRazer() {
        for (report, id) in [(RazerCommands.getScrollMode(), UInt8(0x94)),
                             (RazerCommands.getScrollAcceleration(), 0x96),
                             (RazerCommands.getScrollSmartReel(), 0x97)] {
            XCTAssertEqual([report.commandClass, report.commandId, report.dataSize], [0x02, id, 0x02])
            XCTAssertEqual(report.arguments[0], Razer.varstore)
        }
        let poll2 = RazerCommands.getPollingRate2()
        XCTAssertEqual([poll2.commandClass, poll2.commandId, poll2.dataSize], [0x00, 0xC0, 0x01])
    }

    func testPointerMovementIsNeverLogged() {
        XCTAssertNil(ButtonProbe.describe(page: kHIDPage_GenericDesktop, usage: kHIDUsage_GD_X, value: 5, previous: 0))
        XCTAssertNil(ButtonProbe.describe(page: kHIDPage_GenericDesktop, usage: kHIDUsage_GD_Y, value: -3, previous: nil))
    }

    func testWheelLogsOnlyWhenItMoves() {
        XCTAssertNil(ButtonProbe.describe(page: kHIDPage_GenericDesktop, usage: kHIDUsage_GD_Wheel, value: 0, previous: 1))
        XCTAssertEqual(ButtonProbe.describe(page: kHIDPage_GenericDesktop, usage: kHIDUsage_GD_Wheel, value: -1, previous: -1),
                       "wheel -1")
    }

    func testButtonsLogOnChangeOnly() {
        XCTAssertEqual(ButtonProbe.describe(page: kHIDPage_Button, usage: 4, value: 1, previous: 0), "mouse button 4 down")
        XCTAssertNil(ButtonProbe.describe(page: kHIDPage_Button, usage: 4, value: 1, previous: 1))
        // The first sighting of an idle button is not a press.
        XCTAssertNil(ButtonProbe.describe(page: kHIDPage_Button, usage: 4, value: 0, previous: nil))
    }

    func testTrimmedDropsTheZeroTail() {
        XCTAssertEqual(ButtonProbe.trimmed([0x04, 0x51, 0x00, 0x00]), [0x04, 0x51])
        XCTAssertEqual(ButtonProbe.trimmed([0x00, 0x00]), [0x00])
    }

    func testBitsPadsToEightPlaces() {
        XCTAssertEqual(ButtonProbe.bits(0x20), "00100000")
        XCTAssertEqual(ButtonProbe.bits(0xFF), "11111111")
    }
}
