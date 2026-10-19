// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import XCTest
@testable import MacRazer

/// Remaps saved in the Basilisk V4 Pro's own function table, the way Synapse saves them.
final class OnboardButtonsTests: XCTestCase {
    // MARK: Layout

    func testTheV4ProHasTheSameTableOnEveryConnection() {
        let cable = OnboardButtons.layout(pid: 0x00E2)
        XCTAssertNotNil(cable)
        XCTAssertEqual(cable, OnboardButtons.layout(pid: 0x00E3))
        XCTAssertEqual(cable, OnboardButtons.layout(pid: 0x00E4))
        XCTAssertNil(OnboardButtons.layout(pid: 0x00B9))
    }

    func testLeftRightScrollAndTheConnectionButtonAreNeverWritten() {
        let ids = OnboardButtons.layout(pid: 0x00E3)!.map(\.tableID)
        for never: UInt8 in [0x01, 0x02, 0x39, 0x6A] { XCTAssertFalse(ids.contains(never)) }
        XCTAssertEqual(OnboardButtons.fixed(pid: 0x00E3), [HardwareButton.wheelMode.rawValue: "Cycle Scroll Mode",
                                                          HardwareButton.sideTrigger.rawValue: "HyperShift"])
        let plan = OnboardButtons.plan(pid: 0x00E3, mappings: [HardwareButton.wheelMode.rawValue: .mediaKey(code: 0, name: "Volume Up")])
        XCTAssertFalse(plan.contains { $0.control.button == HardwareButton.wheelMode.rawValue }, "a stray wheel-mode remap is never written")
    }

    func testUnremappedRowsNameTheFactoryFunction() {
        let labels = Dictionary(uniqueKeysWithValues: OnboardButtons.layout(pid: 0x00E3)!.map { ($0.button, OnboardButtons.factoryLabel($0)) })
        XCTAssertEqual(labels[2], "Middle Click")
        XCTAssertEqual(labels[3], "Back")
        XCTAssertEqual(labels[4], "Forward")
        XCTAssertEqual(labels[HardwareButton.dpiCycle.rawValue], "DPI Cycle Up")
        XCTAssertEqual(labels[HardwareButton.leftClickSide.rawValue], "Cycle Up Profile")
        XCTAssertEqual(labels[HardwareButton.sideFront.rawValue], "Disabled")
        XCTAssertEqual(labels[HardwareButton.tiltLeft.rawValue], "Scroll Left")
        XCTAssertFalse(labels.values.contains("Default"), "every V4 Pro control has a known factory function")
    }

    // MARK: Blocks

    func testNativeBlocksMatchWhatTheMiceHold() {
        // Volume Up/Down as Synapse saved them on a Basilisk Mobile.
        XCTAssertEqual(OnboardButtons.nativeBlock(for: .mediaKey(code: 0, name: "Volume Up")), [0x0A, 0x02, 0x00, 0xE9, 0, 0, 0])
        XCTAssertEqual(OnboardButtons.nativeBlock(for: .mediaKey(code: 1, name: "Volume Down")), [0x0A, 0x02, 0x00, 0xEA, 0, 0, 0])
        // ⌘C: the C key (HID 0x06) with left GUI (0x08).
        XCTAssertEqual(OnboardButtons.nativeBlock(for: .keystroke(keyCode: 8, modifiers: CGEventFlags.maskCommand.rawValue, name: "Copy")),
                       [0x02, 0x02, 0x08, 0x06, 0, 0, 0])
        // CGEvent button 2 (middle) is HID button 3.
        XCTAssertEqual(OnboardButtons.nativeBlock(for: .mouseButton(button: 2, name: "Middle Click")), [0x01, 0x01, 0x03, 0, 0, 0, 0])
        XCTAssertNil(OnboardButtons.nativeBlock(for: .doubleClick))
        // The HyperShift clutch, as the press test found it (type 0C).
        XCTAssertEqual(OnboardButtons.nativeBlock(for: .hyperShift), [0x0C, 0x01, 0x01, 0, 0, 0, 0])
    }

