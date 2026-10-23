// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation
import AppKit
import CoreBluetooth
import RazerProtocol
import RazerDeviceKit

// MARK: - Profiles

/// Saved profiles, and the profiles kept in the mouse's slots.
extension MouseController {
    func clearActiveProfileIfNeeded() {
        guard !usesSlotProfiles, activeProfileID != nil else { return }
        activeProfileID = nil
        if let key = profilesStorageKey { ProfileStore.setActiveProfileID(nil, forDevice: key) }
    }

    /// Called by `ButtonRemapper.onManualChange` — a remap edit made outside `applyProfile`
    /// means the live config no longer matches the active profile.
    func clearActiveProfileIfManuallyChanged() { clearActiveProfileIfNeeded() }

    /// Where the currently-displayed `profiles` are persisted. Falls back to the key they
    /// were loaded under when `deviceKey` clears on a dongle unplug — rename/delete are pure
    /// app-side operations on a list the user can still see, and silently ignoring them
    /// (the field snapping back, the confirmed delete not deleting) reads as broken.
    var profilesStorageKey: String? { deviceKey ?? profilesLoadedForKey }

    /// Captures the current live DPI/poll/brightness/lighting + the remapper's button mappings
    /// as a new named profile for the connected mouse.
    func saveCurrentAsProfile(name: String, remapper: ButtonRemapper) {
        // dpi == 0 means the settings read hasn't succeeded yet — snapshotting it would
        // save a profile that later applies as 100 DPI (the protocol clamp floor). The
        // "+" chip is disabled in that state; this guard is the belt to its braces.
        guard let key = deviceKey, dpi != 0 else { return }
        var profile = MouseProfile(name: name, dpi: dpi, pollRate: pollRate == 0 ? 1000 : pollRate,
                                    brightness: brightness,
                                    // No LEDs → no effect captured (the picker isn't even
                                    // shown); an empty string keeps the summary honest.
                                    effect: deviceHasLighting ? effect.rawValue : "",
                                    color: lightingColor,
                                    buttonMappings: remapper.mappings,
                                    // The stage table the DPI button cycles is config too.
                                    dpiStages: dpiStages.isEmpty ? nil : dpiStages)
        // It is what the active slot holds now, so it is kept there unless another profile is.
        if supportsOnboardSlots, let slot = activeOnboardSlot, !profiles.contains(where: { $0.onboardSlot == slot }) {
            profile.onboardSlot = slot
        }
        if !zoneLighting.isEmpty {
            profile.zones = Dictionary(uniqueKeysWithValues: zoneLighting.map { ($0.key.storageKey, $0.value) })
            // The whole-mouse fields follow the logo, which is what a refresh compares.
            if let logo = zoneLighting[.logo] {
                profile.brightness = logo.brightness
                profile.effect = logo.effect
                profile.color = logo.color
            }
        }
        profiles.append(profile)
        ProfileStore.save(profiles, forDevice: key)
        activeProfileID = profile.id
        ProfileStore.setActiveProfileID(profile.id, forDevice: key)
    }

