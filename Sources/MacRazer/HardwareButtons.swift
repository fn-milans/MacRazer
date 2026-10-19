// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation
import IOKit
import IOKit.hid
import CoreGraphics

/// The buttons a mouse only reports to the Mac in OpenRazer's driver mode
/// (`RazerCommands.deviceModeDriver`).
///
/// In normal mode the mouse acts on its DPI and wheel-mode buttons itself, and some buttons
/// send nothing at all. In driver mode each one arrives as a "report 4" code on the
/// keyboard-style interface instead, and the mouse stops acting on them, so MacRazer has to
/// do their jobs. Wheel tilt moves too: from AC Pan to two undeclared bits of the pointer
/// report's button byte.
///
/// Codes were read from the Basilisk V4 Pro itself with `buttonprobe --driver-mode`, never
/// from Synapse (basilisk-v4-pro/button-probe/findings.md in the project notes).
///
/// The raw values are the ids the remap table stores them under. They are negative so they
/// can never collide with a CGEvent button number (-1 is already the Bluetooth DPI Cycle),
/// and in the order the remap window lists them.
enum HardwareButton: Int, CaseIterable, Sendable {
    case dpiCycle = -16
    case wheelMode = -15
    case sideFront = -14
    case sideTrigger = -13
    case leftClickSide = -12
    case tiltLeft = -11
    case tiltRight = -10

    var label: String {
        switch self {
        case .dpiCycle: return "DPI Button"
        case .wheelMode: return "Wheel Mode Button"
        case .sideFront: return "Side Front"
        case .sideTrigger: return "Side Trigger"
        case .leftClickSide: return "Left Click Side"
        case .tiltLeft: return "Tilt Left"
        case .tiltRight: return "Tilt Right"
        }
    }

    /// The report-4 code and pointer-byte bit of each button, per model. Nil for a mouse
    /// whose driver-mode codes nobody has measured: MacRazer never puts that one in driver
    /// mode, since its DPI button would stop working with nothing to replace it.
    static func layout(pid: Int) -> Layout? {
        switch pid {
        case 0x00E2, 0x00E3: // Basilisk V4 Pro, cable and dongle (same codes on both)
            return Layout(report4: [0x52: .dpiCycle, 0x54: .wheelMode, 0xD2: .sideFront,
                                    0x59: .sideTrigger, 0x50: .leftClickSide],
                          pointerBits: [0x20: .tiltLeft, 0x40: .tiltRight])
        default:
            return nil
        }
    }

    struct Layout: Equatable, Sendable {
        let report4: [UInt8: HardwareButton]
        let pointerBits: [UInt8: HardwareButton]
    }
}

/// Turns raw reports into presses and releases. Pure, so it can be tested without a mouse.
///
/// Report 4 is a list of the codes held right now (`04 52` while the DPI button is down,
/// `04` once it is up), so a press is a code that wasn't in the previous list and a release
/// one that has left it. The pointer byte works the same way, bit by bit.
struct HardwareButtonDecoder {
    struct Event: Equatable { let button: HardwareButton; let down: Bool }

    static let report4ID: UInt8 = 0x04
    let layout: HardwareButton.Layout
    private(set) var held: Set<HardwareButton> = []

    init(layout: HardwareButton.Layout) { self.layout = layout }

    /// A report from the keyboard-style interface. IOKit hands it over with its report id
    /// first. Other reports there (0x05 notices) are ignored.
    mutating func report4(_ bytes: [UInt8]) -> [Event] {
        guard bytes.first == Self.report4ID else { return [] }
        let now = Set(bytes.dropFirst().compactMap { layout.report4[$0] })
        return diff(now, among: Set(layout.report4.values))
    }

    /// A report from the pointer interface; its first byte holds the buttons.
    mutating func pointer(_ bytes: [UInt8]) -> [Event] {
        guard let byte = bytes.first else { return [] }
        let now = Set(layout.pointerBits.compactMap { bit, button in byte & bit != 0 ? button : nil })
        return diff(now, among: Set(layout.pointerBits.values))
    }

    /// Everything held is released, for when the listener stops with a button still down.
    mutating func releaseAll() -> [Event] {
        defer { held.removeAll() }
        return held.sorted { $0.rawValue < $1.rawValue }.map { Event(button: $0, down: false) }
    }

