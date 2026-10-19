// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation
import IOKit
import IOKit.hid

/// The `buttonprobe` command: what a mouse reports when each of its controls is pressed.
///
/// Built to learn a new model's buttons from the mouse itself, never from Synapse. It listens
/// to every HID interface the mouse exposes and prints what arrives, and it re-reads a few
/// settings the buttons change on the mouse (DPI, active stage, wheel mode) so a press that
/// sends nothing to the Mac still shows up as the setting it changed.
///
/// Read only, except for `--driver-mode`: that switches the mouse to OpenRazer's driver mode
/// (`RazerCommands.setDeviceMode`) for the run, to see whether the DPI, profile and sniper
/// buttons then report to the Mac as "report 4" codes on the keyboard interface, and puts the
/// mode back when the run ends.
///
/// Main thread only: the interfaces are scheduled on the main run loop and the settings are
/// read between run loop turns, so callbacks and reads never overlap.
final class ButtonProbe: @unchecked Sendable {
    /// One opened interface. Its own object so the C callback's context says which interface
    /// a value came from.
    final class Listener: @unchecked Sendable {
        let device: IOHIDDevice
        let label: String
        let isPointer: Bool
        let buffer: UnsafeMutablePointer<UInt8>
        let size: Int
        unowned let probe: ButtonProbe
        var lastReport: [UInt8] = []
        var lastValues: [IOHIDElementCookie: Int] = [:]