    /// Applies a saved profile's DPI/poll/brightness/lighting and button remaps to the live
    /// mouse. Sends directly on `io` rather than through the public setters: those un-mark
    /// the active profile on every manual change, and publish per-value — whereas an apply
    /// is all-or-nothing: every part (including the software-side button remaps) lands only
    /// when the device took the whole config, so a failed apply changes nothing.
    func applyProfile(_ profile: MouseProfile, remapper: ButtonRemapper) {
        guard let key = deviceKey else {
            profileApplyFailed = true
            return
        }
        profileApplyFailed = false

        let dpi = UInt16(max(100, min(profile.dpi, RazerCommands.dpiCeiling)))
        let hz = profile.pollRate == 0 ? 1000 : profile.pollRate
        let brightnessPct = max(0, min(profile.brightness, 100))
        let effect = profile.lightingEffect
        let lighting = report(for: effect, color: profile.color)
        let color = profile.color
        let mappings = profile.buttonMappings
        // Restore the onboard stage table (what the DPI button cycles) when the profile
        // captured one, marking the stage matching the profile's DPI active. Written before
        // the explicit DPI set so the current DPI always ends up as the profile says.
        // Clamped exactly like the wire command clamps, so what gets published (and what a
        // later "+" re-snapshots) is what the device actually stored.
        let stages = (profile.dpiStages ?? []).prefix(RazerCommands.maxDPIStages)
            .map { max(100, min($0, RazerCommands.dpiCeiling)) }
        let stagesReport = stages.isEmpty ? nil
            : RazerCommands.setDPIStages(stages, activeStage: stages.firstIndex(of: profile.dpi) ?? 0,
                                         countFromOne: deviceID.map(RazerDevices.dpiStagesCountFromOne(pid:)) ?? false)
        // On a mouse with onboard slots the profile goes in its own slot, which is made
        // active first, so every write below lands there (`OnboardSlots`).
        let assigned = Dictionary(uniqueKeysWithValues: profiles.compactMap { p in p.onboardSlot.map { (p.id, $0) } })
        let slot = supportsOnboardSlots ? activeOnboardSlot.flatMap {
            OnboardSlots.slot(for: profile.id, assigned: assigned, active: $0)
        } : nil
        // Zoned mice get each zone's lighting, or the profile's one lighting in every zone
        // when it was saved before zones (`ZonedLighting`).
        let zoneTargets: [LightingZone: ZoneLighting] = Dictionary(uniqueKeysWithValues: lightingZones.map { zone in
            (zone, profile.zones?[zone.storageKey]
                ?? ZoneLighting(effect: effect, color: color, brightness: brightnessPct))
        })

        io.user { [weak self] in
            guard let self else { return }
            guard let dev = try? self.ensureDevice() else {
                self.publish { self.lastWriteFailure = Date(); self.profileApplyFailed = true }
                return
            }
            if let slot, let slotted = dev as? OnboardSlotTransport {
                let switched = self.activateSlotSync(UInt8(slot), on: slotted)
                let now = Int(slotted.slot)
                self.publish { self.update(\.activeOnboardSlot, now) }
                guard switched else {
                    self.publish { self.lastWriteFailure = Date(); self.profileApplyFailed = true }
                    return
                }
                // The remapper hands this profile's remaps over once the apply lands; until
                // then a poll must not write the previous profile's into the new slot.
                if let handed = self.onboardMappings { self.onboardMappings = (handed.deviceKey, mappings) }
            }
            let stagesOK = stagesReport.map { (try? dev.sendWithRetry($0)) != nil } ?? true
            let dpiOK = (try? dev.sendWithRetry(RazerCommands.setDPI(x: dpi, y: dpi))) != nil
            // Over Bluetooth only a profile kept in a slot gets here, and its slot already
            // holds the polling rate Bluetooth has no command for.
            let slotKeepsRest = dev.isBluetooth && slot != nil
            let pollOK = slotKeepsRest || Self.sendPollingRate(hz, to: dev)
            // Lighting commands only count on models that have lighting — the Atheris
            // (correctly) refuses them, and that must not block its profiles from applying.
            let hasLighting = RazerDevices.hasLighting(pid: dev.productID)
            var zonesWritten = true
            for (zone, lit) in zoneTargets {
                let effectOK = (try? dev.sendWithRetry(ZonedLighting.setEffect(lit.lightingEffect, color: lit.color, zone: zone))) != nil
                let brightnessOK = (try? dev.sendWithRetry(RazerCommands.setBrightness(
                    RazerCommands.brightnessRaw(fromPercent: lit.brightness), led: zone.rawValue))) != nil
                zonesWritten = zonesWritten && effectOK && brightnessOK
            }
            let zonesOK = zonesWritten
            if !zoneTargets.isEmpty { self.zonesReadFor = nil }
            let brightOK = !hasLighting || !zoneTargets.isEmpty
                || (try? dev.sendWithRetry(RazerCommands.setBrightness(
                        RazerCommands.brightnessRaw(fromPercent: brightnessPct),
                        led: RazerDevices.brightnessLed(pid: dev.productID)))) != nil
            let lightOK = !hasLighting || (zoneTargets.isEmpty
                ? slotKeepsRest || (try? dev.sendWithRetry(lighting)) != nil
                : zonesOK)
            let allOK = stagesOK && dpiOK && pollOK && brightOK && lightOK
            let anyOK = dpiOK || pollOK || (hasLighting && (brightOK || lightOK))
                || (stagesReport != nil && stagesOK)
            self.publish {
                if stagesOK, !stages.isEmpty {
                    self.dpiStages = stages
                    self.activeDpiStage = stages.firstIndex(of: Int(dpi)) ?? 0
                }
                if dpiOK { self.dpi = Int(dpi) }
                if pollOK, !slotKeepsRest { self.pollRate = hz }
                if !zoneTargets.isEmpty, zonesOK { self.showZoneLighting(zoneTargets) }
                else if hasLighting && brightOK { self.brightness = brightnessPct }
                // The contains-check covers a profile deleted while the writes were in
                // flight — marking it active would persist a dangling id.
                if allOK, self.profiles.contains(where: { $0.id == profile.id }) {
                    remapper.setMappings(mappings)
                    if hasLighting, zoneTargets.isEmpty {
                        self.effect = effect
                        self.lightingColor = color
                    }
                    self.activeProfileID = profile.id
                    ProfileStore.setActiveProfileID(profile.id, forDevice: key)
                    if let slot, let i = self.profiles.firstIndex(where: { $0.id == profile.id }),
                       self.profiles[i].onboardSlot != slot {
                        self.profiles[i].onboardSlot = slot
                        ProfileStore.save(self.profiles, forDevice: key)
                    }
                } else {
                    // Partial/failed apply: don't claim the profile is active, surface the
                    // failure, and let the UI snap optimistic state back to reality. A
                    // partial apply also invalidates whatever profile WAS active — the
                    // config is now a hybrid that matches neither.
                    self.lastWriteFailure = Date()
                    self.profileApplyFailed = true
                    if anyOK { self.clearActiveProfileIfNeeded() }
                }
            }
        }
    }

