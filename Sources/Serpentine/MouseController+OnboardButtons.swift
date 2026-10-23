// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation
import AppKit
import CoreBluetooth
import RazerProtocol
import RazerDeviceKit

// MARK: - Remaps saved in the mouse

/// Keeping the mouse's button function table in line with the remap table (`OnboardButtons`).
extension MouseController {
    /// Whether the connected mouse keeps its remaps itself (`OnboardButtons`).
    var supportsOnboardButtons: Bool { deviceID.map { OnboardButtons.layout(pid: $0) != nil } ?? false }

    /// Main thread. Hands the remap table over; it is written into the mouse straight away,
    /// and again whenever a mouse whose table is known connects.
    func setOnboardMappings(_ mappings: [Int: RemapAction], deviceKey: String?) {
        io.user { [weak self] in
            guard let self else { return }
            self.onboardMappings = deviceKey.map { ($0, mappings) }
            guard self.device != nil else { return }
            self.syncOnboardButtonsSync()
        }
    }

    /// io-queue only. Brings the open mouse's function table in line with the remap table
    /// (`OnboardButtons.sync`), and its HyperShift layer with the HyperShift mappings
    /// (`OnboardButtons.syncShifted`). A remap the mouse
    /// can do is written; a control left unmapped, or one only Serpentine can handle, gets its
    /// factory function back, but only where Serpentine wrote what it holds now
    /// (`OnboardButtons.step`), so a function set some other way is left alone. Needs the
    /// mouse's serial number, which is what Serpentine's record of its writes is kept by; and
    /// the remap table must be this mouse's, so another mouse's remaps are never written.
    func syncOnboardButtonsSync() {
        guard let dev = device, let table = dev as? ButtonFunctionTable,
              OnboardButtons.layout(pid: dev.productID) != nil,
              let known = knownSerial, known.locationID == dev.locationID, known.pid == dev.productID,
              var handed = onboardMappings, handed.deviceKey == known.serial else { return }
        let slot = (dev as? OnboardSlotTransport)?.slot ?? OnboardSlots.first
        let serial = OnboardSlots.ownershipKey(serial: known.serial, slot: slot)
        // The table as read just now, when it was; the writes below then needn't read it again.
        var fresh: (standard: [UInt8: [UInt8]], shifted: [UInt8: [UInt8]?])?
        if onboardReadFrom.map({ $0.serial != serial || $0.locationID != dev.locationID }) ?? true {
            // First sync on this link or slot: the mouse's remaps win over the table handed
            // over, which on another computer, or after a change made on one, is not what the
            // mouse holds. Nothing is written until the whole table has been read.
            guard let read = readOnboardTablesSync(table, pid: dev.productID) else { return }
            fresh = read
            onboardReadFrom = (serial, dev.locationID)
            let adopted = OnboardButtons.adopt(pid: dev.productID, mappings: handed.mappings,
                                               standard: read.standard, shifted: read.shifted)
            if adopted != handed.mappings || onboardPublishNextRead {
                handed = (handed.deviceKey, adopted)
                onboardMappings = handed
                let key = handed.deviceKey
                publish { self.onOnboardMappingsRead?(key, adopted) }
            }
            onboardPublishNextRead = false
        }
        let plan = OnboardButtons.plan(pid: dev.productID, mappings: handed.mappings)
        let shifted = OnboardButtons.shiftedPlan(pid: dev.productID, mappings: handed.mappings)
        if let done = onboardConfirmed, done.serial == serial, done.locationID == dev.locationID,
           done.plan == plan, done.shifted == shifted { return }
        let (owned, failedStandard) = OnboardButtons.sync(table, plan: plan, owned: onboardOwnership.owned(serial: serial),
                                                          current: fresh?.standard)
        onboardOwnership.set(owned, serial: serial)
        var failed = failedStandard
        // The HyperShift layer, kept track of under its own record.
        let shiftedKey = OnboardOwnership.shiftedKey(serial: serial)
        let (shiftedOwned, failedShifted) = OnboardButtons.syncShifted(table, plan: shifted,
                                                                         owned: onboardOwnership.owned(serial: shiftedKey),
                                                                         current: fresh?.shifted)
        onboardOwnership.set(shiftedOwned, serial: shiftedKey)
        failed += failedShifted
        onboardConfirmed = failed == 0 ? (serial, dev.locationID, plan, shifted) : nil
        let message: String? = failed == 0 ? nil : "Couldn't save \(failed) button\(failed == 1 ? "" : "s") in the mouse. Serpentine tries again on its next check."
        publish { self.update(\.onboardWriteError, message) }
    }

    /// io-queue only. Every remappable entry of the mouse's table, both layers (nil for an
    /// unset HyperShift entry), or nil when any read fails.
    func readOnboardTablesSync(_ table: ButtonFunctionTable, pid: Int)

        -> (standard: [UInt8: [UInt8]], shifted: [UInt8: [UInt8]?])? {
        guard let controls = OnboardButtons.layout(pid: pid) else { return nil }
        var standard: [UInt8: [UInt8]] = [:]
        var shifted: [UInt8: [UInt8]?] = [:]
        for control in controls {
            let id = control.tableID
            guard let block = try? table.readButtonBlock(id) else { return nil }
            standard[id] = block
            // Not `try?`: it would flatten an unset entry (nil) into a failed read.
            do { shifted[id] = .some(try table.readShiftedBlock(id)) } catch { return nil }
        }
        return (standard, shifted)
    }
}
