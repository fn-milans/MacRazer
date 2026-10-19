// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation
import IOKit
import IOKit.hid

/// Hears which control of a mouse that keeps its remaps (`OnboardButtons`) was pressed, for
/// the remap window's "Detected" line. The mouse sends what its function table holds (a
/// mouse button, a key, a media key), so a press is matched back to the control whose entry
/// holds that (`OnboardButtons.control(forPage:usage:value:in:)`).
///
/// Reads the mouse's own HID values without seizing it, so macOS keeps getting every click
/// and key; needs Input Monitoring, like `HIDInputWatcher`. Only button, keyboard and
/// consumer values and wheel steps are asked for, so pointer movement never wakes this process. The notices
/// on the 16-byte keyboard-style interface (report 5) are read too: the wheel-mode and DPI
/// buttons do their job in the mouse and only say so there
/// (`OnboardButtons.control(forNotice:in:)`). Run only while the remap window is open.
/// Main thread only.
final class OnboardPressListener: @unchecked Sendable {
    enum Press { case value(page: Int, usage: Int, value: Int), notice([UInt8]) }
    private let onPress: (Press) -> Void
    private var open: [IOHIDDevice] = []
    private var buffers: [(device: IOHIDDevice, buffer: UnsafeMutablePointer<UInt8>, size: Int)] = []
    private var selfContext: UnsafeMutableRawPointer?
    private(set) var pid: Int?

    init(onPress: @escaping (Press) -> Void) { self.onPress = onPress }

    var isRunning: Bool { selfContext != nil }

    static let pages = [kHIDPage_Button, kHIDPage_KeyboardOrKeypad, kHIDPage_Consumer]

    /// Starts listening to the mouse with this product id: the cable or dongle under Razer's
    /// USB vendor id, Bluetooth under its BLE one. Returns whether anything opened; without
    /// Input Monitoring nothing does.
    @discardableResult
    func start(pid: Int) -> Bool {
        if isRunning, self.pid == pid { return true }
        stop()
        let vendor = RazerDevices.connection(pid: pid) == .bluetooth ? BLEProtocol.vendorId : Razer.vendorId
        let devices = HIDDevice.devices(matching: [
            kIOHIDVendorIDKey as String: vendor,
            kIOHIDProductIDKey as String: pid,
        ])
        let context = Unmanaged.passRetained(self).toOpaque()
        // Plus the wheel (scroll up and down are controls too), but never X and Y.
        let matching = (Self.pages.map { [kIOHIDElementUsagePageKey as String: $0] }
            + [[kIOHIDElementUsagePageKey as String: kHIDPage_GenericDesktop,
                kIOHIDElementUsageKey as String: kHIDUsage_GD_Wheel]]) as CFArray
        for device in devices {
            guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { continue }
            IOHIDDeviceSetInputValueMatchingMultiple(device, matching)
            IOHIDDeviceRegisterInputValueCallback(device, { context, _, _, value in
                guard let context else { return }
                let element = IOHIDValueGetElement(value)
                let page = Int(IOHIDElementGetUsagePage(element)), usage = Int(IOHIDElementGetUsage(element))
                let integer = IOHIDValueGetIntegerValue(value)
                guard integer != 0 else { return } // releases
                Unmanaged<OnboardPressListener>.fromOpaque(context).takeUnretainedValue()
                    .onPress(.value(page: page, usage: usage, value: integer))
            }, context)
            func prop(_ key: String) -> Int { IOHIDDeviceGetProperty(device, key as CFString) as? Int ?? 0 }
            let size = prop(kIOHIDMaxInputReportSizeKey)
            if prop(kIOHIDPrimaryUsagePageKey) == kHIDPage_GenericDesktop,
               prop(kIOHIDPrimaryUsageKey) == kHIDUsage_GD_Keyboard, size >= 16 {
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
                IOHIDDeviceRegisterInputReportCallback(device, buffer, size, { context, _, _, _, reportID, report, length in
                    guard let context else { return }
                    var bytes = Array(UnsafeBufferPointer(start: report, count: length))
                    // Some interfaces hand the id over separately; put it back in front.
                    if bytes.first != UInt8(truncatingIfNeeded: reportID) { bytes.insert(UInt8(truncatingIfNeeded: reportID), at: 0) }
                    Unmanaged<OnboardPressListener>.fromOpaque(context).takeUnretainedValue().onPress(.notice(bytes))
                }, context)
                buffers.append((device, buffer, size))
            }
            IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            open.append(device)
        }
        guard !open.isEmpty else {
            Unmanaged<OnboardPressListener>.fromOpaque(context).release()
            return false
        }
        selfContext = context
        self.pid = pid
        return true
    }

    func stop() {
        for entry in buffers {
            IOHIDDeviceRegisterInputReportCallback(entry.device, entry.buffer, entry.size, nil, nil)
            entry.buffer.deallocate()
        }
        buffers.removeAll()
        for device in open {
            IOHIDDeviceRegisterInputValueCallback(device, nil, nil)
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        open.removeAll()
        pid = nil
        if let context = selfContext {
            selfContext = nil
            Unmanaged<OnboardPressListener>.fromOpaque(context).release()
        }
    }

    deinit { stop() }
}
