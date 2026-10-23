// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// The mouse's button function table (`OnboardButtons`), over either link.
public protocol ButtonFunctionTable {
    func readButtonBlock(_ id: UInt8) throws -> [UInt8]
    /// Writes one entry and reads it back; throws when the mouse doesn't hold it afterwards.
    func writeButtonBlock(_ id: UInt8, block: [UInt8]) throws
    /// One entry of the HyperShift layer; nil when nothing was ever written there, so the
    /// standard layer's function applies.
    func readShiftedBlock(_ id: UInt8) throws -> [UInt8]?
    /// Writes one HyperShift-layer entry and reads it back; throws when the mouse doesn't
    /// hold it afterwards.
    func writeShiftedBlock(_ id: UInt8, block: [UInt8]) throws
}