    /// Makes a slot the active profile. Its remaps and settings are read back from the mouse.
    func switchToSlot(_ slot: Int) {
        guard usesSlotProfiles, slot != activeOnboardSlot else { return }
        slotCommand { slotted in self.enterSlotSync(UInt8(slot), on: slotted) }
    }

    /// Adds a profile in the next free slot, as it comes from the factory, and makes it the
    /// active one.
    func addSlotProfile(name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard usesSlotProfiles, !name.isEmpty, let key = profilesStorageKey,
              let slot = OnboardSlots.nextFreeSlot(existing: Set(onboardSlotList)) else { return }
        slotNames[slot] = name
        SlotNames.save(slotNames, forDevice: key)
        slotCommand { slotted in
            guard (try? slotted.base.sendWithRetry(OnboardSlots.create(UInt8(slot)))) != nil else { return false }
            self.existingSlots.insert(UInt8(slot))
            // A removed slot keeps what it held, so a new one is written back to factory, once
            // it is active: over Bluetooth that is the only slot the table reads come from.
            guard self.enterSlotSync(UInt8(slot), on: slotted) else { return false }
            let factory = self.writeFactorySlotSync(UInt8(slot), on: slotted)
            self.syncOnboardButtonsSync()
            return factory
        }
    }

    /// Puts a profile back to how its slot came from the factory, active or not.
    func resetSlotProfile(_ slot: Int) {
        guard usesSlotProfiles else { return }
        slotCommand { slotted in
            let ok = self.writeFactorySlotSync(UInt8(slot), on: slotted)
            if slotted.slot == UInt8(slot) { self.syncOnboardButtonsSync() }
            return ok
        }
    }

