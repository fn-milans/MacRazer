// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation
import RazerProtocol

/// The link of a mouse with onboard slots, with every settings command pointed at the
/// active slot. Owned by `MouseController` and used on its `io` queue only.
///
/// Over Bluetooth the same profile commands are translated by `BLEProtocol` (class 0x03 there),
/// and the slot goes in the third byte of each settings key, which `BluetoothDevice` fills in.
public final class OnboardSlotTransport: RazerTransport, ButtonFunctionTable {
    public let base: any RazerTransport & ButtonFunctionTable
    /// The slot settings commands go to. Set by `MouseController` when it reads or changes
    /// the active slot.
    public var slot: UInt8 = OnboardSlots.first {
        didSet { (base as? BluetoothDevice)?.slot = slot }
    }

    public init(_ base: any RazerTransport & ButtonFunctionTable) { self.base = base }

    public var productID: Int { base.productID }
    public var productName: String { base.productName }
    public var locationID: Int { base.locationID }
    public var isBluetooth: Bool { base.isBluetooth }
    public func close() { base.close() }

    public func sendWithRetry(_ report: RazerReport) throws -> RazerReport {
        try base.sendWithRetry(OnboardSlots.retarget(report, to: slot))
    }

    // The same table commands as `HIDDevice`'s, sent through `sendWithRetry` above. Bluetooth
    // has its own table commands, already pointed at the slot.
    public func readButtonBlock(_ id: UInt8) throws -> [UInt8] {
        if base.isBluetooth { return try base.readButtonBlock(id) }
        guard let block = RazerCommands.parseButtonFunction(try sendWithRetry(RazerCommands.getButtonFunction(id)), id: id)
        else { throw HIDDevice.HIDError.badResponse }
        return block
    }

    public func writeButtonBlock(_ id: UInt8, block: [UInt8]) throws {
        if base.isBluetooth { return try base.writeButtonBlock(id, block: block) }
        _ = try sendWithRetry(RazerCommands.setButtonFunction(id, block: block))
        guard try readButtonBlock(id) == block else { throw HIDDevice.HIDError.badResponse }
    }

    public func readShiftedBlock(_ id: UInt8) throws -> [UInt8]? {
        if base.isBluetooth { return try base.readShiftedBlock(id) }
        let resp = try sendWithRetry(RazerCommands.getButtonFunction(id, layer: 0x01))
        switch RazerCommands.parseShiftedButtonFunction(resp, id: id) {
        case .set(let block): return block
        case .unset: return nil
        case nil: throw HIDDevice.HIDError.badResponse
        }
    }

    public func writeShiftedBlock(_ id: UInt8, block: [UInt8]) throws {
        if base.isBluetooth { return try base.writeShiftedBlock(id, block: block) }
        _ = try sendWithRetry(RazerCommands.setButtonFunction(id, block: block, layer: 0x01))
        guard try readShiftedBlock(id) == block else { throw HIDDevice.HIDError.badResponse }
    }
}

extension RazerTransport {
    /// The Bluetooth link under this one, for the commands only Bluetooth has.
    public var bluetoothDevice: BluetoothDevice? {
        (self as? BluetoothDevice) ?? ((self as? OnboardSlotTransport)?.base as? BluetoothDevice)
    }
}