    func testUsbCommandsMatchTheProbedFormat() {
        let get = RazerCommands.getButtonFunction(0x05)
        XCTAssertEqual([get.commandClass, get.commandId, get.dataSize], [0x02, 0x8C, 0x0A])
        XCTAssertEqual(Array(get.arguments.prefix(2)), [0x01, 0x05])
        let set = RazerCommands.setButtonFunction(0x05, block: [0x0A, 0x02, 0x00, 0xE9, 0, 0, 0])
        XCTAssertEqual([set.commandClass, set.commandId, set.dataSize], [0x02, 0x0C, 0x0A])
        // The dongle's own reply for entry 05 while it held Volume Up (2026-10-19).
        XCTAssertEqual(Array(set.arguments.prefix(10)), [0x01, 0x05, 0x00, 0x0A, 0x02, 0x00, 0xE9, 0x00, 0x00, 0x00])
        var reply = RazerReport(commandClass: 0x02, commandId: 0x8C, dataSize: 0x0A)
        reply.arguments.replaceSubrange(0..<10, with: [0x01, 0x05, 0x00, 0x0A, 0x02, 0x00, 0xE9, 0, 0, 0])
        XCTAssertEqual(RazerCommands.parseButtonFunction(reply, id: 0x05), [0x0A, 0x02, 0x00, 0xE9, 0, 0, 0])
        XCTAssertNil(RazerCommands.parseButtonFunction(reply, id: 0x04), "another entry's reply")
    }

