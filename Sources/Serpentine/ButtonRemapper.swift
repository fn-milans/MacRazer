// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import Combine
import ApplicationServices
import CoreGraphics
import RazerProtocol

/// Software button remapping via a CGEvent tap. Detects which extra mouse buttons fire and,
/// for mapped ones, suppresses the original event and posts a key combo instead.
///
/// It only works while the app runs and needs Accessibility permission. A mouse whose
/// function table is known (`OnboardButtons`) keeps its remaps itself; the tap then only
/// handles what the mouse can't store (a mouse button past the fifth, a key with no HID usage).
///
/// The remap table and its onboard plan are here; the tap, HyperShift, the DPI Cycle bridge
/// and persistence are in `ButtonRemapper+*.swift`. The published values have internal
/// setters so those files can set them; views only read them.
final class ButtonRemapper: ObservableObject, @unchecked Sendable {
    @Published var accessibilityGranted = false
    @Published var eventTapAvailable = false
    @Published var keyboardCaptureAvailable = false
    @Published var lastDetectedButton: Int?
    @Published var seenButtons: Set<Int> = []
    @Published var suggestedButtons: Set<Int> = []
    @Published var mappings: [Int: RemapAction] = [:] {
        didSet { refreshOnboardPlan() }
    }

    @Published var dpiCycleSoftwareAction: RemapAction?
    @Published var dpiBridgeBindingConfirmed = false
    var bridgeKeyIsDown = false
    var dpiBridgeReadRequested = false
    var dpiBridgeRestoreAttempted = false
    var dpiObservers = Set<AnyCancellable>()
    let defaults: UserDefaults
    let actionEmitter: ((RemapAction) -> Void)?

    init(defaults: UserDefaults = .standard, actionEmitter: ((RemapAction) -> Void)? = nil) {
        self.defaults = defaults
        self.actionEmitter = actionEmitter
    }

    var tap: CFMachPort?
    var runLoopSource: CFRunLoopSource?
    var tapIncludesKeyboard = false
    /// Per-device key so each mouse keeps its own remaps.
    var activeKey = "none"
    var activeDeviceID: Int?
    var isBasiliskV3XHyperSpeed: Bool {
        activeKey != "none" && (activeDeviceID.map(RazerDevices.supportsDpiButtonBinding(pid:)) ?? false)
    }
    var remappingPermissionsGranted: Bool { accessibilityGranted && eventTapAvailable }
    var defaultsKey: String { Preferences.Device.buttonMappings(activeKey) }
    /// Mirrors `MouseController.connected` (wired in AppDelegate; main-thread, same as the
    /// tap callback). While the mouse is offline — powered off, asleep, dongle unplugged —
    /// its mappings must not fire: the tap can't tell which device sent a click, so they'd
    /// keep remapping matching buttons on every other pointing device. Published so the
    /// remap UI can say why nothing is firing (button detection still works while paused).
    @Published var remappingPaused = false

    /// Called when a mapped button is pressed while remapping is paused. The mouse is paused
    /// because the app last saw it offline, and a press of one of its mapped buttons is a good
    /// sign it has just woken up. Without this, the mapping only came back at the next battery
    /// poll, and that poll backs off while the mouse is away. Main thread, like the tap.
    var onPressWhilePaused: (() -> Void)?

    /// Switch to the connected mouse's mappings (called when the device changes). `key` is the
    /// per-unit device key (serial/PID).
    func setActiveDevice(_ key: String?, deviceID: Int? = nil) {
        let k = key ?? "none"
        let idChanged = deviceID != nil && deviceID != activeDeviceID
        guard k != activeKey || idChanged else { return }
        activeKey = k
        if deviceID != nil || k == "none" { activeDeviceID = deviceID }
        seenButtons = [] // detected buttons are per-device
        hyperShiftHeld = false
        suppressedTapButtons = []
        // Side buttons that are plain Back/Forward clicks, listed before the first press.
        suggestedButtons = isBasiliskV3XHyperSpeed || hasHardwareButtonLayout ? [3, 4] : []
        loadMappings()
        loadDpiSoftwareAction()
        dpiBridgeBindingConfirmed = false
        dpiBridgeReadRequested = false
        dpiBridgeRestoreAttempted = false
    }

    static var presets: [RemapPreset] { RemapCatalog.presets }

    func start() {
        loadMappings()
        loadDpiSoftwareAction()
        refreshAccessibility(prompt: false)
    }

