// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation
import RazerProtocol

/// What the app learns about a mouse's battery over time: the sample history and its charge
/// cycles (per unit), the discharge curve (per model), and the last reading of every mouse.
/// `MouseController` feeds it readings and publishes what it derives.
///
/// Used on the device queue only (`DeviceQueue`), like the device itself.
final class BatteryTracker {
    private(set) var history = BatteryHistory(deviceKey: "default")
    private(set) var cycleHistory = ChargeCycleHistory(deviceKey: "default")
    /// The device the current history belongs to; nil until a mouse has been opened.
    private(set) var deviceKey: String?
    let snapshotStore = LastBatterySnapshotStore()
    /// The latest reading, for the saves on sleep and termination.
    var latestSnapshot: LastBatterySnapshot?
    /// Learned per-percent discharge curve, only for models `RazerDevices` covers (see
    /// `dischargeCurveModelKey`); nil leaves every other mouse on the generic rate estimate.
    private(set) var curveModel: DischargeCurveModel?
    private var curveModelKey: String?

    /// Called when a discharge cycle finishes, with every cycle and their average length in
    /// hours. On the device queue.
    var onCyclesChanged: (([ChargeCycleSummary], Double?) -> Void)?

    init() { wireHistory() }

    /// What the usage graph shows, decimated for display. One function for the poll path and
    /// the device-swap republish so the two can't drift (e.g. one of them forgetting the
    /// decimation).
    struct Display {
        let samples: [BatterySample]
        let previous: [BatterySample]
        let rate: Double?
        let cycleStart: Date?
        let cycleStartPercent: Int?
    }

    var display: Display {
        Display(samples: BatteryHistory.decimatedForDisplay(history.samples),
                previous: BatteryHistory.decimatedForDisplay(history.previousCycleSamples),
                rate: history.currentRatePerHour,
                cycleStart: history.cycleStartedAt,
                cycleStartPercent: history.cycleStartedPercent)
    }

    var cycles: (all: [ChargeCycleSummary], averageHours: Double?) {
        (cycleHistory.cycles, cycleHistory.averageCycleDuration.map { $0 / 3600 })
    }

    /// Writes out the throttled savers' in-memory tail: up to five minutes of samples and
    /// learned rate, ~30s of curve updates, and the last reading.
    func saveNow() {
        history.saveNow()
        curveModel?.saveNow()
        if let latestSnapshot { snapshotStore.save(latestSnapshot, force: true) }
    }

    /// Model-scoped (not per-serial) discharge curve, shared across every unit of a covered
    /// model so data accumulates faster. Independent of the per-unit history swap, since the
    /// curve key is the same across both Cobra HyperSpeed PIDs and every serial.
    func useCurveModel(pid: Int) {
        let key = RazerDevices.dischargeCurveModelKey(pid: pid)
        guard key != curveModelKey else { return }
        curveModelKey = key
        curveModel = key.map { DischargeCurveModel(modelKey: $0) }
    }

    /// A trusted reading: recorded (when the poll state machine says so), saved as the mouse's
    /// last reading, and returned with the estimate it gives.
    func record(percent: Int, charging: Bool, recordSample: Bool,
                productID: Int, deviceName: String) -> LastBatterySnapshot {
        if recordSample { history.record(percent: percent, charging: charging) }
        let estimateHours = charging ? nil : history.estimateHoursRemaining(currentPercent: percent, curveModel: curveModel)
        let snapshot = LastBatterySnapshot(
            deviceKey: deviceKey ?? String(format: "%04x", productID),
            productID: productID,
            deviceName: deviceName,
            percent: percent,
            observedAt: Date(),
            estimatedHoursRemaining: estimateHours,
            wasCharging: charging
        )
        let previous = latestSnapshot?.deviceKey == snapshot.deviceKey
            ? latestSnapshot : snapshotStore.load(snapshot.deviceKey)
        snapshotStore.save(snapshot, previous: previous)
        latestSnapshot = snapshot
        return snapshot
    }

    /// What `switchDevice` found for the mouse now open.
    struct Switch {
        /// The serial resolved for a mouse whose data so far was under its PID: the same unit.
        let isSameUnitKeyUpgrade: Bool
        /// The last reading kept for this mouse, shown until it is read again.
        let restoredSnapshot: LastBatterySnapshot?
        var restoredEstimate: String? {
            restoredSnapshot.flatMap { $0.wasCharging ? "Charging" : $0.estimateText }
        }
    }