    private mutating func diff(_ now: Set<HardwareButton>, among scope: Set<HardwareButton>) -> [Event] {
        let before = held.intersection(scope)
        let released = before.subtracting(now), pressed = now.subtracting(before)
        held.subtract(released)
        held.formUnion(pressed)
        let order: (HardwareButton, HardwareButton) -> Bool = { $0.rawValue < $1.rawValue }
        return released.sorted(by: order).map { Event(button: $0, down: false) }
            + pressed.sorted(by: order).map { Event(button: $0, down: true) }
    }
}

/// Listens for `HardwareButton` presses on the mouse's keyboard-style interface (report 4)
/// and its pointer interface (tilt bits). Opened without seizing, so macOS keeps getting
/// every ordinary click and movement. Main thread only, like `HIDInputWatcher`.
final class HardwareButtonListener: @unchecked Sendable {
    private let onEvent: (HardwareButtonDecoder.Event) -> Void
    private var open: [(device: IOHIDDevice, buffer: UnsafeMutablePointer<UInt8>, size: Int, isPointer: Bool)] = []
    private var decoder: HardwareButtonDecoder?
    private var selfContext: UnsafeMutableRawPointer?
    private(set) var pid: Int?

    init(onEvent: @escaping (HardwareButtonDecoder.Event) -> Void) { self.onEvent = onEvent }

    var isRunning: Bool { selfContext != nil }

    /// Starts listening to the mouse with this product id. Returns whether both interfaces it
    /// needs opened; without Input Monitoring neither does.
    @discardableResult
    func start(pid: Int) -> Bool {
        if isRunning, self.pid == pid { return true }
        stop()
        guard let layout = HardwareButton.layout(pid: pid) else { return false }
        let context = Unmanaged.passRetained(self).toOpaque()
        var opened: [(device: IOHIDDevice, buffer: UnsafeMutablePointer<UInt8>, size: Int, isPointer: Bool)] = []
        let devices = HIDDevice.devices(matching: [
            kIOHIDVendorIDKey as String: Razer.vendorId,
            kIOHIDProductIDKey as String: pid,
        ])
        for device in devices {
            func prop(_ key: String) -> Int { IOHIDDeviceGetProperty(device, key as CFString) as? Int ?? 0 }
            let page = prop(kIOHIDPrimaryUsagePageKey), usage = prop(kIOHIDPrimaryUsageKey)
            let size = prop(kIOHIDMaxInputReportSizeKey)
            guard page == kHIDPage_GenericDesktop, size > 0 else { continue }
            let isPointer = usage == kHIDUsage_GD_Mouse
            // Two keyboard-style interfaces: the 8-byte boot keyboard, and the 16-byte one
            // that carries reports 4 and 5. Only the second is wanted.
            guard isPointer || (usage == kHIDUsage_GD_Keyboard && size >= 16) else { continue }
            guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { continue }
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            let callback: IOHIDReportCallback = isPointer
                ? { context, _, _, _, _, report, length in
                    guard let context else { return }
                    let bytes = Array(UnsafeBufferPointer(start: report, count: length))
                    Unmanaged<HardwareButtonListener>.fromOpaque(context).takeUnretainedValue().received(pointer: bytes)
                }
                : { context, _, _, _, reportID, report, length in
                    guard let context else { return }
                    var bytes = Array(UnsafeBufferPointer(start: report, count: length))
                    // Some interfaces hand the id over separately; put it back in front.
                    if bytes.first != UInt8(truncatingIfNeeded: reportID) { bytes.insert(UInt8(truncatingIfNeeded: reportID), at: 0) }
                    Unmanaged<HardwareButtonListener>.fromOpaque(context).takeUnretainedValue().received(report4: bytes)
                }
            IOHIDDeviceRegisterInputReportCallback(device, buffer, size, callback, context)
            IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            opened.append((device, buffer, size, isPointer))
        }
        guard !opened.isEmpty else {
            Unmanaged<HardwareButtonListener>.fromOpaque(context).release()
            return false
        }
        open = opened
        decoder = HardwareButtonDecoder(layout: layout)
        selfContext = context
        self.pid = pid
        return opened.contains { $0.isPointer } && opened.contains { !$0.isPointer }
    }

