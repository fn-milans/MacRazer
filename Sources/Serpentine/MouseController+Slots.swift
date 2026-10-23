// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation
import AppKit
import CoreBluetooth
import RazerProtocol
import RazerDeviceKit

// MARK: - Onboard profile slots

/// The mouse's own profile slots (`OnboardSlots`).
extension MouseController {
    /// On a mouse with onboard slots, the slots are its profiles: one is always active, and
    /// every setting changed goes into it. Snapshot profiles are for mice without slots.
    var usesSlotProfiles: Bool { supportsOnboardSlots }

    /// The connected mouse keeps its profiles in slots, but they haven't been read (it didn't
    /// answer as the link opened, and hasn't on a poll since). Its profiles can't be shown,
    /// and it must not fall back to snapshot profiles.
    var onboardSlotsUnread: Bool {
        connected && !supportsOnboardSlots && capabilities.onboardSlots
    }

    func slotName(_ slot: Int) -> String { slotNames[slot] ?? SlotNames.defaultName(slot) }

    /// io-queue only. The link is on another slot now, or its slot was reset: its remaps are
    /// read back from the mouse on the next sync, from an empty table so nothing of the
    /// previous slot's carries over, and handed to the remapper.
    func followSlotSync() {
        onboardConfirmed = nil
        // Read again even when it is the slot last read: a reset changes it under the app.
        onboardReadFrom = nil
        onboardMappings = knownSerial.map { ($0.serial, [:]) }
        onboardPublishNextRead = true
        zonesReadFor = nil
    }

    /// io-queue only. Makes an existing slot the active one and follows it (`followSlotSync`).
    /// The profile shows as active straight away; its settings and remaps are read after
    /// (`slotCommand`), DPI and lighting first, as they are what changes on screen.
    func enterSlotSync(_ slot: UInt8, on slotted: OnboardSlotTransport) -> Bool {
        if slotted.slot != slot {
            guard (try? slotted.base.sendWithRetry(OnboardSlots.activate(slot))) != nil else { return false }
            slotted.slot = slot
            publish { self.update(\.activeOnboardSlot, Int(slot)) }
        }
        followSlotSync()
        return true
    }

    /// io-queue only. Puts a slot back to how it came from the factory
    /// (`OnboardSlots.factorySettings`, the button table on both layers), and forgets what
    /// Serpentine wrote there. Over USB it needn't be the active slot. Over Bluetooth it is made
    /// active first: table reads there only come from the active slot, so comparing another
    /// slot's entries would read the wrong one (an add made that way cleared slot 1's
    /// HyperShift entries, 2026-10-22). Returns whether every write landed.
    func writeFactorySlotSync(_ slot: UInt8, on slotted: OnboardSlotTransport) -> Bool {
        guard let controls = OnboardButtons.layout(pid: slotted.productID) else { return false }
        if slotted.isBluetooth, slotted.slot != slot {
            guard enterSlotSync(slot, on: slotted) else { return false }
        }
        let active = slotted.slot
        // Pointed at the slot for these writes only; it isn't made active.
        slotted.slot = slot
        defer { slotted.slot = active }
        var ok = true
        for report in OnboardSlots.factorySettings(pid: slotted.productID) {
            ok = (try? slotted.sendWithRetry(report)) != nil && ok
        }
        for control in controls {
            let id = control.tableID
            if (try? slotted.readButtonBlock(id)) != control.factory {
                ok = (try? slotted.writeButtonBlock(id, block: control.factory)) != nil && ok
            }
            // An unset HyperShift entry already does the factory function.
            if let shifted = (try? slotted.readShiftedBlock(id)) ?? nil, shifted != control.factory {
                ok = (try? slotted.writeShiftedBlock(id, block: control.factory)) != nil && ok
            }
        }
        if let serial = knownSerial?.serial {
            let key = OnboardSlots.ownershipKey(serial: serial, slot: slot)
            onboardOwnership.set([:], serial: key)
            onboardOwnership.set([:], serial: OnboardOwnership.shiftedKey(serial: key))
        }
        if slot == active { followSlotSync() }
        return ok
    }

    /// io-queue only. Reads which slots exist and which is active, and points the link at
    /// the active one. Nil on mice without slots, or when the mouse doesn't answer.
    func readOnboardSlotsSync(_ d: any RazerTransport) -> UInt8? {
        guard let slotted = d as? OnboardSlotTransport,
              let slots = (try? slotted.base.sendWithRetry(OnboardSlots.listSlots())).flatMap(OnboardSlots.parseSlots),
              let active = (try? slotted.base.sendWithRetry(OnboardSlots.getActive())).flatMap(OnboardSlots.parseActive)
        else { return nil }
        existingSlots = slots
        slotted.slot = active
        slotsReadOn = ObjectIdentifier(slotted)
        return active
    }

