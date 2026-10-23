// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation
import AppKit
import CoreBluetooth
import RazerProtocol
import RazerDeviceKit

// MARK: - Connection

/// Opening the link, choosing between USB and Bluetooth, and the device key.
extension MouseController {
    /// io-queue only. Decides what a failed battery read does to the open handle.
    ///
    /// A timeout is the dongle answering for a mouse that didn't: asleep, switched off, out of
    /// range. The handle is fine, and keeping it spares a re-enumerate, reopen and serial read
    /// on every poll until the mouse is back. It is kept only once the serial is known,
    /// though: while it isn't, reopening is how it gets asked for again when the mouse wakes,
    /// and without that the session's history would stay under the PID fallback key.
    ///
    /// Replies that make no sense drop the handle, so the next poll starts clean. Anything at
    /// the USB level (the device gone, a failed transfer, a failed open) also forgets the
    /// serial, because the thing on that interface may no longer be the same mouse.
    func releaseDeviceIfNeeded(after error: Error) {
        let serialKnown = device.map { d in
            knownSerial.map { $0.locationID == d.locationID && $0.pid == d.productID } ?? false
        } ?? false
        let onDongle = device.map {
            !$0.isBluetooth && RazerDevices.connection(pid: $0.productID) == .wirelessDongle
        } ?? false
        let keep = Self.keepsHandleOnTimeout(
            serialKnown: serialKnown, onDongle: onDongle,
            // Only asked when it matters: an IOHID enumeration per failed poll otherwise.
            bluetoothControllable: { HIDDevice.bluetoothRazerMouse()?.controllablePID != nil })
        switch error {
        case HIDDevice.HIDError.timeout where keep:
            return
        case HIDDevice.HIDError.timeout, HIDDevice.HIDError.badResponse:
            break
        default:
            knownSerial = nil
        }
        device?.close() // release the user client now rather than at CF-dealloc time
        device = nil    // drop the handle so we reopen next tick
        onboardConfirmed = nil // a reopened mouse may have been changed elsewhere
        onboardReadFrom = nil
    }

    /// Whether a timeout keeps the open handle (see `releaseDeviceIfNeeded`). Not when the
    /// handle is a dongle and the mouse has turned up on Bluetooth: it is on one wireless
    /// link at a time, so the dongle will keep timing out, and only a reopen
    /// (`openTransport`) moves over to it.
    static func keepsHandleOnTimeout(serialKnown: Bool, onDongle: Bool,
                                     bluetoothControllable: () -> Bool) -> Bool {
        serialKnown && !(onDongle && bluetoothControllable())
    }

    /// Whether to skip the USB device for the Bluetooth one. A cable wins: it carries
    /// everything, Bluetooth only part of it. A dongle doesn't: it stays plugged in and
    /// enumerating whatever mode the mouse is in, and a mouse macOS has on Bluetooth has
    /// nothing behind the dongle (picking it timed out on every poll on the Cobra HyperSpeed).
    static func prefersBluetooth(over usb: RazerConnection?, bluetoothControllable: Bool) -> Bool {
        bluetoothControllable && usb == .wirelessDongle
    }

