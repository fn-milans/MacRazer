// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

final class HardwareButtonsTests: XCTestCase {
    private let v4Pro = HardwareButton.layout(pid: 0x00E3)!

    func testOnlyMeasuredMiceHaveALayout() {
        XCTAssertEqual(HardwareButton.layout(pid: 0x00E2), HardwareButton.layout(pid: 0x00E3))
        XCTAssertNil(HardwareButton.layout(pid: 0x00B9)) // Basilisk V3 X: never measured
    }

    func testIdsCannotCollideWithMouseButtonsOrTheBluetoothDpiCycle() {
        for button in HardwareButton.allCases {
            XCTAssertLessThan(button.rawValue, -1)
            XCTAssertEqual(ButtonRemapper.label(for: button.rawValue), button.label)
        }
    }

    func testReport4PressAndRelease() {
        // From recheck-driver.log: `04 52` while the DPI button is held, `04` once it is up.
        var d = HardwareButtonDecoder(layout: v4Pro)
        XCTAssertEqual(d.report4([0x04, 0x52, 0, 0]), [.init(button: .dpiCycle, down: true)])
        XCTAssertEqual(d.report4([0x04, 0x52, 0, 0]), [], "a repeat of the same list is no new press")
        XCTAssertEqual(d.report4([0x04, 0, 0, 0]), [.init(button: .dpiCycle, down: false)])
    }

    func testReport4TwoButtonsHeld() {
        var d = HardwareButtonDecoder(layout: v4Pro)
        XCTAssertEqual(d.report4([0x04, 0x59]), [.init(button: .sideTrigger, down: true)])
        XCTAssertEqual(d.report4([0x04, 0x59, 0x50]), [.init(button: .leftClickSide, down: true)])
        XCTAssertEqual(d.report4([0x04, 0x50]), [.init(button: .sideTrigger, down: false)])
    }

    func testOtherReportsAndUnknownCodesAreIgnored() {
        var d = HardwareButtonDecoder(layout: v4Pro)
        XCTAssertEqual(d.report4([0x05, 0x39, 0x02]), [], "report 5 is a notice, not a button")
        XCTAssertEqual(d.report4([0x04, 0x77]), [])
    }

    func testTiltBitsLeaveOrdinaryButtonsAlone() {
        var d = HardwareButtonDecoder(layout: v4Pro)
        XCTAssertEqual(d.pointer([0x10, 0, 0]), [], "button 5 is macOS's to handle")
        XCTAssertEqual(d.pointer([0x20, 0, 0]), [.init(button: .tiltLeft, down: true)])
        XCTAssertEqual(d.pointer([0x00, 0, 0]), [.init(button: .tiltLeft, down: false)])
        XCTAssertEqual(d.pointer([0x41, 0, 0]), [.init(button: .tiltRight, down: true)])
    }

    func testPointerReportsDoNotReleaseReport4Buttons() {
        var d = HardwareButtonDecoder(layout: v4Pro)
        _ = d.report4([0x04, 0x52])
        XCTAssertEqual(d.pointer([0x00]), [])
        XCTAssertEqual(d.releaseAll(), [.init(button: .dpiCycle, down: false)])
        XCTAssertTrue(d.held.isEmpty)
    }

    // MARK: DPI stage step

    /// The V4 Pro's own reply: 400/800/1600/3200/6400, third stage active, numbered from 1.
    private func stagesReply(active: UInt8) -> RazerReport {
        var r = RazerReport(commandClass: 0x04, commandId: 0x86, dataSize: 0x26)
        r.arguments[0] = 0x01
        r.arguments[1] = active
        r.arguments[2] = 5
        for (i, dpi) in [400, 800, 1600, 3200, 6400].enumerated() {
            let base = 3 + i * 7
            r.arguments[base] = UInt8(i + 1)
            r.arguments[base + 1] = UInt8(dpi >> 8); r.arguments[base + 2] = UInt8(dpi & 0xFF)
            r.arguments[base + 3] = UInt8(dpi >> 8); r.arguments[base + 4] = UInt8(dpi & 0xFF)
        }
        return r
    }

    func testNextDpiStageKeepsEveryStageAndMovesTheActiveByte() throws {
        let reply = stagesReply(active: 3)
        let step = try XCTUnwrap(RazerCommands.nextDPIStage(from: reply))
        XCTAssertEqual(step.dpi, 3200)
        XCTAssertEqual([step.report.commandClass, step.report.commandId, step.report.dataSize], [0x04, 0x06, 0x26])
        XCTAssertEqual(step.report.arguments[1], 4)
        XCTAssertEqual(Array(step.report.arguments[2..<0x26]), Array(reply.arguments[2..<0x26]))
    }

    func testNextDpiStageWrapsAfterTheLast() throws {
        let step = try XCTUnwrap(RazerCommands.nextDPIStage(from: stagesReply(active: 5)))
        XCTAssertEqual(step.dpi, 400)
        XCTAssertEqual(step.report.arguments[1], 1)
    }

    func testNextDpiStageFromAnUnexpectedActiveByteGoesToStageOne() throws {
        XCTAssertEqual(try XCTUnwrap(RazerCommands.nextDPIStage(from: stagesReply(active: 0))).dpi, 400)
        var empty = stagesReply(active: 1)
        empty.arguments[2] = 0
        XCTAssertNil(RazerCommands.nextDPIStage(from: empty))
    }

    // MARK: Wheel mode

    func testWheelModeCommandsAsMeasured() {
        let get = RazerCommands.getWheelMode()
        XCTAssertEqual([get.commandClass, get.commandId, get.dataSize, get.arguments[0]], [0x02, 0xB0, 0x02, 0x01])
        let set = RazerCommands.setWheelMode(0x02)
        XCTAssertEqual([set.commandClass, set.commandId, set.dataSize], [0x02, 0x30, 0x02])
        XCTAssertEqual(Array(set.arguments.prefix(2)), [0x01, 0x02])
    }

    func testWheelModeCyclesThroughAllThree() {
        // The mouse's own order: 01 -> 02 (probe pass 1), 02 -> 00 (09:52 press).
        XCTAssertEqual(RazerCommands.nextWheelMode(current: 0x00), 0x01)
        XCTAssertEqual(RazerCommands.nextWheelMode(current: 0x01), 0x02)
        XCTAssertEqual(RazerCommands.nextWheelMode(current: 0x02), 0x00)
        XCTAssertEqual(RazerCommands.nextWheelMode(current: 0x07), 0x00)
    }

    func testSmartReelSetMatchesOpenRazer() {
        // razer_chroma_misc_set_scroll_smart_reel; accepted by the V4 Pro (read back 01 01).
        let on = RazerCommands.setScrollSmartReel(true)
        XCTAssertEqual([on.commandClass, on.commandId, on.dataSize], [0x02, 0x17, 0x02])
        XCTAssertEqual(Array(on.arguments.prefix(2)), [0x01, 0x01])
        XCTAssertEqual(RazerCommands.setScrollSmartReel(false).arguments[1], 0x00)
    }
}
