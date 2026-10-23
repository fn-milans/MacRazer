// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation
import AppKit
import CoreBluetooth
import RazerProtocol
import RazerDeviceKit

// MARK: - Polling and reads

/// The poll loop, the battery and settings reads, and the checks that follow the mouse.
extension MouseController {
    /// Settings (DPI + polling) only — no spinner. Call on the main thread.
    func refreshSettings() {
        guard !settingsReadQueued else { return }
        settingsReadQueued = true
        io.async { [weak self] in
            guard let self else { return }
            self.readSettingsSync()
            self.publish { self.settingsReadQueued = false }
        }
    }

    /// Main thread. The popover's 2-second check (`checkLiveSync`).
    func checkLive() {
        guard !liveCheckQueued, !settingsReadQueued else { return }
        liveCheckQueued = true
        io.async { [weak self] in
            guard let self else { return }
            self.checkLiveSync()
            self.publish { self.liveCheckQueued = false }
        }
    }

    /// io-queue only. Reads the two things a button on the mouse changes: the active slot
    /// (`checkActiveSlotSync`, which re-reads everything when it moved) and the DPI. Only
    /// when the DPI differs from the last full read does that read run again; otherwise
    /// this is two commands, where a full read is a dozen.
    func checkLiveSync() {
        guard let dev = device, !userWorkPending else { return }
        let slot = (dev as? OnboardSlotTransport)?.slot
        checkActiveSlotSync()
        guard (dev as? OnboardSlotTransport)?.slot == slot, !userWorkPending else { return }
        let tableDriven = dev.isBluetooth || RazerDevices.supportsDpiModes(pid: dev.productID)
        let now: [Int]?
        if tableDriven {
            now = (try? dev.sendWithRetry(RazerCommands.getDPIStages())).map { r in
                let stages = RazerCommands.parseDPIStages(r)
                let active = RazerCommands.parseActiveDPIStage(r, countFromOne: RazerDevices.dpiStagesCountFromOne(pid: dev.productID))
                return [stages.indices.contains(active) ? active : -1] + stages
            }
        } else {
            now = (try? dev.sendWithRetry(RazerCommands.getDPI())).map { [Int(RazerCommands.parseDPI($0).x)] }
        }
        guard let now, now != dpiSignature else { return }
        readSettingsSync()
    }