    /// Must be called on `io`. Picks the link to talk to the mouse over (`prefersBluetooth`).
    func openTransport() throws -> any RazerTransport {
        let bt = HIDDevice.bluetoothRazerMouse().flatMap { m in m.controllablePID.map { (pid: $0, name: m.name) } }
        var usbError: Error?
        do {
            // Decided before opening, so an idle dongle isn't opened and closed on every poll.
            let usb = try HIDDevice.controlInterface(vendorId: Razer.vendorId) // any Razer mouse
            let connection = RazerDevices.connection(pid: HIDDevice.productID(of: usb))
            if !Self.prefersBluetooth(over: connection, bluetoothControllable: bt != nil) {
                let hid = try HIDDevice.open(usb)
                return RazerDevices.hasOnboardSlots(pid: hid.productID) ? OnboardSlotTransport(hid) : hid
            }
        } catch {
            // Whatever stopped USB (nothing there, or Input Monitoring not granted, which
            // Bluetooth doesn't need) still leaves a Bluetooth mouse to try.
            guard bt != nil else { throw error }
            usbError = error
        }
        guard let bt else { throw HIDDevice.HIDError.notFound }
        // If Bluetooth fails too, report the USB problem when there was a real one: its
        // error text is what drives the Input Monitoring hint.
        var reportable = usbError
        if case .notFound? = usbError as? HIDDevice.HIDError { reportable = nil }
        // A slow failure (CoreBluetooth timeouts) blocks `io` for seconds, so it isn't
        // retried on every poll. A fast one, like a mouse that just went to sleep, is cheap
        // and retried normally, so it reconnects as soon as it wakes.
        if Self.shouldSkipBluetoothRetry(lastFailure: bluetoothOpenFailedAt, now: Date(),
                                         bypassCooldown: bypassBluetoothRetryCooldown) {
            throw reportable ?? HIDDevice.HIDError.notFound
        }
        let started = Date()
        // The first open is what shows the Bluetooth permission prompt, and Bluetooth stays
        // "unknown" while it's up, so that open times out. That isn't a failure to back off
        // from: the user may click Allow a second later.
        let askingPermission = CBManager.authorization == .notDetermined
        do {
            let device = try BluetoothDevice.open(pid: bt.pid, hidName: bt.name)
            bluetoothOpenFailedAt = nil
            return RazerDevices.hasOnboardSlots(pid: device.productID) ? OnboardSlotTransport(device) : device
        } catch {
            if !bypassBluetoothRetryCooldown, !askingPermission,
               Date().timeIntervalSince(started) > 1 { bluetoothOpenFailedAt = Date() }
            throw reportable ?? error
        }
    }

    /// Must be called on `io`.
    func ensureDevice() throws -> any RazerTransport {
        if let d = device { return d }
        let d = try openTransport()
        device = d
        onboardReadFrom = nil // read the remaps back from what may be another mouse, or a changed one
        let pid = d.productID
        battery.useCurveModel(pid: pid)
        // Per-unit key: the device's serial number if it reports one, else the PID. Lets two
        // mice of the same model keep separate settings. If the serial probe fails on a
        // reconnect (the wireless link is already known to be flaky) but we already have a
        // serial-keyed history for this session, keep using it instead of falling back to the
        // PID key — that fallback would fragment one mouse's history across two files on every
        // transient serial-read failure rather than just on a genuine device change.
        let serial: String?
        if let known = knownSerial, known.locationID == d.locationID, known.pid == pid {
            serial = known.serial
        } else {
            serial = (try? d.sendWithRetry(RazerCommands.getSerial())).flatMap { RazerCommands.parseSerial($0) }
            if let serial { knownSerial = (d.locationID, pid, serial) }
        }
        let key = serial ?? battery.deviceKey ?? String(format: "%04x", pid)
        // Switch to this mouse's own battery history (per-device file + learned rate).
        if key != battery.deviceKey {
            let switched = battery.switchDevice(to: key, serial: serial, pid: pid,
                                                migrate: Self.migratePerDeviceData(from:to:))
            let isSameUnitKeyUpgrade = switched.isSameUnitKeyUpgrade
            let savedSnapshotForKey = switched.restoredSnapshot
            let restoredEstimate = switched.restoredEstimate
            // A charging debounce pending for the previous mouse must not auto-confirm the new
            // one's first read — that's exactly the unverified-first-read case the debounce
            // exists to guard.
            pollState.deviceChanged()
            // Republish everything derived from history immediately so the usage graph doesn't
            // keep showing the previous mouse's curve until the next poll tick.
            let snap = battery.display
            let (cycles, avg) = battery.cycles
            let loadedProfiles = ProfileStore.profiles(forDevice: key)
            let loadedActiveID = ProfileStore.activeProfileID(forDevice: key)
            let loadedSlotNames = SlotNames.names(forDevice: key, carrying: loadedProfiles)
            publish {
                if self.lastBatterySnapshot?.deviceKey != key {
                    self.update(\.lastBatterySnapshot, savedSnapshotForKey)
                    self.update(\.batteryPercent, savedSnapshotForKey?.percent)
                    self.update(\.timeEstimate, restoredEstimate)
                }
                self.batterySamples = snap.samples
                self.previousCycleSamples = snap.previous
                self.dischargeRatePerHour = snap.rate
                self.cycleStartedAt = snap.cycleStart
                self.cycleStartedPercent = snap.cycleStartPercent
                self.pastCycles = cycles
                self.averageCycleHours = avg
                self.profiles = loadedProfiles
                self.activeProfileID = loadedActiveID
                self.slotNames = loadedSlotNames
                self.profilesLoadedForKey = key
                // A genuinely different physical mouse — re-arm so it gets its own alert
                // instead of inheriting the previous one's "already notified" state. Skipped
                // for the same-unit PID→serial rename above, which would otherwise let one
                // mouse alert twice in a single discharge. Done here on the main queue (not
                // from the io-queue caller) because that's where `notify()` runs — the two
                // must not race on the policy.
                if !isSameUnitKeyUpgrade { self.lowBatteryNotifier.deviceChanged() }
            }
        }
        let name = d.productName
        let battery = RazerDevices.hasBattery(pid: pid)
        let bluetooth = d.isBluetooth
        ioHasBattery = battery
        slotsReadOn = nil
        let slot = readOnboardSlotsSync(d)
        publish {
            self.update(\.activeOnboardSlot, slot.map(Int.init))
            if let slot { self.followActiveSlot(Int(slot)) }
            self.update(\.deviceIsBluetooth, bluetooth)
            self.update(\.deviceID, pid)
            self.update(\.deviceKey, key)
            self.update(\.deviceName, name)
            self.update(\.deviceSupported, RazerDevices.fullySupported(pid: pid))
            self.update(\.deviceHasBattery, battery)
            self.update(\.deviceHasLighting, RazerDevices.hasLighting(pid: pid))
            self.update(\.deviceMaxDPI, RazerDevices.maxDPI(pid: pid))
        }
        return d
    }