    /// Re-check the Accessibility grant (call when the window appears / returns to front).
    func refreshAccessibility(prompt: Bool) {
        // An explicit Re-check is the user saying they changed a permission: try the
        // keyboard-capable tap again.
        if prompt { keyboardTapRefused = false }
        // Use the literal key to avoid touching the non-Sendable global CFString symbol.
        let granted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompt] as CFDictionary)
        accessibilityGranted = granted
        if granted {
            installTapIfNeeded()
        } else {
            removeTap()
        }
    }

    /// Tears down the event tap and its run-loop source — called when Accessibility is revoked
    /// while the app is running, so a stale tap isn't left registered indefinitely.
    func removeTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        tapIncludesKeyboard = false
        eventTapAvailable = false
        keyboardCaptureAvailable = false
        bridgeKeyIsDown = false
    }

    func openAccessibilitySettings() { SystemSettingsPanes.openAccessibility() }

    static var mediaOptions: [(code: Int, name: String)] { RemapCatalog.mediaOptions }

    /// Called after an individual button's mapping changes — lets owners (e.g. profile tracking
    /// in `MouseController`) know the live config has drifted from whatever profile was applied.
    var onManualChange: (() -> Void)?

    func setAction(_ action: RemapAction, for button: Int) {
        mappings[button] = action
        seenButtons.insert(button)
        saveMappings()
        onManualChange?()
    }

    /// Replaces the whole mapping table at once — used when applying a saved profile (as opposed
    /// to a single-button edit from the remap UI, which goes through `setAction`).
    func setMappings(_ new: [Int: RemapAction]) {
        mappings = withoutUnremappable(new)
        seenButtons.formUnion(new.keys)
        saveMappings()
    }

    /// Where each control of the connected mouse has its remap (`OnboardButtons.plan`),
    /// empty for a mouse without a known function table.
    @Published var onboardPlan: [OnboardButtons.Entry] = []

    /// The id the active mouse's remaps are saved under (`setActiveDevice`), nil with none.
    var activeDeviceKey: String? { activeKey == "none" ? nil : activeKey }

    /// The active mouse's function table, if it has a known one.
    var onboardLayout: [OnboardButtons.Control]? {
        guard activeKey != "none", let pid = activeDeviceID else { return nil }
        return OnboardButtons.layout(pid: pid)
    }

    /// Whether the connected mouse keeps its remaps itself.
    var mappingsLiveInMouse: Bool { onboardLayout != nil }
    /// The active mouse's remappable controls, for the remap window.
    var onboardControls: Set<Int> { Set(onboardLayout?.map(\.button) ?? []) }
    /// Whether a control is HyperShift from the factory (the side trigger,
    /// `OnboardButtons.isHyperShiftOnFactory`).
    func hyperShiftIsDefault(_ button: Int) -> Bool {
        onboardLayout?.first { $0.button == button }.map(OnboardButtons.isHyperShiftOnFactory) ?? false
    }

    /// The highest DPI the active mouse takes, for the custom DPI Clutch.
    var activeMaxDPI: Int { activeDeviceID.map(RazerDevices.maxDPI(pid:)) ?? 26000 }

    /// Whether an action is what a control already does from the factory, so its menu
    /// needn't offer it (HyperShift on the side trigger, Cycle Scroll Mode on Scroll Mode).
    func isDefault(_ action: RemapAction, for button: Int) -> Bool {
        guard let control = onboardLayout?.first(where: { $0.button == button }) else { return false }
        return OnboardButtons.isFactory(action, on: control)
    }

    /// Whether a control is the HyperShift clutch: set to HyperShift, or left on a factory
    /// HyperShift.
    func isHyperShiftClutch(_ button: Int) -> Bool {
        if let action = mappings[button], action != .passthrough { return action == .hyperShift }
        return hyperShiftIsDefault(button)
    }
    /// Controls whose remap is saved in the mouse: what they send is already the remapped
    /// action, so the tap lets it through untouched.
    var savedInMouse: Set<Int> = []

    /// Whether any remap needs the event tap, and so the Accessibility permission.
    var needsEventTap: Bool {
        !mappingsLiveInMouse || onboardPlan.contains { $0.placement == .app }
    }

    /// Whether Serpentine sees this control's presses, so it can be given an action only
    /// Serpentine can do (Double Click, HyperShift, a HyperShift mapping). Every button of a
    /// mouse without a function table; on one with, only those that are a mouse button while
    /// on their factory function (`OnboardButtons.appSees`).
    func appSees(_ button: Int) -> Bool {
        guard let control = onboardLayout?.first(where: { $0.button == button }) else { return true }
        return OnboardButtons.appSees(control)
    }

    /// A remap that can't fire: only Serpentine can do it, but it never sees the control.
    func remapCantFire(_ button: Int) -> Bool {
        onboardPlan.contains { $0.control.button == button && $0.placement == .app } && !appSees(button)
    }

    /// The order the remap window lists the active mouse's controls in, empty for none.
    var activeRowOrder: [Int] { onboardLayout == nil ? [] : activeDeviceID.flatMap(OnboardButtons.rowOrder(pid:)) ?? [] }

    func refreshOnboardPlan() {
        let plan = activeDeviceID.map { OnboardButtons.plan(pid: $0, mappings: activeKey == "none" ? [:] : mappings) } ?? []
        if plan != onboardPlan { onboardPlan = plan }
        savedInMouse = Set(plan.compactMap { entry in
            if case .mouse = entry.placement { return entry.control.button }
            return nil
        })
    }

    /// A button mapped to `.hyperShift` is held down. Main thread.
    @Published var hyperShiftHeld = false
    /// Tap-path buttons whose press was taken over, so their release is swallowed too even
    /// if HyperShift was let go in between and the release alone would map to nothing.
    var suppressedTapButtons: Set<Int> = []

    /// macOS refused the keyboard-capable tap this session. Cleared by an explicit Re-check
    /// (`refreshAccessibility(prompt: true)`) or a relaunch.
    var keyboardTapRefused = false

    static let tapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let remapper = Unmanaged<ButtonRemapper>.fromOpaque(userInfo).takeUnretainedValue()
        return remapper.handle(type: type, event: event)
    }

    static let magic: Int64 = 0x52415A45 // "RAZE" — marks events we post, to skip them
    lazy var postSource: CGEventSource? = {
        let s = CGEventSource(stateID: .combinedSessionState)
        s?.userData = Self.magic
        return s
    }()
}