    /// Removes a profile and its slot from the mouse; never slot 1, which always exists. When
    /// it was the active one, the mouse goes back to slot 1.
    func deleteSlotProfile(_ slot: Int) {
        guard usesSlotProfiles, slot != Int(OnboardSlots.first), let key = profilesStorageKey else { return }
        slotNames[slot] = nil
        SlotNames.save(slotNames, forDevice: key)
        slotCommand { slotted in
            if slotted.slot == UInt8(slot) {
                guard self.enterSlotSync(OnboardSlots.first, on: slotted) else { return false }
            }
            guard (try? slotted.base.sendWithRetry(OnboardSlots.remove(UInt8(slot)))) != nil else { return false }
            self.existingSlots.remove(UInt8(slot))
            if let serial = self.knownSerial?.serial {
                let owned = OnboardSlots.ownershipKey(serial: serial, slot: UInt8(slot))
                self.onboardOwnership.set([:], serial: owned)
                self.onboardOwnership.set([:], serial: OnboardOwnership.shiftedKey(serial: owned))
            }
            return true
        }
    }

    func renameSlotProfile(_ slot: Int, to newName: String) {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let key = profilesStorageKey else { return }
        slotNames[slot] = name
        SlotNames.save(slotNames, forDevice: key)
    }

    /// Runs a slot change on the io queue, then publishes the slot the mouse is on and
    /// re-reads its settings, then its button table, each queued after the other: a read
    /// inside a user command stands down for it (`userWorkPending`). `body` returns whether
    /// it fully landed.
    func slotCommand(_ body: @escaping @Sendable (OnboardSlotTransport) -> Bool) {
        profileApplyFailed = false
        io.user { [weak self] in
            guard let self else { return }
            guard let slotted = (try? self.ensureDevice()) as? OnboardSlotTransport else {
                self.publish { self.lastWriteFailure = Date(); self.profileApplyFailed = true }
                return
            }
            let ok = body(slotted)
            let now = Int(slotted.slot)
            self.publish {
                self.update(\.activeOnboardSlot, now)
                if !ok { self.lastWriteFailure = Date(); self.profileApplyFailed = true }
                self.refreshSettings()
                self.io.async { [weak self] in self?.syncOnboardButtonsSync() }
            }
        }
    }

    func renameProfile(_ id: UUID, to newName: String) {
        // Same trim-and-reject-empty rule as profile creation — a whitespace-only commit
        // would leave a blank, unclickable-looking chip on the main page.
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let key = profilesStorageKey,
              let idx = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[idx].name = name
        ProfileStore.save(profiles, forDevice: key)
    }

    func deleteProfile(_ id: UUID, remapper: ButtonRemapper) {
        guard let key = profilesStorageKey else { return }
        // Its slot is removed from the mouse too (never slot 1, which always exists). When
        // it was the active one the mouse goes back to slot 1, and the profile kept there, if
        // any, is applied so the app and its remaps follow.
        if let slot = profiles.first(where: { $0.id == id })?.onboardSlot, slot != Int(OnboardSlots.first),
           supportsOnboardSlots {
            let fallback = profiles.first { $0.onboardSlot == Int(OnboardSlots.first) }
            io.user { [weak self] in
                guard let self, let slotted = (try? self.ensureDevice()) as? OnboardSlotTransport else { return }
                let wasActive = slotted.slot == UInt8(slot)
                if wasActive {
                    guard self.activateSlotSync(OnboardSlots.first, on: slotted) else { return }
                }
                if (try? slotted.base.sendWithRetry(OnboardSlots.remove(UInt8(slot)))) != nil {
                    self.existingSlots.remove(UInt8(slot))
                }
                let now = Int(slotted.slot)
                self.publish {
                    self.update(\.activeOnboardSlot, now)
                    guard wasActive else { return }
                    if let fallback, self.connected { self.applyProfile(fallback, remapper: remapper) }
                    self.refreshSettings()
                }
            }
        }
        profiles.removeAll { $0.id == id }
        ProfileStore.save(profiles, forDevice: key)
        if activeProfileID == id {
            activeProfileID = nil
            ProfileStore.setActiveProfileID(nil, forDevice: key)
        }
    }
}