    private func received(report4 bytes: [UInt8]) {
        guard var d = decoder else { return }
        let events = d.report4(bytes)
        decoder = d
        events.forEach(onEvent)
    }

    private func received(pointer bytes: [UInt8]) {
        guard var d = decoder else { return }
        let events = d.pointer(bytes)
        decoder = d
        events.forEach(onEvent)
    }

    /// Stops listening. A button still held gets its release, so nothing stays "down".
    func stop() {
        for entry in open {
            IOHIDDeviceRegisterInputReportCallback(entry.device, entry.buffer, entry.size, nil, nil)
            IOHIDDeviceUnscheduleFromRunLoop(entry.device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDDeviceClose(entry.device, IOOptionBits(kIOHIDOptionsTypeNone))
            entry.buffer.deallocate()
        }
        open.removeAll()
        if var d = decoder {
            let released = d.releaseAll()
            decoder = nil
            released.forEach(onEvent)
        }
        pid = nil
        if let context = selfContext {
            selfContext = nil
            Unmanaged<HardwareButtonListener>.fromOpaque(context).release()
        }
    }
}

/// Gives each `HardwareButton` press somewhere to go: the user's remap if there is one,
/// otherwise the job the mouse does with that button in normal mode. Runs the listener while
/// the connected mouse is in driver mode. Main thread.
final class HardwareButtonRouter: @unchecked Sendable {
    private let remapper: ButtonRemapper
    private weak var controller: MouseController?
    private lazy var listener = HardwareButtonListener { [weak self] in self?.handle($0) }
    private var tiltTimer: Timer?

    /// How often a held tilt scrolls again. The mouse repeats AC Pan every ~20 ms in normal
    /// mode (button-probe findings), and this keeps that feel.
    static let tiltRepeatInterval: TimeInterval = 0.02

    init(remapper: ButtonRemapper, controller: MouseController) {
        self.remapper = remapper
        self.controller = controller
    }

    /// Starts or stops listening as the mouse goes in and out of driver mode.
    func update(driverModeActive: Bool, connected: Bool, pid: Int?) {
        guard driverModeActive, connected, let pid, let layout = HardwareButton.layout(pid: pid) else {
            listener.stop()
            stopTilt()
            remapper.setHardwareButtons([])
            return
        }
        remapper.setHardwareButtons(Array(Set(layout.report4.values).union(layout.pointerBits.values)))
        guard listener.pid != pid || !listener.isRunning else { return }
        if !listener.start(pid: pid) {
            listener.stop()
            controller?.hardwareButtonsUnavailable(
                "MacRazer couldn't listen to the mouse's buttons. Allow Input Monitoring for MacRazer, then turn this on again.")
        }
    }

    func handle(_ event: HardwareButtonDecoder.Event) {
        if remapper.hardwareButton(event.button, down: event.down) { return }
        switch event.button {
        case .dpiCycle:
            if event.down { controller?.cycleDpiStage() }
        case .wheelMode:
            if event.down { controller?.toggleWheelMode() }
        case .tiltLeft, .tiltRight:
            if event.down { startTilt(left: event.button == .tiltLeft) } else { stopTilt() }
        case .sideFront, .sideTrigger, .leftClickSide:
            break // silent in normal mode, so there is no job to keep
        }
    }

    // MARK: Tilt

    /// Horizontal scroll while a tilt is held, as macOS does with the AC Pan the mouse sends
    /// in normal mode. A positive horizontal line delta scrolls left.
    private func startTilt(left: Bool) {
        stopTilt()
        let delta: Int32 = left ? 1 : -1
        Self.postHorizontalScroll(delta)
        let timer = Timer(timeInterval: Self.tiltRepeatInterval, repeats: true) { _ in
            Self.postHorizontalScroll(delta)
        }
        RunLoop.main.add(timer, forMode: .common)
        tiltTimer = timer
    }

    private func stopTilt() {
        tiltTimer?.invalidate()
        tiltTimer = nil
    }

    private static func postHorizontalScroll(_ delta: Int32) {
        CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2,
                wheel1: 0, wheel2: delta, wheel3: 0)?.post(tap: .cghidEventTap)
    }
}
