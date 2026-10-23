// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation
import Combine
import AppKit
import CoreBluetooth
import RazerProtocol
import RazerDeviceKit

/// A Razer mouse on Bluetooth that Serpentine isn't controlling, and why — drives the
/// popover's Bluetooth notice.
enum BluetoothMouseStatus: Equatable {
    /// A model with no Bluetooth control: switch it to the 2.4 GHz dongle or USB-C.
    case needsModeSwitch(name: String)
    /// A supported model not reached yet (just connected, or a failed open backing off).
    case connecting(name: String)
    /// A supported model, but macOS denies Serpentine Bluetooth access.
    case accessDenied(name: String)

    var name: String {
        switch self {
        case .needsModeSwitch(let n), .connecting(let n), .accessDenied(let n): return n
        }
    }

    init(_ mouse: HIDDevice.BluetoothMouse, authorization: CBManagerAuthorization) {
        if mouse.controllablePID == nil {
            self = .needsModeSwitch(name: mouse.name)
        } else if authorization == .denied || authorization == .restricted {
            self = .accessDenied(name: mouse.name)
        } else {
            self = .connecting(name: mouse.name)
        }
    }
}

enum BluetoothRecoveryState: Equatable {
    case idle
    case reconnecting
}

/// Owns the HID device for the app's lifetime and exposes observable state to SwiftUI.
/// All HID IO runs on a serial background queue (the calls block with sleeps); published
/// state is updated on the main queue.
/// `@unchecked Sendable`: state is accessed under a strict discipline — `device` only on the
/// `io` queue, `@Published` properties only on the main queue (via `publish`).
///
/// The state is declared here and the work is split by feature into `MouseController+*.swift`
/// (reads, writes, lighting, slots, remaps in the mouse, profiles, connection, previews). The
/// published values are `internal(set)` so those files can set them; views only read them and
/// change the mouse through the methods.
final class MouseController: ObservableObject, @unchecked Sendable {
    static let connectionSoundsEnabledKey = Preferences.connectionSoundsEnabled