    /// Moves to another mouse's history, by its device key (serial, or PID when it reports
    /// none). `migrate` moves the rest of the per-device data, for a same-unit key upgrade.
    func switchDevice(to key: String, serial: String?, pid: Int, migrate: @escaping (_ from: String, _ to: String) -> Void) -> Switch {
        // Same-session key upgrade: the serial probe failed on this session's first open
        // (data landed under the PID fallback) and has now resolved. Move that data to the
        // serial key — it demonstrably belongs to this physical unit (same session, same
        // connection); without this, everything recorded so far would be orphaned forever.
        // Cross-session PID orphans are deliberately NOT migrated: with two same-model units,
        // they could belong to the other mouse.
        let transition = SnapshotDeviceTransition.resolve(
            currentKey: deviceKey, newKey: key, serial: serial,
            pidKey: String(format: "%04x", pid))
        let isSameUnitKeyUpgrade = transition == .upgradedFromPID
        if let oldKey = deviceKey, let saved = snapshotStore.load(oldKey), saved.deviceKey != key {
            if isSameUnitKeyUpgrade, saved.deviceKey == oldKey {
                let rekeyed = LastBatterySnapshot(
                    deviceKey: key, productID: saved.productID, deviceName: saved.deviceName,
                    percent: saved.percent, observedAt: saved.observedAt,
                    estimatedHoursRemaining: saved.estimatedHoursRemaining,
                    wasCharging: saved.wasCharging
                )
                snapshotStore.save(rekeyed, force: true)
                snapshotStore.remove(saved.deviceKey)
                latestSnapshot = rekeyed
            }
        }
        // A missing serial is a failed identity probe, not evidence of a new mouse.
        // Preserve the current offline snapshot and all other devices' snapshots.
        let restored = serial == nil
            ? (snapshotStore.load(key) ?? latestSnapshot)
            : snapshotStore.load(key)
        latestSnapshot = restored
        history = Self.handOverHistory(
            history, outgoingKey: deviceKey,
            migrate: isSameUnitKeyUpgrade ? { old in migrate(old, key) } : nil,
            makeIncoming: { BatteryHistory(deviceKey: key) })
        deviceKey = key
        cycleHistory = ChargeCycleHistory(deviceKey: key)
        wireHistory()
        // The curve model is model-scoped and survives this per-unit swap when both units are
        // the same model — but its open dwell belongs to the previous mouse, and the new
        // one's current percent was never watched arriving.
        curveModel?.observationInterrupted()
        return Switch(isSameUnitKeyUpgrade: isSameUnitKeyUpgrade, restoredSnapshot: restored)
    }

    /// Moves from one device's battery history to another's, in the order that loses nothing.
    ///
    /// The outgoing history holds up to `BatteryHistory.historySaveInterval` of samples, and
    /// its learned rate, in memory. They are written first, because `migrate` moves files
    /// and anything not yet on disk would be left behind. The placeholder history the app
    /// starts with (`outgoingKey` nil) belongs to no device and is not written. Static and
    /// closure-driven so the order can be tested without a mouse.
    static func handOverHistory(_ outgoing: BatteryHistory, outgoingKey: String?,
                                migrate: ((String) -> Void)?,
                                makeIncoming: () -> BatteryHistory) -> BatteryHistory {
        guard let outgoingKey else { return makeIncoming() }
        outgoing.saveNow()
        migrate?(outgoingKey)
        return makeIncoming()
    }

    /// Hooks `history` to log finished discharge cycles into `cycleHistory` and per-interval
    /// dwell time into `curveModel`. Re-run whenever `history`/`cycleHistory` are swapped.
    private func wireHistory() {
        history.onCycleFinished = { [weak self] samples in
            guard let self else { return }
            self.cycleHistory.recordFinishedCycle(samples: samples)
            // The cycle ended, so whatever dwell the curve model had open at the current
            // percent will never complete — drop it so it can't skew a later cycle's mean.
            self.curveModel?.observationInterrupted()
            let cycles = self.cycles
            self.onCyclesChanged?(cycles.all, cycles.averageHours)
        }
        // Reads `self.curveModel` dynamically each call, so it stays correct even when only
        // `curveModel` (not `history`) changes — no separate rewiring needed for that case.
        history.onInterval = { [weak self] from, to, duration in
            self?.curveModel?.record(fromPercent: from, toPercent: to, duration: duration)
        }
        history.onObservationGap = { [weak self] in
            self?.curveModel?.observationInterrupted()
        }
    }
}