    /// Moves every per-device store from one key to another — files and UserDefaults —
    /// filling holes only (existing destination data is never overwritten). The key
    /// patterns mirror their owners (BatteryHistory, ChargeCycleHistory, ProfileStore,
    /// ButtonRemapper, PopoverView's custom DPI).
    static func migratePerDeviceData(from old: String, to new: String) {
        let fm = FileManager.default
        let dir = StoreDirectory.default
        for prefix in ["battery-history-", "charge-cycles-"] {
            let src = dir.appendingPathComponent("\(prefix)\(old).json")
            let dst = dir.appendingPathComponent("\(prefix)\(new).json")
            if fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) {
                try? fm.moveItem(at: src, to: dst)
            }
        }
        let defaults = UserDefaults.standard
        for prefix in Preferences.Device.migratedPrefixes {
            let srcKey = "\(prefix)\(old)", dstKey = "\(prefix)\(new)"
            if let value = defaults.object(forKey: srcKey), defaults.object(forKey: dstKey) == nil {
                defaults.set(value, forKey: dstKey)
                defaults.removeObject(forKey: srcKey)
            }
        }
        // Profiles get MERGED, not hole-filled: a returning user's serial key usually
        // already has profiles, and one saved minutes ago (under the PID fallback, before
        // the serial resolved) disappearing on reconnect reads as data loss. IDs are
        // unique, so appending the missing ones is safe. The active id travels only with
        // its profile — migrating it alone would persist a dangling id that no chip shows
        // and the drift check can never clear.
        let sourceProfiles = ProfileStore.profiles(forDevice: old)
        if !sourceProfiles.isEmpty {
            var destination = ProfileStore.profiles(forDevice: new)
            let existing = Set(destination.map(\.id))
            destination.append(contentsOf: sourceProfiles.filter { !existing.contains($0.id) })
            ProfileStore.save(destination, forDevice: new)
            if ProfileStore.activeProfileID(forDevice: new) == nil,
               let active = ProfileStore.activeProfileID(forDevice: old),
               destination.contains(where: { $0.id == active }) {
                ProfileStore.setActiveProfileID(active, forDevice: new)
            }
        }
        ProfileStore.removeStorage(forDevice: old)
    }
}