    /// io-queue only. Makes `slot` the active one, creating it first when it doesn't exist
    /// yet. A new slot is given the wheel settings the mouse has now, since the profile
    /// doesn't carry them, and Serpentine takes over its button table. Returns whether the
    /// mouse is on `slot` afterwards.
    func activateSlotSync(_ slot: UInt8, on slotted: OnboardSlotTransport) -> Bool {
        if slotted.slot == slot { return true }
        let created = !existingSlots.contains(slot)
        var wheel: [RazerReport] = []
        if created {
            // Read from the slot that is active now, before switching away from it.
            if let mode = try? slotted.sendWithRetry(RazerCommands.getWheelMode()).arguments[1] {
                wheel.append(RazerCommands.setWheelMode(mode))
            }
            if let reel = try? slotted.sendWithRetry(RazerCommands.getScrollSmartReel()).arguments[1] {
                wheel.append(RazerCommands.setScrollSmartReel(reel != 0))
            }
            if RazerDevices.hasSmartReelSensitivity(pid: slotted.productID),
               let level = (try? slotted.sendWithRetry(RazerCommands.getSmartReelSensitivity()))
                   .flatMap(RazerCommands.parseWheelLevel) {
                wheel.append(RazerCommands.setSmartReelSensitivity(level))
            }
            if RazerDevices.hasScrollAcceleration(pid: slotted.productID) {
                if let on = try? slotted.sendWithRetry(RazerCommands.getScrollAcceleration()).arguments[1] {
                    wheel.append(RazerCommands.setScrollAcceleration(on != 0))
                }
                if let level = (try? slotted.sendWithRetry(RazerCommands.getScrollAccelerationLevel()))
                    .flatMap(RazerCommands.parseWheelLevel) {
                    wheel.append(RazerCommands.setScrollAccelerationLevel(level))
                }
            }
            guard (try? slotted.base.sendWithRetry(OnboardSlots.create(slot))) != nil else { return false }
            existingSlots.insert(slot)
        }
        guard (try? slotted.base.sendWithRetry(OnboardSlots.activate(slot))) != nil else { return false }
        slotted.slot = slot
        onboardConfirmed = nil
        // Serpentine switched slot to apply a profile: the profile's remaps go in, rather than
        // the slot's being read back over them.
        if let serial = knownSerial?.serial {
            onboardReadFrom = (OnboardSlots.ownershipKey(serial: serial, slot: slot), slotted.locationID)
        }
        if created {
            for report in wheel { _ = try? slotted.sendWithRetry(report) }
            adoptButtonTableSync(slotted, slot: slot)
        }
        return true
    }

    /// io-queue only. A slot Serpentine just created is its own, whatever it held from before
    /// (a removed slot keeps its old settings), so every entry in it may be put back.
    func adoptButtonTableSync(_ slotted: OnboardSlotTransport, slot: UInt8) {
        guard let serial = knownSerial?.serial, let controls = OnboardButtons.layout(pid: slotted.productID) else { return }
        let key = OnboardSlots.ownershipKey(serial: serial, slot: slot)
        var owned: [UInt8: Set<[UInt8]>] = [:]
        var shifted: [UInt8: Set<[UInt8]>] = [:]
        for control in controls {
            let id = control.tableID
            if let block = try? slotted.readButtonBlock(id) { owned[id] = [block] }
            if let block = (try? slotted.readShiftedBlock(id)) ?? nil { shifted[id] = [block] }
        }
        onboardOwnership.set(owned, serial: key)
        onboardOwnership.set(shifted, serial: OnboardOwnership.shiftedKey(serial: key))
    }

    /// Main thread. The mouse is on `slot`: the profile kept there is the active one.
    func followActiveSlot(_ slot: Int) {
        guard !usesSlotProfiles, let profile = profiles.first(where: { $0.onboardSlot == slot }),
              profile.id != activeProfileID, let key = profilesStorageKey else { return }
        activeProfileID = profile.id
        ProfileStore.setActiveProfileID(profile.id, forDevice: key)
        // Zoned mice are read back on the next refresh (`zonesReadFor` follows the slot).
        // Others have no lighting read-back, so the app takes the profile's word for it.
        if deviceHasLighting, !profile.effect.isEmpty, lightingZones.isEmpty {
            effect = profile.lightingEffect
            lightingColor = profile.color
        }
        onSlotProfileFollowed?(profile)
    }

    /// io-queue only. Notices the mouse moving to another slot by itself (a Cycle Profile
    /// button) and points the link there, following it (`followSlotSync`). Also reads the
    /// slots on a link they couldn't be read on as it opened.
    func checkActiveSlotSync() {
        guard let slotted = device as? OnboardSlotTransport, !userWorkPending else { return }
        if slotsReadOn != ObjectIdentifier(slotted) {
            // Not read when this link opened: read them now, and the mouse's profiles appear.
            guard let active = readOnboardSlotsSync(slotted) else { return }
            followSlotSync()
            publish {
                self.update(\.activeOnboardSlot, Int(active))
                self.refreshSettings()
            }
            return
        }
        guard let active = (try? slotted.base.sendWithRetry(OnboardSlots.getActive())).flatMap(OnboardSlots.parseActive),
              active != slotted.slot else { return }
        slotted.slot = active
        existingSlots.insert(active)
        // Its remaps and settings come from the mouse (`followSlotSync`).
        followSlotSync()
        publish {
            self.update(\.activeOnboardSlot, Int(active))
            self.refreshSettings()
        }
    }
}
