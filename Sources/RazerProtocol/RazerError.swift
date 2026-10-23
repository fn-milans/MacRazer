// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// Why a command to the mouse failed, on any link. The `Int32` codes are IOKit's `IOReturn`.
public enum RazerError: Error, CustomStringConvertible {
    case notFound
    case openFailed(Int32)
    case setReportFailed(Int32)
    case getReportFailed(Int32)
    case badResponse
    case timeout
    case commandFailed
    case notSupported

    public var description: String {
        func hex(_ r: Int32) -> String { String(format: "0x%08x", UInt32(bitPattern: r)) }
        switch self {
        case .notFound: return "No Razer mouse found on USB (is the cable or 2.4GHz dongle plugged in?)"
        case .openFailed(let r): return "IOHIDDeviceOpen failed: \(hex(r))"
        case .setReportFailed(let r): return "SetReport failed: \(hex(r))"
        case .getReportFailed(let r): return "GetReport failed: \(hex(r))"
        case .badResponse: return "Malformed or mismatched response report"
        case .timeout: return "Device command timed out (known-finicky over the wireless dongle)"
        case .commandFailed: return "Device reported the command failed (status 0x03)"
        case .notSupported: return "Device reports the command as not supported (status 0x05)"
        }
    }
}