    @Published internal(set) var connected = false
    @Published internal(set) var batteryPercent: Int?
    @Published internal(set) var charging = false
    @Published internal(set) var dpi: Int = 0
    @Published internal(set) var pollRate: Int = 0
    @Published internal(set) var brightness: Int = 100 // percent
    /// Lighting state is controller-owned like DPI/brightness: published on successful
    /// device writes only. There's no lighting readback command, so this is the app's
    /// single source of truth for what the mouse is showing — the picker, the swatches,
    /// and profile snapshots all read it (a UI-local copy used to snapshot "phantom"
    /// lighting the mouse never took).
    @Published internal(set) var effect: LightingEffect = .staticColor
    @Published internal(set) var lightingColor = RGB(r: 0x44, g: 0xD6, b: 0x2C) // razer green
    /// Each zone's lighting as read from the mouse, on mice whose zones are set one by one
    /// (`ZonedLighting`); empty on every other mouse. `effect`, `lightingColor` and
    /// `brightness` then show the selected zone (the logo when all are selected).
    @Published internal(set) var zoneLighting: [LightingZone: ZoneLighting] = [:]
    /// The zone the lighting controls change; nil changes them all.
    @Published internal(set) var selectedLightingZone: LightingZone?
    @Published internal(set) var dpiStages: [Int] = [] // the mouse's configured DPI presets
    @Published internal(set) var activeDpiStage: Int?
    @Published internal(set) var dpiStagesError: String?
    @Published internal(set) var isUpdatingDpiStages = false
    @Published internal(set) var sleepTimeout: Int?
    /// Smart-Reel (`RazerCommands.setScrollSmartReel`), on mice with `RazerDevices.hasWheelControls`; nil
    /// until read, and on every other mouse.
    @Published internal(set) var smartReel: Bool?
    /// Smart-Reel sensitivity, `RazerCommands.wheelLevelRange` (higher drops into free
    /// spin more readily), on mice with `RazerDevices.hasSmartReelSensitivity`; nil until read,
    /// and on every other mouse.
    @Published internal(set) var smartReelSensitivity: Int?
    /// Scroll acceleration on/off and its level (`RazerCommands.wheelLevelRange`, higher
    /// scrolls further on a fast free spin), on mice with `RazerDevices.hasScrollAcceleration`; nil
    /// until read, and on every other mouse.
    @Published internal(set) var scrollAcceleration: Bool?
    @Published internal(set) var scrollAccelerationLevel: Int?
    @Published internal(set) var sleepTimeoutError: String?
    /// The battery percentage at which the mouse itself goes into its low-battery mode, on mice
    /// with `RazerDevices.supportsLowBatteryThreshold`; nil until read, and on every other mouse.
    @Published internal(set) var lowBatteryThreshold: Int?
    @Published internal(set) var isUpdatingSleepTimeout = false
    @Published internal(set) var timeEstimate: String?
    /// The most recent trusted battery reading, retained while disconnected.
    @Published internal(set) var lastBatterySnapshot: LastBatterySnapshot?
    /// Snapshots of `io`-queue-owned history, republished on the main queue for the usage graph.
    @Published internal(set) var batterySamples: [BatterySample] = []
    /// The last finished cycle's curve, drawn dimmed behind the current one (~2 charges of
    /// context) so the chart doesn't blank out at a recharge.
    @Published internal(set) var previousCycleSamples: [BatterySample] = []
    @Published internal(set) var dischargeRatePerHour: Double?
    @Published internal(set) var cycleStartedAt: Date?
    @Published internal(set) var cycleStartedPercent: Int?
    @Published internal(set) var pastCycles: [ChargeCycleSummary] = []
    @Published internal(set) var averageCycleHours: Double?
    @Published internal(set) var statusText = "…"
    @Published internal(set) var lastError: String?
    @Published internal(set) var isRefreshing = false
    /// Name of the connected Razer mouse (from its USB product string), or nil if none present.
    @Published internal(set) var deviceName: String?
    /// Whether the connected model's control protocol is verified (Cobra family).
    @Published internal(set) var deviceSupported = true
    /// Whether the connected mouse has a battery (wired-only mice don't → hide battery UI).
    @Published internal(set) var deviceHasBattery = true
    /// Whether the connected mouse has RGB lighting (e.g. the Atheris has none → hide it).
    @Published internal(set) var deviceHasLighting = true
    /// Max settable DPI for the connected model (drives the slider range).
    @Published internal(set) var deviceMaxDPI = 26000
    /// Bumped whenever a user-initiated device write fails, so the UI can snap its
    /// optimistic slider state back to the real values (the values themselves don't change
    /// on a failed write, so no other `@Published` transition fires).
    @Published internal(set) var lastWriteFailure: Date?
    /// Product ID of the connected mouse (nil when none) — drives feature gating.
    @Published internal(set) var deviceID: Int?
    /// Stable per-unit key (serial number if available, else PID) — drives per-device settings.
    @Published internal(set) var deviceKey: String?
    /// The connected mouse is on Bluetooth. Read through the `supports…` properties below.
    @Published internal(set) var deviceIsBluetooth = false
    /// The Basilisk V3 X HyperSpeed's dedicated DPI Cycle assignment, available over Bluetooth.
    @Published internal(set) var dpiCycleButtonBinding: BLEProtocol.DPIButtonBinding?
    @Published internal(set) var dpiCycleButtonError: String?
    @Published internal(set) var isUpdatingDpiCycleButton = false
    /// A Razer mouse seen on Bluetooth while we aren't controlling one, and why.
    @Published internal(set) var bluetoothMouse: BluetoothMouseStatus?
    @Published internal(set) var bluetoothRecoveryState: BluetoothRecoveryState = .idle
    @Published internal(set) var wakeRecoveryCounter = 0

    // What the connected link can do. Bluetooth has no known command for polling rate or
    // effects other than static, and switches DPI only between the mouse's own stages
    // (`BLEProtocol`). A profile sets all of those, so applying one there would half-fail,
    // except on a mouse with onboard slots: its profile lives in the mouse, and switching to
    // its slot brings back what Bluetooth can't set.
    /// What the connected mouse can do on its link; `.none` while nothing is connected.
    /// Derived from `deviceID` and `deviceIsBluetooth`, which are published, so views follow it.
    var capabilities: DeviceCapabilities {
        DeviceCapabilities(pid: deviceID, link: deviceIsBluetooth ? .bluetooth : .usb)
    }
    var supportsPollRate: Bool { capabilities.pollRate }
    var supportsLightingEffects: Bool { capabilities.lightingEffects }
    /// The connected mouse's lighting zones (`ZonedLighting`); empty when it is lit as one.
    var lightingZones: [LightingZone] { capabilities.lightingZones }
    var lightingEffects: [LightingEffect] { capabilities.effects }
    var supportsFreeDPI: Bool { capabilities.freeDPI }
    /// Single and Stages DPI modes, the same on every link (`setDPITable`).
    var supportsDpiModes: Bool { capabilities.dpiModes }
    var supportsProfiles: Bool { !capabilities.isBluetooth || activeOnboardSlot != nil }
    var ioHasBattery = true // io-queue mirror of deviceHasBattery