    func testBluetoothReadSplitsCurrentFromFactory() throws {
        // The V4 Pro's reply for entry 09 while it held F13 (test write, 2026-10-19).
        let reply = Data([0x09, 0x00, 0x02, 0x01, 0x02, 0x01, 0x00, 0x09, 0x68, 0x00,
                          0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        let function = try BLEProtocol.parseButtonFunction(id: 0x09, reply)
        XCTAssertEqual(function.current, [0x02, 0x02, 0x00, 0x68, 0, 0, 0])
        XCTAssertEqual(function.factory, [0x01, 0x01, 0x09, 0, 0, 0, 0])
        XCTAssertThrowsError(try BLEProtocol.parseButtonFunction(id: 0x80, reply), "another entry's reply")
    }

    // MARK: Plan

    private func placement(_ plan: [OnboardButtons.Entry], _ button: Int) -> OnboardButtons.Placement {
        plan.first { $0.control.button == button }!.placement
    }

    func testUnmappedControlsKeepTheirFactoryFunction() {
        let plan = OnboardButtons.plan(pid: 0x00E3, mappings: [:])
        XCTAssertEqual(plan.count, OnboardButtons.layout(pid: 0x00E3)!.count)
        XCTAssertTrue(plan.allSatisfy { $0.placement == .factory })
    }

    func testNativeActionsAreSavedAsThemselves() {
        let back = 3, front = HardwareButton.sideFront.rawValue
        let plan = OnboardButtons.plan(pid: 0x00E4, mappings: [back: .mediaKey(code: 1, name: "Volume Down"),
                                                               front: .mediaKey(code: 0, name: "Volume Up")])
        XCTAssertEqual(placement(plan, back), .mouse([0x0A, 0x02, 0x00, 0xEA, 0, 0, 0]))
        XCTAssertEqual(placement(plan, front), .mouse([0x0A, 0x02, 0x00, 0xE9, 0, 0, 0]))
    }

    func testOnlyMacRazerActionsStayOnFactory() {
        let back = 3, middle = 2, dpi = HardwareButton.dpiCycle.rawValue
        let plan = OnboardButtons.plan(pid: 0x00E3, mappings: [
            back: .doubleClick,
            middle: .mediaKey(code: 0, name: "Volume Up"),
            ButtonRemapper.hyperShiftKey(middle): .mediaKey(code: 7, name: "Mute"),
            dpi: .mediaKey(code: 1, name: "Volume Down"),
        ])
        XCTAssertEqual(placement(plan, back), .app)
        XCTAssertEqual(placement(plan, middle), .mouse([0x0A, 0x02, 0x00, 0xE9, 0, 0, 0]), "a HyperShift mapping no longer keeps it on factory")
        XCTAssertEqual(placement(plan, dpi), .mouse([0x0A, 0x02, 0x00, 0xEA, 0, 0, 0]))
    }

    // MARK: HyperShift layer

    func testHyperShiftMappingsGoToTheMousesOwnLayer() {
        let middle = 2, front = HardwareButton.sideFront.rawValue
        let shifted = OnboardButtons.shiftedPlan(pid: 0x00E3, mappings: [
            ButtonRemapper.hyperShiftKey(middle): .mediaKey(code: 7, name: "Mute"),
            ButtonRemapper.hyperShiftKey(front): .doubleClick,
            front: .mediaKey(code: 0, name: "Volume Up"),
        ])
        XCTAssertEqual(shifted.count, OnboardButtons.layout(pid: 0x00E3)!.count, "every button has a HyperShift entry")
        XCTAssertEqual(placement(shifted, middle), .mouse(OnboardButtons.consumerBlock(0x00E2)))
        XCTAssertEqual(placement(shifted, front), .factory, "the mouse can't double-click")
        let set = RazerCommands.setButtonFunction(0x04, block: OnboardButtons.consumerBlock(0x00E9), layer: 0x01)
        XCTAssertEqual(Array(set.arguments.prefix(7)), [0x01, 0x04, 0x01, 0x0A, 0x02, 0x00, 0xE9], "as hslayertest wrote it")
    }

    func testTheHyperShiftLayerIsWrittenAndRestored() {
        let table = factoryTable()
        let mute = OnboardButtons.consumerBlock(0x00E2)
        let mapped = OnboardButtons.shiftedPlan(pid: 0x00E3, mappings: [ButtonRemapper.hyperShiftKey(3): .mediaKey(code: 7, name: "Mute")])
        var result = OnboardButtons.syncShifted(table, plan: mapped, owned: [:])
        XCTAssertEqual(table.shiftedWrites.map(\.0), [0x04])
        XCTAssertEqual(result.owned[0x04], [mute])
        XCTAssertTrue(table.writes.isEmpty, "the standard layer isn't touched")
        XCTAssertEqual(table.shifted[0x04], mute)
        // Already there: not written again.
        table.shiftedWrites = []
        result = OnboardButtons.syncShifted(table, plan: mapped, owned: result.owned)
        XCTAssertTrue(table.shiftedWrites.isEmpty)
        // Cleared: factory back, only where MacRazer wrote.
        let cleared = OnboardButtons.shiftedPlan(pid: 0x00E3, mappings: [:])
        result = OnboardButtons.syncShifted(table, plan: cleared, owned: result.owned)
        XCTAssertEqual(table.shiftedWrites.map(\.0), [0x04])
        XCTAssertEqual(table.shiftedWrites.first?.1, OnboardButtons.mouseBlock(4))
        XCTAssertEqual(result.owned[0x04], [])
        table.shiftedWrites = []
        _ = OnboardButtons.syncShifted(table, plan: cleared, owned: result.owned)
        XCTAssertTrue(table.shiftedWrites.isEmpty, "nothing of MacRazer's left there")
    }

    func testAHyperShiftEntrySetElsewhereIsLeftAlone() {
        let table = factoryTable()
        table.shifted[0x05] = OnboardButtons.consumerBlock(0x00CD) // Synapse, say
        let result = OnboardButtons.syncShifted(table, plan: OnboardButtons.shiftedPlan(pid: 0x00E3, mappings: [:]), owned: [:])
        XCTAssertEqual(result.failed, 0)
        XCTAssertTrue(table.shiftedWrites.isEmpty)
    }

    func testBluetoothReadsCarryTheHyperShiftLayer() throws {
        // bthstest: Scroll Click with Volume Down on its HyperShift layer, and Side Back with
        // nothing there; the write puts the layer byte in the payload, as over USB.
        let set = Data([0x03, 0x01, 0x01, 0x0A, 0x01, 0x02, 0x03, 0x00, 0x00, 0xEA, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(try BLEProtocol.parseButtonFunction(id: 0x03, set).current, OnboardButtons.mouseBlock(3))
        XCTAssertEqual(try BLEProtocol.parseShiftedButtonFunction(id: 0x03, set), OnboardButtons.consumerBlock(0x00EA))
        let unset = Data([0x04, 0x00, 0x01, 0x01, 0x01, 0x01, 0x04, 0x04, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertNil(try BLEProtocol.parseShiftedButtonFunction(id: 0x04, unset))
        XCTAssertEqual(BLEProtocol.buttonFunctionPayload(id: 0x04, block: OnboardButtons.consumerBlock(0x00E9), layer: 0x01),
                       [0x01, 0x04, 0x01, 0x0A, 0x02, 0x00, 0xE9, 0, 0, 0])
    }

    func testShiftedReadsTellASetEntryFromAnUnsetOne() {
        // hslayerread: 02/8c 01 04 01 while layer 01 held Volume Up, and before anything was
        // written there (the reply falls back to layer 00).
        var reply = RazerReport(commandClass: 0x02, commandId: 0x8C, dataSize: 0x0A)
        reply.arguments.replaceSubrange(0..<10, with: [0x01, 0x04, 0x01, 0x0A, 0x02, 0x00, 0xE9, 0, 0, 0])
        XCTAssertEqual(RazerCommands.parseShiftedButtonFunction(reply, id: 0x04), .set([0x0A, 0x02, 0x00, 0xE9, 0, 0, 0]))
        reply.arguments.replaceSubrange(0..<10, with: [0x01, 0x04, 0x00, 0x01, 0x01, 0x04, 0, 0, 0, 0])
        XCTAssertEqual(RazerCommands.parseShiftedButtonFunction(reply, id: 0x04), .unset)
        XCTAssertNil(RazerCommands.parseShiftedButtonFunction(reply, id: 0x05))
        XCTAssertEqual(RazerCommands.getButtonFunction(0x04, layer: 0x01).arguments[2], 0x01)
    }

    func testOnTheV4ProAnyButtonCanBeTheHyperShiftKey() {
        let r = remapper([:])
        XCTAssertTrue(r.hasHyperShiftKey, "the layer picker shows")
        r.setMappings([4: .hyperShift, ButtonRemapper.hyperShiftKey(3): .doubleClick,
                       ButtonRemapper.hyperShiftKey(5): .hyperShift,
                       ButtonRemapper.hyperShiftKey(2): .mediaKey(code: 7, name: "Mute")])
        XCTAssertEqual(r.mappings, [4: .hyperShift, ButtonRemapper.hyperShiftKey(2): .mediaKey(code: 7, name: "Mute")],
                       "a HyperShift key on the standard layer, and only what the mouse can do on its layer")
        let plan = OnboardButtons.plan(pid: 0x00E3, mappings: r.mappings)
        XCTAssertEqual(plan.first { $0.control.button == 4 }?.placement, .mouse(OnboardButtons.hyperShiftBlock), "saved in the mouse")
        let shifted = OnboardButtons.shiftedPlan(pid: 0x00E3, mappings: [ButtonRemapper.hyperShiftKey(4): .hyperShift])
        XCTAssertEqual(shifted.first { $0.control.button == 4 }?.placement, .factory, "no clutch on the HyperShift layer")
    }

    func testScrollUpAndDownAreRemappableAndSavedInTheMouse() {
        let layout = OnboardButtons.layout(pid: 0x00E3)!
        XCTAssertEqual(layout.first { $0.tableID == 0x09 }?.factory, [0x01, 0x01, 0x09, 0, 0, 0, 0])
        XCTAssertEqual(layout.first { $0.tableID == 0x0A }?.factory, [0x01, 0x01, 0x0A, 0, 0, 0, 0])
        let up = HardwareButton.scrollUp.rawValue
        let plan = OnboardButtons.plan(pid: 0x00E3, mappings: [up: .mediaKey(code: 0, name: "Volume Up")])
        XCTAssertEqual(plan.first { $0.control.button == up }?.placement, .mouse([0x0A, 0x02, 0x00, 0xE9, 0, 0, 0]))
        XCTAssertEqual(HardwareButton.scrollUp.label, "Scroll Up")
        XCTAssertEqual(HardwareButton.wheelMode.label, "Scroll Mode")
    }

    func testOnlyMouseButtonControlsAreSeenByTheApp() {
        let seen = OnboardButtons.layout(pid: 0x00E3)!.filter(OnboardButtons.appSees).map(\.button)
        XCTAssertEqual(Set(seen), [2, 3, 4])
    }

    func testRowsFollowTheMouse() {
        XCTAssertEqual(OnboardButtons.rowOrder(pid: 0x00E4), [
            2, HardwareButton.scrollUp.rawValue, HardwareButton.scrollDown.rawValue, HardwareButton.tiltLeft.rawValue, HardwareButton.tiltRight.rawValue,
            HardwareButton.dpiCycle.rawValue, HardwareButton.wheelMode.rawValue,
            HardwareButton.leftClickSide.rawValue, HardwareButton.sideFront.rawValue,
            4, 3, HardwareButton.sideTrigger.rawValue,
        ])
        XCTAssertNil(OnboardButtons.rowOrder(pid: 0x00B9))
        XCTAssertEqual(HardwareButton.leftClickSide.label, "Left Side")
    }

    // MARK: Detection

    func testPressesAreMatchedToTheControlThatSentThem() {
        let front = HardwareButton.sideFront.rawValue, left = HardwareButton.leftClickSide.rawValue
        let plan = OnboardButtons.plan(pid: 0x00E3, mappings: [front: .mediaKey(code: 0, name: "Volume Up"),
                                                               left: .keystroke(keyCode: 8, modifiers: CGEventFlags.maskCommand.rawValue, name: "Copy")])
        func control(_ page: Int, _ usage: Int, _ value: Int = 1) -> Int? {
            OnboardButtons.control(forPage: page, usage: usage, value: value, in: plan)
        }
        XCTAssertEqual(control(0x09, 4), 3, "HID button 4 is Side Back")
        XCTAssertEqual(control(0x09, 5), 4)
        XCTAssertEqual(control(0x09, 3), 2)
        XCTAssertNil(control(0x09, 1), "left click isn't a control")
        XCTAssertEqual(control(0x0C, 0xE9), front)
        XCTAssertEqual(control(0x07, 0x06), left, "the C of ⌘C")
        XCTAssertEqual(control(0x0C, 0x238, -1), HardwareButton.tiltLeft.rawValue)
        XCTAssertEqual(control(0x0C, 0x238, 1), HardwareButton.tiltRight.rawValue)
        XCTAssertNil(control(0x07, 0xE3), "a bare modifier")
        XCTAssertEqual(control(0x01, 0x38, 1), HardwareButton.scrollUp.rawValue)
        XCTAssertEqual(control(0x01, 0x38, -2), HardwareButton.scrollDown.rawValue)
    }

    func testALoneModifierIsSavedAsItsModifierBit() {
        func block(_ keyCode: UInt16) -> [UInt8]? {
            OnboardButtons.nativeBlock(for: .keystroke(keyCode: keyCode, modifiers: 0, name: ""))
        }
        XCTAssertEqual(block(55), [0x02, 0x02, 0x08, 0x00, 0, 0, 0], "Left ⌘")
        XCTAssertEqual(block(54), [0x02, 0x02, 0x80, 0x00, 0, 0, 0], "Right ⌘")
        XCTAssertEqual(block(59), [0x02, 0x02, 0x01, 0x00, 0, 0, 0], "Left ⌃")
        XCTAssertEqual(block(60), [0x02, 0x02, 0x20, 0x00, 0, 0, 0], "Right ⇧")
        XCTAssertEqual(block(61), [0x02, 0x02, 0x40, 0x00, 0, 0, 0], "Right ⌥")
        let back = 3 // Side Back
        let plan = OnboardButtons.plan(pid: 0x00E3, mappings: [3: .keystroke(keyCode: 54, modifiers: 0, name: "Right ⌘")])
        XCTAssertEqual(OnboardButtons.control(forPage: 0x07, usage: 0xE7, value: 1, in: plan), back)
        XCTAssertNil(OnboardButtons.control(forPage: 0x07, usage: 0xE3, value: 1, in: plan), "the other ⌘")
    }

    func testWheelModeAndDpiAreHeardFromTheMousesNotices() {
        let plan = OnboardButtons.plan(pid: 0x00E3, mappings: [:])
        XCTAssertEqual(OnboardButtons.control(forNotice: [0x05, 0x39, 0x02], in: plan), HardwareButton.wheelMode.rawValue)
        XCTAssertEqual(OnboardButtons.control(forNotice: [0x05, 0x39], in: plan), HardwareButton.wheelMode.rawValue)
        XCTAssertEqual(OnboardButtons.control(forNotice: [0x05, 0x02, 0x06, 0x40], in: plan), HardwareButton.dpiCycle.rawValue)
        XCTAssertNil(OnboardButtons.control(forNotice: [0x05, 0x31, 0xC2], in: plan), "a battery notice")
        XCTAssertNil(OnboardButtons.control(forNotice: [0x04, 0x52], in: plan))
        let remapped = OnboardButtons.plan(pid: 0x00E3, mappings: [HardwareButton.dpiCycle.rawValue: .mediaKey(code: 7, name: "Mute")])
        XCTAssertNil(OnboardButtons.control(forNotice: [0x05, 0x02, 0x06, 0x40], in: remapped), "the DPI button no longer changes DPI")
    }

    // MARK: Steps

    private let factory = OnboardButtons.mouseBlock(4)
    private let volUp = OnboardButtons.consumerBlock(0x00E9)
    private let copy: [UInt8] = [0x02, 0x02, 0x08, 0x06, 0, 0, 0]

    func testARemapIsWrittenAndOwned() {
        let step = OnboardButtons.step(.mouse(volUp), current: factory, factory: factory, owned: [])
        XCTAssertEqual(step.write, volUp)
        XCTAssertEqual(step.owned, [volUp])
        XCTAssertEqual(step.ownedIfFailed, [volUp], "the mouse may hold it anyway")
    }

    func testARemapAlreadyInPlaceIsNotWrittenAgain() {
        let step = OnboardButtons.step(.mouse(volUp), current: volUp, factory: factory, owned: [])
        XCTAssertNil(step.write)
        XCTAssertEqual(step.owned, [volUp])
    }

    func testAClearedRemapGoesBackToFactory() {
        for placement in [OnboardButtons.Placement.factory, .app] {
            let step = OnboardButtons.step(placement, current: volUp, factory: factory, owned: [volUp])
            XCTAssertEqual(step.write, factory)
            XCTAssertEqual(step.owned, [])
            XCTAssertEqual(step.ownedIfFailed, [volUp], "tried again next time")
        }
    }

    func testAnEntrySetElsewhereIsLeftAlone() {
        // Never written by MacRazer.
        var step = OnboardButtons.step(.factory, current: copy, factory: factory, owned: [])
        XCTAssertNil(step.write)
        // Written by MacRazer, then changed by something else.
        step = OnboardButtons.step(.factory, current: copy, factory: factory, owned: [volUp])
        XCTAssertNil(step.write)
        XCTAssertEqual(step.owned, [], "no longer MacRazer's")
    }

    // MARK: Sync

    private final class FakeTable: ButtonFunctionTable {
        var entries: [UInt8: [UInt8]]
        var writes: [UInt8] = []
        var shiftedWrites: [(UInt8, [UInt8])] = []
        /// The HyperShift layer; an id missing here was never written.
        var shifted: [UInt8: [UInt8]] = [:]
        var refuse: Set<UInt8> = []
        init(_ entries: [UInt8: [UInt8]]) { self.entries = entries }
        func readButtonBlock(_ id: UInt8) throws -> [UInt8] {
            guard let block = entries[id] else { throw HIDDevice.HIDError.timeout }
            return block
        }
        func writeButtonBlock(_ id: UInt8, block: [UInt8]) throws {
            XCTAssertNotEqual(id, OnboardButtons.connectionSlotID)
            writes.append(id)
            guard !refuse.contains(id) else { throw HIDDevice.HIDError.badResponse }
            entries[id] = block
        }
        func readShiftedBlock(_ id: UInt8) throws -> [UInt8]? {
            guard entries[id] != nil else { throw HIDDevice.HIDError.timeout }
            return shifted[id]
        }
        func writeShiftedBlock(_ id: UInt8, block: [UInt8]) throws {
            XCTAssertNotEqual(id, OnboardButtons.connectionSlotID)
            shiftedWrites.append((id, block))
            guard !refuse.contains(id) else { throw HIDDevice.HIDError.badResponse }
            shifted[id] = block
        }
    }

    private func factoryTable() -> FakeTable {
        FakeTable(Dictionary(uniqueKeysWithValues: OnboardButtons.layout(pid: 0x00E3)!.map { ($0.tableID, $0.factory) }))
    }

    func testSyncWritesOnlyWhatChangesAndRestoresWhenCleared() {
        let table = factoryTable()
        var result = OnboardButtons.sync(table, plan: OnboardButtons.plan(pid: 0x00E3, mappings: [3: .mediaKey(code: 0, name: "Volume Up")]), owned: [:])
        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(table.writes, [0x04])
        XCTAssertEqual(table.entries[0x04], volUp)
        XCTAssertEqual(result.owned[0x04], [volUp])

        table.writes = []
        result = OnboardButtons.sync(table, plan: OnboardButtons.plan(pid: 0x00E3, mappings: [:]), owned: result.owned)
        XCTAssertEqual(table.writes, [0x04])
        XCTAssertEqual(table.entries[0x04], factory)
        XCTAssertEqual(result.owned[0x04], [])
    }

    func testSyncLeavesOtherSettingsAlone() {
        let table = factoryTable()
        table.entries[0x05] = copy // set by Synapse elsewhere
        let result = OnboardButtons.sync(table, plan: OnboardButtons.plan(pid: 0x00E3, mappings: [:]), owned: [:])
        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(table.writes, [])
        XCTAssertEqual(table.entries[0x05], copy)
    }

    func testAFailedWriteIsCountedAndRemembered() {
        let table = factoryTable()
        table.refuse = [0x04]
        let result = OnboardButtons.sync(table, plan: OnboardButtons.plan(pid: 0x00E3, mappings: [3: .mediaKey(code: 0, name: "Volume Up")]), owned: [:])
        XCTAssertEqual(result.failed, 1)
        XCTAssertEqual(result.owned[0x04], [volUp])
    }

    func testOwnershipIsKeptPerSerial() {
        let name = "MacRazerTests.\(#function)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let store = OnboardOwnership(defaults: defaults)
        store.set([0x04: [volUp], 0x05: []], serial: "PM2401")
        XCTAssertEqual(store.owned(serial: "PM2401"), [0x04: [volUp]])
        XCTAssertEqual(store.owned(serial: "OTHER"), [:])
        store.set([0x04: []], serial: "PM2401")
        XCTAssertNil(defaults.dictionary(forKey: OnboardOwnership.defaultsKey)?["PM2401"])
    }

    // MARK: Remapper

    private var emitted: [RemapAction] = []

    private func remapper(_ mappings: [Int: RemapAction], suite: String = #function) -> ButtonRemapper {
        let name = "MacRazerTests.\(suite)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let r = ButtonRemapper(defaults: defaults) { [weak self] in self?.emitted.append($0) }
        r.setActiveDevice("V4PRO", deviceID: 0x00E3)
        r.setMappings(mappings)
        return r
    }

    private func click(_ r: ButtonRemapper, _ button: Int64, down: Bool) -> Bool {
        let event = CGEvent(mouseEventSource: nil, mouseType: down ? .otherMouseDown : .otherMouseUp,
                            mouseCursorPosition: .zero, mouseButton: CGMouseButton(rawValue: UInt32(button))!)!
        event.setIntegerValueField(.mouseEventButtonNumber, value: button)
        return r.handle(type: down ? .otherMouseDown : .otherMouseUp, event: event) != nil
    }

    func testSavedRemapsAreNotRemappedAgainByTheTap() {
        let r = remapper([3: .mediaKey(code: 1, name: "Volume Down")])
        XCTAssertTrue(r.mappingsLiveInMouse)
        XCTAssertFalse(r.needsEventTap, "nothing needs MacRazer")
        XCTAssertTrue(click(r, 3, down: true), "whatever the mouse sends goes through")
        XCTAssertTrue(click(r, 3, down: false))
        XCTAssertEqual(emitted, [])
        XCTAssertEqual(r.onboardFixed[HardwareButton.sideTrigger.rawValue], "HyperShift")
        XCTAssertEqual(r.activeDeviceKey, "V4PRO")
    }

    func testMacRazerActionsAreDoneByTheTap() {
        let r = remapper([3: .doubleClick])
        XCTAssertTrue(r.needsEventTap)
        XCTAssertFalse(click(r, 3, down: true))
        XCTAssertFalse(click(r, 3, down: false))
        XCTAssertEqual(emitted, [.doubleClick])
    }

    func testRemapsForFixedOrUnsupportedControlsAreDropped() {
        // Scroll Mode was remappable in an earlier build; its saved remap has no row to clear
        // it from, and the popover counted it as "1 remapped".
        let name = "MacRazerTests.\(#function)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let saved: [Int: RemapAction] = [HardwareButton.wheelMode.rawValue: .mediaKey(code: 1, name: "Volume Down"),
                                         HardwareButton.sideTrigger.rawValue: .doubleClick, 3: .passthrough]
        defaults.set(try! JSONEncoder().encode(saved), forKey: "buttonMappings-V4PRO")
        let r = ButtonRemapper(defaults: defaults)
        r.setActiveDevice("V4PRO", deviceID: 0x00E3)
        XCTAssertEqual(r.mappings, [3: .passthrough])
        let stored = try! JSONDecoder().decode([Int: RemapAction].self, from: defaults.data(forKey: "buttonMappings-V4PRO")!)
        XCTAssertEqual(stored, [3: .passthrough], "saved without them")
        r.setMappings([HardwareButton.wheelMode.rawValue: .doubleClick, 4: .doubleClick])
        XCTAssertEqual(r.mappings, [4: .doubleClick], "a profile can't bring one back")
    }

    func testSilentButtonsAreFlaggedUntilRemapped() {
        let front = HardwareButton.sideFront.rawValue, left = HardwareButton.leftClickSide.rawValue
        let r = remapper([:])
        XCTAssertTrue(r.undetectable(front))
        XCTAssertTrue(r.undetectable(left))
        XCTAssertFalse(r.undetectable(3))
        XCTAssertFalse(r.undetectable(HardwareButton.dpiCycle.rawValue), "heard from its notice")
        r.setAction(.mediaKey(code: 0, name: "Volume Up"), for: front)
        XCTAssertFalse(r.undetectable(front), "it sends Volume Up now")
    }

    func testMacRazerActionsOnControlsItCantSeeAreFlagged() {
        let dpi = HardwareButton.dpiCycle.rawValue
        let r = remapper([dpi: .doubleClick])
        XCTAssertFalse(r.appSees(dpi))
        XCTAssertTrue(r.appSees(3))
        XCTAssertTrue(r.remapCantFire(dpi))
        XCTAssertFalse(r.remapCantFire(3))
    }

    // MARK: Reading the mouse

    private func control(_ button: Int) -> OnboardButtons.Control {
        OnboardButtons.layout(pid: 0x00E3)!.first { $0.button == button }!
    }

    func testEveryActionTheMouseKeepsReadsBackAsItself() {
        let sideBack = control(3)
        let actions: [RemapAction] = [
            ButtonRemapper.presets[0].action,
            .keystroke(keyCode: 55, modifiers: 0, name: "Left ⌘"),
            .keystroke(keyCode: 54, modifiers: 0, name: "Right ⌘"),
            .mouseButton(button: 2, name: "Middle Click"),
            .mediaKey(code: 16, name: "Play / Pause"),
            .cycleProfile(up: false),
            .hyperShift,
        ]
        for action in actions {
            let block = OnboardButtons.nativeBlock(for: action)!
            XCTAssertEqual(OnboardButtons.action(for: block, control: sideBack), action)
        }
        XCTAssertEqual(OnboardButtons.action(for: sideBack.factory, control: sideBack), .passthrough)
        // A keystroke recorded with the recorder comes back with the recorder's name.
        let f5 = OnboardButtons.action(for: BLEProtocol.keyboardBlock(hidUsage: 0x09, modifiers: 0x0A), control: sideBack)
        XCTAssertEqual(f5, .keystroke(keyCode: 3, modifiers: CGEventFlags([.maskShift, .maskCommand]).rawValue, name: "⇧⌘F"))
    }

    func testBlocksMacRazerCantWriteAreNotShownAsAnAction() {
        let sideBack = control(3)
        XCTAssertNil(OnboardButtons.action(for: [0x02, 0x02, 0x10, 0x09, 0, 0, 0], control: sideBack), "right ⌃ with a key")
        XCTAssertNil(OnboardButtons.action(for: [0x03, 0x02, 0x01, 0x02, 0, 0, 0], control: sideBack), "a macro")
        XCTAssertNil(OnboardButtons.action(for: OnboardButtons.disabledBlock, control: sideBack))
        XCTAssertEqual(OnboardButtons.action(for: OnboardButtons.disabledBlock, control: control(HardwareButton.sideFront.rawValue)), .passthrough)
    }

    func testAFreshInstallShowsTheRemapsTheMouseHolds() {
        let layout = OnboardButtons.layout(pid: 0x00E3)!
        var standard = Dictionary(uniqueKeysWithValues: layout.map { ($0.tableID, $0.factory) })
        var shifted: [UInt8: [UInt8]?] = Dictionary(uniqueKeysWithValues: layout.map { ($0.tableID, nil) })
        let copy = ButtonRemapper.presets[0].action
        standard[0x05] = OnboardButtons.nativeBlock(for: copy)!                  // Side Forward
        standard[0x80] = OnboardButtons.hyperShiftBlock                          // Side Front
        shifted[0x04] = OnboardButtons.consumerBlock(0x00E9)                     // Side Back, Volume Up
        let adopted = OnboardButtons.adopt(pid: 0x00E3, mappings: [:], standard: standard, shifted: shifted)
        XCTAssertEqual(adopted, [4: copy, HardwareButton.sideFront.rawValue: .hyperShift,
                                 ButtonRemapper.hyperShiftKey(3): .mediaKey(code: 0, name: "Volume Up")])
        // Syncing what was read writes nothing.
        for entry in OnboardButtons.plan(pid: 0x00E3, mappings: adopted) {
            XCTAssertNil(OnboardButtons.step(entry.placement, current: standard[entry.control.tableID]!,
                                             factory: entry.control.factory, owned: []).write)
        }
    }

    func testTheMouseWinsOverAStaleTableButKeepsWhatOnlyMacRazerDoes() {
        let layout = OnboardButtons.layout(pid: 0x00E3)!
        var standard = Dictionary(uniqueKeysWithValues: layout.map { ($0.tableID, $0.factory) })
        let shifted: [UInt8: [UInt8]?] = [:]
        standard[0x04] = OnboardButtons.mouseBlock(5)                            // Side Back changed elsewhere
        let named = RemapAction.keystroke(keyCode: 8, modifiers: CGEventFlags.maskCommand.rawValue, name: "My Copy")
        standard[0x05] = OnboardButtons.nativeBlock(for: named)!
        let local: [Int: RemapAction] = [3: .mediaKey(code: 7, name: "Mute"), 4: named, 2: .doubleClick,
                                         HardwareButton.dpiCycle.rawValue: .mediaKey(code: 0, name: "Volume Up")]
        let adopted = OnboardButtons.adopt(pid: 0x00E3, mappings: local, standard: standard, shifted: shifted)
        XCTAssertEqual(adopted, [3: .mouseButton(button: 4, name: "Forward"), 4: named, 2: .doubleClick],
                       "the DPI button is back on its factory function in the mouse; unread layers keep their mappings")
    }
}