        init(device: IOHIDDevice, label: String, isPointer: Bool, size: Int, probe: ButtonProbe) {
            self.device = device
            self.label = label
            self.isPointer = isPointer
            self.size = size
            self.buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: max(size, 1))
            self.probe = probe
        }
    }

    /// A setting re-read between run loop turns, and what it last answered.
    struct Watched {
        let name: String
        let request: RazerReport
        let bytes: Int
        var last: String?
    }

    private let started = Date()
    private var listeners: [Listener] = []
    private var watched: [Watched] = []

    init() {}

    // MARK: Output

    func log(_ line: String) {
        let t = String(format: "+%7.3fs", Date().timeIntervalSince(started))
        FileHandle.standardOutput.write(Data("\(t)  \(line)\n".utf8))
    }

    static func hex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    /// A raw report with its zero tail cut off, which is most of a 16- or 64-byte report.
    static func trimmed(_ bytes: [UInt8]) -> [UInt8] {
        guard let last = bytes.lastIndex(where: { $0 != 0 }) else { return Array(bytes.prefix(1)) }
        return Array(bytes[...last])
    }

    /// Whether an input value is worth a line. Pointer movement never is: it arrives a
    /// thousand times a second and says nothing about buttons. Relative controls (wheel,
    /// horizontal pan) only when they move; everything else only when it changes.
    static func describe(page: Int, usage: Int, value: Int, previous: Int?) -> String? {
        switch (page, usage) {
        case (kHIDPage_GenericDesktop, kHIDUsage_GD_X), (kHIDPage_GenericDesktop, kHIDUsage_GD_Y):
            return nil
        case (kHIDPage_GenericDesktop, kHIDUsage_GD_Wheel):
            return value == 0 ? nil : "wheel \(value > 0 ? "+" : "")\(value)"
        case (kHIDPage_Consumer, kHIDUsage_Csmr_ACPan):
            return value == 0 ? nil : "horizontal pan \(value > 0 ? "+" : "")\(value)"
        default:
            break
        }
        guard value != previous, !(previous == nil && value == 0) else { return nil }
        switch page {
        case kHIDPage_Button:
            return "mouse button \(usage) \(value != 0 ? "down" : "up")"
        case kHIDPage_KeyboardOrKeypad:
            return String(format: "keyboard usage 0x%02x %@", usage, value != 0 ? "down" : "up")
        case kHIDPage_Consumer:
            return String(format: "consumer usage 0x%03x = %d", usage, value)
        default:
            return String(format: "page 0x%04x usage 0x%04x = %d", page, usage, value)
        }
    }

    // MARK: Listening

    /// Opens every interface with the vendor id and starts listening. Returns how many opened.
    @discardableResult
    func start(vendorId: Int) -> Int {
        for device in HIDDevice.matchingDevices(vendorId: vendorId) {
            func prop(_ key: String) -> Int { IOHIDDeviceGetProperty(device, key as CFString) as? Int ?? 0 }
            let page = prop(kIOHIDPrimaryUsagePageKey), usage = prop(kIOHIDPrimaryUsageKey)
            let size = prop(kIOHIDMaxInputReportSizeKey)
            let label = String(format: "if[%04x:%04x in%d]", page, usage, size)
            guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
                log("\(label) could not be opened (Input Monitoring?)")
                continue
            }
            let isPointer = page == kHIDPage_GenericDesktop && usage == kHIDUsage_GD_Mouse
            let listener = Listener(device: device, label: label, isPointer: isPointer, size: size, probe: self)
            let context = Unmanaged.passUnretained(listener).toOpaque()
            IOHIDDeviceRegisterInputValueCallback(device, { context, _, _, value in
                guard let context else { return }
                Unmanaged<Listener>.fromOpaque(context).takeUnretainedValue().probe.received(value, on: context)
            }, context)
            // Raw reports from everything but the pointer interface, where they are mostly
            // movement. Razer's "report 4" (special buttons in driver mode) arrives on the
            // keyboard interface as a vendor array the value callback may not name.
            if !isPointer, size > 0 {
                IOHIDDeviceRegisterInputReportCallback(device, listener.buffer, size, { context, _, _, _, reportID, report, length in
                    guard let context else { return }
                    let bytes = Array(UnsafeBufferPointer(start: report, count: length))
                    Unmanaged<Listener>.fromOpaque(context).takeUnretainedValue()
                        .probe.received(report: bytes, id: reportID, on: context)
                }, context)
            }
            IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            listeners.append(listener)
            log("listening on \(label)\(isPointer ? " (pointer: buttons, wheel and tilt only)" : "")")
        }
        return listeners.count
    }

    private func received(_ value: IOHIDValue, on context: UnsafeMutableRawPointer) {
        let listener = Unmanaged<Listener>.fromOpaque(context).takeUnretainedValue()
        let element = IOHIDValueGetElement(value)
        let page = Int(IOHIDElementGetUsagePage(element)), usage = Int(IOHIDElementGetUsage(element))
        let length = IOHIDValueGetLength(value)
        if length > 4 {
            // A buffer-style element: integer reads of these are meaningless.
            let bytes = Array(UnsafeBufferPointer(start: IOHIDValueGetBytePtr(value), count: length))
            log(String(format: "%@ page 0x%04x usage 0x%04x bytes ", listener.label, page, usage) + Self.hex(Self.trimmed(bytes)))
            return
        }
        let cookie = IOHIDElementGetCookie(element)
        let integer = IOHIDValueGetIntegerValue(value)
        defer { listener.lastValues[cookie] = integer }
        guard let line = Self.describe(page: page, usage: usage, value: integer,
                                       previous: listener.lastValues[cookie]) else { return }
        log("\(listener.label) \(line)")
    }

    private func received(report: [UInt8], id: UInt32, on context: UnsafeMutableRawPointer) {
        let listener = Unmanaged<Listener>.fromOpaque(context).takeUnretainedValue()
        guard report != listener.lastReport else { return }
        listener.lastReport = report
        log("\(listener.label) report \(String(format: "0x%02x", id)): \(Self.hex(Self.trimmed(report)))")
    }

    func stop() {
        for listener in listeners {
            IOHIDDeviceRegisterInputValueCallback(listener.device, nil, nil)
            if !listener.isPointer, listener.size > 0 {
                IOHIDDeviceRegisterInputReportCallback(listener.device, listener.buffer, listener.size, nil, nil)
            }
            IOHIDDeviceUnscheduleFromRunLoop(listener.device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(listener.device, IOOptionBits(kIOHIDOptionsTypeNone))
            listener.buffer.deallocate()
        }
        listeners.removeAll()
    }

    // MARK: Settings the buttons change on the mouse

    /// The reads `poll(_:)` repeats. All OpenRazer commands, all reads.
    static func watchList() -> [Watched] {
        [
            Watched(name: "device mode", request: RazerCommands.getDeviceMode(), bytes: 2),
            Watched(name: "DPI x/y", request: RazerCommands.getDPI(), bytes: 5),
            Watched(name: "DPI stages (store, active, count)", request: RazerCommands.getDPIStages(), bytes: 3),
            Watched(name: "polling 0x85", request: RazerCommands.getPollingRate(), bytes: 1),
            Watched(name: "polling 0xC0", request: RazerCommands.getPollingRate2(), bytes: 2),
            Watched(name: "scroll mode", request: RazerCommands.getScrollMode(), bytes: 4),
            Watched(name: "scroll acceleration", request: RazerCommands.getScrollAcceleration(), bytes: 4),
            Watched(name: "Smart-Reel", request: RazerCommands.getScrollSmartReel(), bytes: 4),
        ]
    }

    func watch(_ list: [Watched]) { watched = list }

    /// Re-reads every watched setting and prints the ones that changed (all of them, the
    /// first time). A read the mouse refuses prints once, as its error.
    func poll(_ channel: DeviceProbeChannel) {
        for i in watched.indices {
            let answer: String
            do {
                let resp = try channel.send(watched[i].request)
                answer = Self.hex(resp.arguments.prefix(watched[i].bytes))
            } catch {
                answer = "error: \(error)"
            }
            if answer != watched[i].last {
                log("setting \(watched[i].name): \(answer)\(watched[i].last.map { "  (was \($0))" } ?? "")")
                watched[i].last = answer
            }
        }
    }
}

/// Set by the SIGINT handler, read between run loop turns. A C signal handler can't capture,
/// so it has to be a global.
nonisolated(unsafe) var buttonProbeInterrupted: Int32 = 0