    /// Saved DPI/poll/lighting/button-remap presets for the connected mouse, and which one (if
    /// any) currently matches the live config. Loaded/swapped alongside `deviceKey` in
    /// `ensureDevice()`, same as the battery history.
    @Published internal(set) var profiles: [MouseProfile] = []
    @Published internal(set) var activeProfileID: UUID?
    /// The most recent profile apply failed (mouse offline/asleep) — without this, tapping
    /// a chip on a sleeping mouse does visibly nothing. Cleared when the next apply starts.
    @Published internal(set) var profileApplyFailed = false

    /// User preference: show the battery % beside the menu bar icon (persisted).
    @Published var showPercentInMenuBar: Bool = (UserDefaults.standard.object(forKey: Preferences.showPercentInMenuBar) as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(showPercentInMenuBar, forKey: Preferences.showPercentInMenuBar)
            updateStatusText()
        }
    }

    /// User preference: play sounds when the mouse connects or disconnects (persisted).
    @Published var connectionSoundsEnabled: Bool =
        (UserDefaults.standard.object(forKey: MouseController.connectionSoundsEnabledKey) as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(connectionSoundsEnabled, forKey: MouseController.connectionSoundsEnabledKey)
        }
    }

    /// Every command to the mouse, in order, with what the user asked for going first.
    let io = DeviceQueue()
    var userWorkPending: Bool { io.userWorkPending }

    #if DEBUG
    /// The bookkeeping in `DeviceQueue`, for the test that says it never leaks. A count stuck
    /// above zero would stop every background read for the life of the process, and the
    /// popover would quietly stop reflecting the mouse.
    var userWorkPendingForTesting: Bool { userWorkPending }
    func runUserCommandForTesting(_ body: @escaping @Sendable () -> Void) { io.user(body) }
    #endif

    var device: (any RazerTransport)?
    /// When opening a Bluetooth mouse last failed slowly (see `openTransport`).
    var bluetoothOpenFailedAt: Date?
    /// `io` queue only. Wake/activity checks bypass the long-open cooldown and do not
    /// establish another cooldown if the peripheral is still waking.
    var bypassBluetoothRetryCooldown = false
    static let bluetoothRetryInterval: TimeInterval = 30
    static func shouldSkipBluetoothRetry(lastFailure: Date?, now: Date,
                                         bypassCooldown: Bool) -> Bool {
        guard !bypassCooldown, let lastFailure else { return false }
        return now.timeIntervalSince(lastFailure) < bluetoothRetryInterval
    }
    var pollTimer: Timer?
    /// Battery history, charge cycles, discharge curve and last readings. `io` queue only.
    let battery = BatteryTracker()
    /// Suppresses connect/disconnect sounds until the first poll establishes a baseline.
    var hasBaseline = false
    let lowBatteryNotifier = LowBatteryNotifier()
    /// Listens for the mouse itself moving while it reads offline, so a wake is noticed at
    /// once instead of at the next (backed-off) poll. Main thread; see `HIDInputWatcher`.
    lazy var inputWatcher = HIDInputWatcher(vendorId: Razer.vendorId) { [weak self] in
        // Any Razer mouse moved. That is a reason to look, not proof this one is back: the
        // read decides. If it still fails, the offline publish starts the watcher again.
        self?.mouseInputSeen()
    }
    /// When movement last sent us to the device. A mouse can be moving and still unreadable —
    /// waking up, or answering from a dongle that refuses commands for a moment — and each
    /// failed check restarts the watcher, so without a floor here a hand on the mouse would
    /// turn into a read per movement. Past the floor the ordinary poll takes over, and the
    /// next offline poll starts the watcher again.
    var lastInputTriggeredCheck = Date.distantPast
    let wakeRecoveryGenerationLock = NSLock()
    var wakeRecoveryGeneration = 0

    func beginWakeRecoveryGeneration() -> Int {
        wakeRecoveryGenerationLock.lock()
        defer { wakeRecoveryGenerationLock.unlock() }
        wakeRecoveryGeneration += 1
        return wakeRecoveryGeneration
    }

    func isCurrentWakeRecovery(_ generation: Int) -> Bool {
        wakeRecoveryGenerationLock.lock()
        defer { wakeRecoveryGenerationLock.unlock() }
        return generation == wakeRecoveryGeneration
    }

    /// Main thread, from `inputWatcher`.
    func mouseInputSeen() {
        guard Date().timeIntervalSince(lastInputTriggeredCheck) >= 2 else { return }
        lastInputTriggeredCheck = Date()
        // Log the movement for offline reconnect reports, then use the ordinary offline
        // check so repeated movement still respects the Bluetooth open-failure cooldown.
        FileHandle.standardError.write(Data("[Serpentine] mouse moved while offline — checking now\n".utf8))
        checkIfOffline()
    }

    /// A wake or mouse movement is strong evidence that a sleeping peripheral may have
    /// returned. Retry a bounded number of times, serially, and bypass the slow-open
    /// cooldown for these attempts. This never sends traffic merely to keep the mouse awake.
    func beginWakeRecovery(discardBluetoothSession: Bool = false) {
        let generation = beginWakeRecoveryGeneration()
        if !connected { update(\.bluetoothRecoveryState, .reconnecting) }
        io.async { [weak self] in
            guard let self, self.isCurrentWakeRecovery(generation) else { return }
            // Only an observed HID removal proves the old BLE session needs replacing.
            if discardBluetoothSession, self.device?.isBluetooth == true {
                self.device?.close()
                self.device = nil
                self.onboardConfirmed = nil
                self.onboardReadFrom = nil
            }
            self.bluetoothOpenFailedAt = nil
            self.performWakeRecoveryAttempt(generation: generation, retryIndex: 0)
        }
    }

    /// Called by the IOKit monitor when macOS removes or re-enumerates the supported BLE HID.
    /// Unlike a timer, these service transitions occur at the mouse's sleep/wake boundary.
    func beginBluetoothWakeRecovery(discardBluetoothSession: Bool = false) {
        beginWakeRecovery(discardBluetoothSession: discardBluetoothSession)
    }

    func performWakeRecoveryAttempt(generation: Int, retryIndex: Int) {
        guard isCurrentWakeRecovery(generation) else { return }
        io.async { [weak self] in
            guard let self, self.isCurrentWakeRecovery(generation) else { return }
            self.bypassBluetoothRetryCooldown = true
            self.readBatterySync()
            if self.pollState.batteryReady, let active = self.device,
               active.isBluetooth, RazerDevices.supportsDpiButtonBinding(pid: active.productID) {
                self.readSettingsSync()
                self.publish {
                    guard self.isCurrentWakeRecovery(generation) else { return }
                    self.update(\.wakeRecoveryCounter, self.wakeRecoveryCounter &+ 1)
                }
            }
            self.bypassBluetoothRetryCooldown = false
            let next = self.pollState.nextPollInterval(pointerActive: Self.pointerIsInUse())
            self.publish {
                self.scheduleNextPoll(after: next)
                guard self.isCurrentWakeRecovery(generation) else { return }
                if self.connected {
                    self.update(\.bluetoothRecoveryState, .idle)
                } else if retryIndex < Self.bluetoothWakeRetryDelays.count {
                    self.update(\.bluetoothRecoveryState, .reconnecting)
                    let delay = Self.bluetoothWakeRetryDelays[retryIndex]
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        self.performWakeRecoveryAttempt(generation: generation, retryIndex: retryIndex + 1)
                    }
                } else {
                    self.update(\.bluetoothRecoveryState, .idle)
                }
            }
        }
    }

    static let bluetoothWakeRetryDelays: [TimeInterval] = [0.3, 1.0, 2.0]
    /// io-queue only: the pure decision core of the poll loop — offline debounce, garbage
    /// rejection, charge confirmation. All the subtle logic lives (and is tested) there;
    /// this class just does the I/O and acts on the verdicts.
    var pollState = BatteryPollStateMachine()

    /// Re-read notification authorization (launch, and whenever the app is refocused) so a
    /// low-battery alert isn't consumed while notifications are switched off.
    func refreshNotificationAuthorization() { lowBatteryNotifier.refreshAuthorization() }

    func start() {
        if let snapshot = battery.snapshotStore.load() {
            lastBatterySnapshot = snapshot
            batteryPercent = snapshot.percent
            battery.latestSnapshot = snapshot
        }
        battery.onCyclesChanged = { [weak self] cycles, average in
            guard let self else { return }
            self.publish { self.pastCycles = cycles; self.averageCycleHours = average }
        }
        lowBatteryNotifier.refreshAuthorization()
        refreshAll()
        scheduleNextPoll(after: BatteryPollStateMachine.Cadence.settling)
        // The history and curve files are written on a throttle, and a Mac that sleeps and
        // then loses power never reaches `applicationWillTerminate`. Save on the way down.
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.saveHistorySoon()
        }
        // Sleep is where a mouse most often disappears: switched off, or its dongle moved to
        // another machine. The poll may be minutes away by then, so ask as soon as we're up.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.beginWakeRecovery() }
    }

    var sleepObserver: NSObjectProtocol?
    var wakeObserver: NSObjectProtocol?

    /// Writes the throttled history and curve out without waiting. The Mac is going to sleep
    /// either way; if the queue is mid-read this lands a moment later, or on wake.
    func saveHistorySoon() {
        io.async { [weak self] in self?.battery.saveNow() }
    }

    /// Self-rescheduling poll loop. Scheduled on the common run-loop modes so it keeps firing
    /// even while the menu/popover is being tracked.
    func scheduleNextPoll(after interval: TimeInterval) {
        pollTimer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            self?.pollTick()
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    /// Whether the pointer has been used recently, by any device (see `Cadence.inUse`).
    /// `CGEventSource` answers from the window server's own bookkeeping: no event tap, no
    /// callbacks, no permission. Movement settles it nearly every time; clicks and scrolls
    /// are only asked about once movement has gone quiet, for a hand that clicks without
    /// moving.
    static func pointerIsInUse() -> Bool {
        let window = BatteryPollStateMachine.Cadence.pointerActiveWindow
        for type in [CGEventType.mouseMoved, .leftMouseDown, .scrollWheel] {
            if CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: type) < window {
                return true
            }
        }
        return false
    }

    func pollTick() {
        io.async { [weak self] in
            guard let self else { return }
            self.readBatterySync()
            // Fast while settling or just dropped, slow once connected (faster while the
            // pointer is in use), and backing off when the mouse stays unreachable. See
            // `BatteryPollStateMachine.Cadence`.
            let next = self.pollState.nextPollInterval(pointerActive: Self.pointerIsInUse())
            self.publish { self.scheduleNextPoll(after: next) }
        }
    }

    /// Main-thread only (timer/popover callbacks): prevents the 2s popover timer from
    /// stacking reads while one is still grinding through the retry ladder — with a mouse
    /// that answers slowly (or a dongle answering with stale reports), each read can take
    /// seconds, and unconditionally enqueueing every tick would grow the serial io queue's
    /// backlog without bound, delaying user writes by minutes.
    var settingsReadQueued = false

    var settingsTimer: Timer?

    /// io-queue only. The DPI as the last full read found it (the active stage and the stage
    /// table on a mouse the table drives, else the DPI), for `checkLiveSync` to compare.
    var dpiSignature: [Int]?
    /// Main thread. A check is queued; the timer doesn't queue another behind it.
    var liveCheckQueued = false

    /// Main-thread only. A check is already on its way; don't queue another behind it.
    var offlineCheckQueued = false

    /// Subtle system sound on a connection-state change. "Pop" pairs with "Submarine" —
    /// both soft and rounded. (System sounds live in /System/Library/Sounds; swap the names
    /// here to taste — e.g. "Bottle", "Tink", "Hero" for connect.)
    static let connectSound = NSSound.Name("Pop")
    static let disconnectSound = NSSound.Name("Submarine")
    /// Plays the connect (true) or disconnect (false) sound. Main thread. Swapped out by tests,
    /// so they can check that the setting really gates `playSound`.
    var playConnectionSound: (Bool) -> Void = { connected in
        NSSound(named: connected ? MouseController.connectSound : MouseController.disconnectSound)?.play()
    }

    /// Set when the last attempt to write the remaps into the mouse didn't fully succeed.
    @Published internal(set) var onboardWriteError: String?

    /// Which entries Serpentine wrote into which mouse. Tests hand in their own defaults.
    var onboardOwnership = OnboardOwnership(defaults: .standard)

    /// io-queue only. The remap table to keep in the mouse, and the device key it belongs to
    /// (`ButtonRemapper.activeDeviceKey`); nil until the remapper has handed it over, so a poll
    /// that runs first can't write anything.
    var onboardMappings: (deviceKey: String, mappings: [Int: RemapAction])?
    /// io-queue only. The plan last confirmed in the mouse, and which mouse.
    var onboardConfirmed: (serial: String, locationID: Int, plan: [OnboardButtons.Entry], shifted: [OnboardButtons.Entry])?
    /// io-queue only. The mouse and slot whose remaps were last read from the mouse
    /// (`OnboardButtons.adopt`); cleared when the link is reopened, so each connection reads
    /// them again.
    var onboardReadFrom: (serial: String, locationID: Int)?

    /// Main thread. Given the remaps read from the mouse when they differ from the remap
    /// table handed over, with the device key they belong to. Set by `AppDelegate`.
    var onOnboardMappingsRead: ((_ deviceKey: String, _ mappings: [Int: RemapAction]) -> Void)?


    /// io-queue only. The mouse and slot whose zone lighting was last read.
    var zonesReadFor: String?
    /// io-queue only. The colour each zone last had, for an effect that reports none.
    var zoneColors: [LightingZone: RGB] = [:]

    /// The mouse's active onboard slot (`OnboardSlots`); nil on mice without them, and until
    /// read. Profiles are kept in the mouse only while this is set.
    @Published internal(set) var activeOnboardSlot: Int?
    var supportsOnboardSlots: Bool { activeOnboardSlot != nil }
    /// The slots that exist in the mouse, in order: its profiles.
    @Published internal(set) var onboardSlotList: [Int] = []
    /// The profiles' names, by slot (`SlotNames`).
    @Published internal(set) var slotNames: [Int: String] = [:]

    /// io-queue only. The slots that exist in the open mouse, as last read or changed.
    var existingSlots: Set<UInt8> = [] {
        didSet {
            let list = existingSlots.map(Int.init).sorted()
            publish { self.update(\.onboardSlotList, list) }
        }
    }

    /// io-queue only. The next sync hands the remaps read from the mouse to the remapper even
    /// when they match the table handed over: set when the link moves to another slot, whose
    /// remaps replace the ones shown.
    var onboardPublishNextRead = false

    /// io-queue only. The link the slots were last read on. A link they weren't read on,
    /// because the mouse didn't answer as it opened (a dongle still waking after the switch
    /// from Bluetooth), gets them read on its next poll (`checkActiveSlotSync`).
    var slotsReadOn: ObjectIdentifier?


    /// Main thread. Given the remaps of a profile the mouse switched to by itself (a Cycle
    /// Profile button), so the remapper follows it. Set by `AppDelegate`.
    var onSlotProfileFollowed: ((MouseProfile) -> Void)?


    var profilesLoadedForKey: String?


    /// io-queue only. The serial number read the last time a device was opened, and the
    /// interface it was read from, so a reopen doesn't have to ask again. Only a successful
    /// read is kept: a serial that failed to resolve is retried on the next open, which the
    /// same-session key upgrade below depends on. Cleared by `forceCheck` on any plug or
    /// unplug, and by `releaseDeviceIfNeeded` on any USB-level failure, since either can mean
    /// a different unit now sits on the same interface.
    var knownSerial: (locationID: Int, pid: Int, serial: String)?


    func publish(_ block: @escaping @Sendable () -> Void) {
        DispatchQueue.main.async(execute: block)
    }

    /// Assign a published property only when the value actually changed. Every @Published
    /// set fires objectWillChange even for equal values, and the poll/settings timers
    /// re-publish the same state every few seconds — each no-op publish re-rendered every
    /// observing view, which among other things dismissed any open SwiftUI Menu (the remap
    /// shortcut picker collapsing after ~a second, mid-choice).
    func update<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<MouseController, T>, _ value: T) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    func updateStatusText() {
        let text: String
        if !showPercentInMenuBar || !deviceHasBattery {
            text = "" // no-battery mouse or preference off → just the mouse icon
        } else if let p = batteryPercent, connected {
            // Single mouse glyph + percentage only — charging is shown inside the popover.
            text = " \(p)%"
        } else {
            text = " —"
        }
        update(\.statusText, text)
    }
}