    /// Called as a view of the mouse opens or closes. While one is open what a button on the
    /// mouse changes (the DPI-cycle button, a profile switch) is re-read every couple of
    /// seconds so it shows at once.
    func setLiveChecks(_ on: Bool, for viewer: LiveViewer = .window) {
        let wasActive = !liveViewers.isEmpty
        if on { liveViewers.insert(viewer) } else { liveViewers.remove(viewer) }
        let active = !liveViewers.isEmpty
        if !active {
            settingsTimer?.invalidate()
            settingsTimer = nil
        }
        guard active, !wasActive || on else { return }
        // While the mouse is unreachable the poll backs off, so a mouse woken just before the
        // view opened could otherwise still read offline. Looking is a good moment to check.
        checkIfOffline()
        refreshSettings()
        guard settingsTimer == nil else { return }
        // Only what a button on the mouse changes is checked this often (`checkLiveSync`);
        // everything else is read when the view opens, and again after a change.
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkLive()
        }
        RunLoop.main.add(t, forMode: .common)
        settingsTimer = t
    }

    /// Immediate check triggered by an IOKit plug/unplug event. On a removal we pass
    /// `immediateOffline` so the disconnect shows at once (bypassing the timeout debounce,
    /// since a USB termination is definitive). Also realigns the poll cadence.
    func forceCheck(immediateOffline: Bool) {
        // A plug event is the only way a different unit can turn up on an interface we
        // already know, so the cached serial is no longer evidence of which mouse it is.
        io.async { [weak self] in self?.knownSerial = nil }
        checkNow(immediateOffline: immediateOffline)
    }

    /// Checks at once if the mouse is currently offline, for moments that suggest it may be
    /// back: the popover opening, or a remapped button being pressed. Main thread. Repeated
    /// calls while one check is pending are dropped, so clicking away at a button that isn't
    /// answering can't pile reads up on the serial queue.
    func checkIfOffline() {
        guard !connected, !offlineCheckQueued else { return }
        offlineCheckQueued = true
        io.async { [weak self] in
            guard let self else { return }
            self.readBatterySync()
            let next = self.pollState.nextPollInterval(pointerActive: Self.pointerIsInUse())
            self.publish {
                self.offlineCheckQueued = false
                self.scheduleNextPoll(after: next)
            }
        }
    }

    /// Reads the battery now and realigns the poll cadence to the result.
    func checkNow(immediateOffline: Bool) {
        io.async { [weak self] in
            guard let self else { return }
            self.readBatterySync(immediateOffline: immediateOffline)
            let next = self.pollState.nextPollInterval(pointerActive: Self.pointerIsInUse())
            self.publish { self.scheduleNextPoll(after: next) }
        }
    }

    /// Full refresh (battery + settings) with the spinner — used by the refresh button.
    /// Re-reads DPI/poll so on-mouse changes (e.g. middle-button DPI cycling) show up.
    func refreshAll() {
        publish { self.isRefreshing = true }
        io.async { [weak self] in
            guard let self else { return }
            self.readBatterySync()
            self.readSettingsSync()
            // Keep the spinner visible long enough to read as feedback — but pace it on the
            // main queue, never by sleeping the serial io queue (that would delay any queued
            // device command, e.g. a DPI write right after tapping refresh).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.isRefreshing = false }
        }
    }

    /// Runs on `io`. Performs the HID reads, feeds the outcome to `pollState` (where every
    /// decision rule lives — see `BatteryPollStateMachine`), and acts on the verdict.
    func readBatterySync(immediateOffline: Bool = false) {
        let outcome: BatteryPollStateMachine.ReadOutcome
        var errText: String?
        /// The charging flag as the device reported it this tick, or nil when the charging
        /// read itself failed. The verdict's `isCharging` is the two-poll-*confirmed* one,
        /// which resets on any transient read failure — so a docked mouse looks "not
        /// charging" on the first good poll after one. That's harmless for the history reset
        /// the confirmation guards, but it would fire a false "battery low" while the mouse
        /// sits on the charger, and blink the menu bar bolt off for a whole poll cycle.
        /// Nil is kept distinct from false: the mouse refuses commands around sleep exactly
        /// when it's most likely docked, so "read failed" must not read as "on battery".
        var observedCharging: Bool?
        do {
            let dev = try ensureDevice()
            if !ioHasBattery {
                // Battery-less mice (wired-only): a DPI read is the alive-check; no battery UI.
                do {
                    _ = try dev.sendWithRetry(RazerCommands.getDPI())
                } catch HIDDevice.HIDError.commandFailed, HIDDevice.HIDError.notSupported {
                    // Refused ≠ dead: a failure/not-supported reply proves the link is up,
                    // which is all this check needs (some firmwares may reject this exact
                    // DPI variant while everything else works).
                }
                outcome = .aliveNoBattery
            } else {
                let raw: UInt8
                do {
                    raw = try dev.sendWithRetry(RazerCommands.getBatteryLevel()).arguments[1]
                } catch HIDDevice.HIDError.commandFailed, HIDDevice.HIDError.notSupported {
                    // The device answered — the link is alive — but refused the command
                    // (seen on the HyperSpeed around sleep). Pre-validation builds parsed
                    // these replies as all-zeros; raw 0 keeps taking that grace path
                    // rather than flapping to offline with disconnect sounds.
                    raw = 0
                }
                // Charging status only matters alongside a real battery value — skip it on
                // the raw==0 grace ticks so the fast not-ready poll loop stays one command
                // per tick against an already-fragile (waking/refusing) link. A failed read
                // counts as not-charging. (A garbage-rejected tick still pays for the extra
                // command — bounded at two ticks per episode, not worth pre-empting the
                // state machine's decision here.)
                // raw == 0 is the grace tick (device refused the level read): no charging
                // query is issued, so the state is genuinely unknown rather than false.
                let chargeReply = raw == 0 ? nil : try? dev.sendWithRetry(RazerCommands.getChargingStatus())
                observedCharging = raw == 0 ? nil : chargeReply.map { $0.arguments[1] != 0 }
                let charging = observedCharging ?? false
                outcome = .battery(raw: raw, charging: charging)
            }
            checkActiveSlotSync()
            syncOnboardButtonsSync()
        } catch {
            releaseDeviceIfNeeded(after: error)
            errText = String(describing: error)
            // No Razer mouse present at all (vs. present-but-asleep timeout).
            let gone: Bool = { if case HIDDevice.HIDError.notFound = error { return true }; return false }()
            outcome = .failure(deviceGone: gone)
        }

        switch pollState.handle(outcome, immediateOffline: immediateOffline) {
        case .aliveNoBattery:
            // A battery-less (wired) mouse can't be charging — without this the menu bar
            // bolt survives a swap from a charging wireless mouse and never clears.
            publishConnected {
                self.update(\.batteryPercent, nil)
                self.update(\.charging, false)
            }

        case .notReady:
            // Keep the last known value on screen; the fast poll cadence retries shortly.
            publishConnected {}

        case .reading(let pct, let isCharging, let recordSample):
            let snapshot = battery.record(percent: pct, charging: isCharging, recordSample: recordSample,
                                          productID: device?.productID ?? 0,
                                          deviceName: device?.productName ?? "Razer Mouse")
            let estimate = isCharging ? "Charging" : snapshot.estimateText
            let snap = battery.display
            let chargingNow = observedCharging // immutable capture for the @Sendable publish block
            publishConnected {
                // A real reading proves the mouse is responding again — a stale "couldn't
                // apply" banner would now be lying (polls clear it within ~15s of a wake).
                self.update(\.profileApplyFailed, false)
                self.update(\.batteryPercent, pct)
                if !snapshot.sameDisplayedState(as: self.lastBatterySnapshot) {
                    self.update(\.lastBatterySnapshot, snapshot)
                }
                // Published for display (menu bar bolt, popover badge) off the *observed*
                // flag, not the debounced one: the debounce exists to guard the destructive
                // history reset below, and applying it here blinks the bolt off for a full
                // poll cycle after any transient failure. An unknown read holds the last
                // known state rather than claiming discharge.
                if let chargingNow { self.update(\.charging, chargingNow) }
                self.lowBatteryNotifier.notify(deviceKey: self.deviceKey, deviceName: self.deviceName,
                                               percent: pct, charging: chargingNow)
                self.update(\.timeEstimate, estimate)
                self.update(\.batterySamples, snap.samples)
                self.update(\.previousCycleSamples, snap.previous)
                self.update(\.dischargeRatePerHour, snap.rate)
                self.update(\.cycleStartedAt, snap.cycleStart)
                self.update(\.cycleStartedPercent, snap.cycleStartPercent)
                self.update(\.bluetoothMouse, nil)
            }

        case .pendingOffline:
            FileHandle.standardError.write(Data(
                "[Serpentine] battery read failed (\(pollState.consecutiveFailures)): \(errText ?? "?")\n".utf8))

        case .offline(let gone):
            FileHandle.standardError.write(Data(
                "[Serpentine] battery read failed (\(pollState.consecutiveFailures)): \(errText ?? "?")\n".utf8))
            // Can't reach a Razer mouse — is one sitting on Bluetooth instead?
            let btStatus = HIDDevice.bluetoothRazerMouse().map {
                BluetoothMouseStatus($0, authorization: CBManager.authorization)
            }
            let err = errText
            publish {
                let wasConnected = self.connected
                self.update(\.connected, false)
                // Nothing on the USB side will say when a mouse behind its dongle wakes up,
                // but the mouse itself will, the moment it moves.
                self.inputWatcher.start()
                // An unreachable mouse isn't charging as far as we know — leaving this set
                // strands the menu bar bolt on (dimmed) indefinitely after a disconnect.
                self.update(\.charging, false)
                self.update(\.lastError, err)
                self.update(\.bluetoothMouse, btStatus)
                // The DPI Cycle assignment read before the mouse went away says nothing about
                // what it holds when it comes back (firmware can reset it). Forget it, so the F20
                // bridge stays unconfirmed until it's read again.
                self.update(\.dpiCycleButtonBinding, nil)
                // Same for the sleep timeout: the controls wait for a fresh read.
                self.update(\.sleepTimeout, nil)
                self.update(\.lowBatteryThreshold, nil)
                if gone {
                    self.update(\.deviceName, nil)
                    self.update(\.deviceID, nil)
                    self.update(\.deviceKey, nil)
                    self.update(\.deviceIsBluetooth, false)
                    self.update(\.activeDpiStage, nil)
                }
                self.updateStatusText()
                if self.hasBaseline && wasConnected { self.playSound(connected: false) }
                self.hasBaseline = true
            }
        }
    }

    /// Main-queue publish shared by every "device is reachable" verdict: the connection
    /// flag, error reset, first-baseline and connect-sound handling. `alsoSet` runs inside
    /// the same block, before the status text refresh.
    func publishConnected(alsoSet: @escaping @Sendable () -> Void) {
        publish {
            let wasConnected = self.connected
            self.update(\.connected, true)
            self.update(\.bluetoothRecoveryState, .idle)
            self.update(\.lastError, nil)
            self.inputWatcher.stop() // in use again: its reports would be a wake-up per movement
            alsoSet()
            self.updateStatusText()
            if self.hasBaseline && !wasConnected {
                self.playSound(connected: true)
                // A sleeping BLE mouse may answer the battery probe before its vendor
                // channel is ready. Queue a focused settings pass after the connection
                // state is published so DPI, binding and power controls converge quickly.
                DispatchQueue.main.async { [self] in
                    guard self.capabilities.stageEditingOverBluetooth else { return }
                    self.refreshSettings()
                }
            }
            self.hasBaseline = true
        }
    }

    func playSound(connected: Bool) {
        guard connectionSoundsEnabled else { return }
        playConnectionSound(connected)
    }

    /// Runs on `io`. Per-feature errors (failure/not-supported — e.g. no brightness on the
    /// Atheris) skip just that value, so the others still update; link-level errors
    /// (timeouts, stale reports) abort the remaining reads — grinding three more full retry
    /// ladders against a dead link would occupy the serial queue for seconds and delay any
    /// queued user write. Battery refresh surfaces connection errors; this can fail quietly.
    func readSettingsSync() {
        guard let dev = try? ensureDevice() else { return }
        checkActiveSlotSync()
        var linkDead = false
        func read<T>(_ report: RazerReport, _ parse: (RazerReport) -> T) -> T? {
            // Stand down the moment a tap is waiting. Whatever is skipped here is read again
            // by the next poll, and a stale DPI reading for two seconds costs less than a
            // slider that does nothing for a second.
            guard !linkDead, !self.userWorkPending else { return nil }
            do { return parse(try dev.sendWithRetry(report)) }
            catch HIDDevice.HIDError.commandFailed, HIDDevice.HIDError.notSupported {
                return nil // this feature only — the device answered, keep reading others
            } catch {
                linkDead = true
                return nil
            }
        }
        let stagesReport = read(RazerCommands.getDPIStages()) { $0 }
        let stages = stagesReport.map { RazerCommands.parseDPIStages($0) } ?? []
        // Over Bluetooth the current DPI *is* the active stage: both reads are the same
        // stage-table request (`BLEProtocol`), so take it from the one already made.
        // A mouse with DPI modes (`supportsDpiModes`) is driven by its stage table on every
        // link, so its active stage counts over USB too. Its DPI is still read on its own
        // there: a direct DPI write (earlier builds, other apps) leaves the table alone.
        let tableDriven = dev.isBluetooth || RazerDevices.supportsDpiModes(pid: dev.productID)
        let activeDpiStage: Int? = tableDriven
            ? stagesReport.flatMap { r in
                let active = RazerCommands.parseActiveDPIStage(r, countFromOne: RazerDevices.dpiStagesCountFromOne(pid: dev.productID))
                return stages.indices.contains(active) ? active : nil
            }
            : nil
        let d: Int? = dev.isBluetooth
            ? activeDpiStage.map { stages[$0] }
            : read(RazerCommands.getDPI()) { Int(RazerCommands.parseDPI($0).x) }
        // What the 2-second check compares against (`checkLiveSync`); only a complete read.
        let signature = tableDriven ? (stagesReport == nil ? nil : [activeDpiStage ?? -1] + stages) : d.map { [$0] }
        if !linkDead { dpiSignature = signature }
        // Over Bluetooth the transport maps the classic command; over USB the mouse decides.
        let pollRead = dev.isBluetooth
            ? (report: RazerCommands.getPollingRate(), parse: RazerCommands.parsePollingRate)
            : RazerCommands.pollingRateRead(pid: dev.productID)
        let p = read(pollRead.report, pollRead.parse)
        let b = read(RazerCommands.getBrightness(led: RazerDevices.brightnessLed(pid: dev.productID))) { RazerCommands.brightnessPercent(fromRaw: $0.arguments[2]) }
        let sleep: Int? = {
            if !dev.isBluetooth, RazerDevices.supportsSleepTimeout(pid: dev.productID) {
                return read(RazerCommands.getIdleTime(), RazerCommands.parseIdleTime) ?? nil
            }
            guard RazerDevices.supportsSleepTimeout(pid: dev.productID),
                  let bluetooth = dev.bluetoothDevice,
                  !linkDead, !self.userWorkPending else { return nil }
            do { return try bluetooth.readSleepTimeout() }
            catch HIDDevice.HIDError.timeout { linkDead = true; return nil }
            catch { return nil }
        }()
        let hasWheelControls = dev.capabilities.wheelControls
        let smartReel = hasWheelControls ? read(RazerCommands.getScrollSmartReel()) { $0.arguments[1] != 0 } : nil
        let hasReelSensitivity = dev.capabilities.smartReelSensitivity
        let reelSensitivity = hasReelSensitivity
            ? read(RazerCommands.getSmartReelSensitivity(), RazerCommands.parseWheelLevel) ?? nil : nil
        let hasAcceleration = dev.capabilities.scrollAcceleration
        let acceleration = hasAcceleration ? read(RazerCommands.getScrollAcceleration()) { $0.arguments[1] != 0 } : nil
        let accelerationLevel = hasAcceleration
            ? read(RazerCommands.getScrollAccelerationLevel(), RazerCommands.parseWheelLevel) ?? nil : nil
        let hasLowBattery = dev.capabilities.lowBatteryThreshold
        let lowBattery = hasLowBattery ? read(RazerCommands.getLowBatteryThreshold(), RazerCommands.parseLowBatteryThreshold) : nil
        // Zone lighting changes only through the app or a profile switch, so it is read once
        // per mouse and slot rather than on every refresh.
        let zonesKey = "\(dev.productID)-\(dev.locationID)-\((dev as? OnboardSlotTransport)?.slot ?? 0)"
        var zonesRead: [LightingZone: ZoneLighting]?
        if zonesReadFor != zonesKey, !ZonedLighting.zones(pid: dev.productID).isEmpty {
            var read: [LightingZone: ZoneLighting] = [:]
            for zone in ZonedLighting.zones(pid: dev.productID) {
                guard let lit = readZoneSync(zone, on: dev) else { break }
                read[zone] = lit
            }
            if read.count == ZonedLighting.zones(pid: dev.productID).count {
                zonesRead = read
                zonesReadFor = zonesKey
            }
        }
        let zones = zonesRead
        let zoned = !ZonedLighting.zones(pid: dev.productID).isEmpty
        publish {
            if let zones { self.showZoneLighting(zones) } else if !zoned { self.update(\.zoneLighting, [:]) }
            if let lowBattery { self.update(\.lowBatteryThreshold, lowBattery) } else if !hasLowBattery { self.update(\.lowBatteryThreshold, nil) }
            // A skipped read keeps the last value, so the switch doesn't blink out of the window.
            if let smartReel { self.update(\.smartReel, smartReel) } else if !hasWheelControls { self.update(\.smartReel, nil) }
            if let reelSensitivity {
                self.update(\.smartReelSensitivity, reelSensitivity)
            } else if !hasReelSensitivity {
                self.update(\.smartReelSensitivity, nil)
            }
            if let acceleration {
                self.update(\.scrollAcceleration, acceleration)
            } else if !hasAcceleration {
                self.update(\.scrollAcceleration, nil)
            }
            if let accelerationLevel {
                self.update(\.scrollAccelerationLevel, accelerationLevel)
            } else if !hasAcceleration {
                self.update(\.scrollAccelerationLevel, nil)
            }
            if let d { self.update(\.dpi, d) }
            if let p { self.update(\.pollRate, p) }
            if let b, self.zoneLighting.isEmpty { self.update(\.brightness, b) }
            if !stages.isEmpty { self.update(\.dpiStages, stages) }
            self.update(\.activeDpiStage, activeDpiStage)
            if let sleep { self.update(\.sleepTimeout, sleep) }
            // The mouse's own controls change config behind the app's back (the DPI-cycle
            // button; onboard memory surviving an app restart). If what we just read
            // contradicts the active profile, its checkmark is a lie — clear it. Comparing
            // against the PROFILE's stored values (not the previous published ones) keeps
            // the launch-time restore honest without clearing it on the first read.
            if let id = self.activeProfileID,
               let active = self.profiles.first(where: { $0.id == id }) {
                let dpiDrifted = d.map { $0 != active.dpi } ?? false
                let pollDrifted = p.map { $0 != active.pollRate } ?? false
                let brightnessDrifted = self.deviceHasLighting && (b.map { $0 != active.brightness } ?? false)
                if dpiDrifted || pollDrifted || brightnessDrifted {
                    self.clearActiveProfileIfNeeded()
                }
            }
        }
    }

    /// Writes out the throttled savers' in-memory tail (up to five minutes of samples and
    /// learned rate, and ~30s of curve updates, otherwise dropped on every clean quit).
    /// Called from `applicationWillTerminate`.
    /// Best-effort with a short timeout: the serial queue may be mid-poll inside the HID
    /// retry ladder (seconds of sleeps against a flaky dongle), and wedging quit behind
    /// that is worse than losing the tail — the timeout path just matches the old
    /// unclean-quit behavior.
    func flushHistoryToDisk() {
        let done = DispatchSemaphore(value: 0)
        io.async {
            self.battery.saveNow()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 2)
    }
}
