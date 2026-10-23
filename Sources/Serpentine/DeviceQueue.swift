// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// The one serial queue everything the app says to the mouse goes through, in order, and the
/// bookkeeping that lets what the user asked for go first.
///
/// A serial queue is right for a device that answers one command at a time, but it means a
/// tap can sit behind work nobody asked for: opening the window alone issues six round-trips,
/// each with a receiver wait, so dragging the DPI slider a moment later waited out the better
/// part of a second before anything happened.
///
/// A background read can be abandoned safely, because the next poll does it again. A write
/// cannot. So reads check `userWorkPending` between round-trips and stop; writes never do.
final class DeviceQueue: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.github.fn-milans.serpentine.hid")
    private let lock = NSLock()
    /// How many user-initiated commands are waiting. Under `lock`.
    private var userWorkCount = 0

    /// True while a tap is waiting for the device.
    var userWorkPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return userWorkCount > 0
    }

    /// Background work: polls and reads.
    func async(_ body: @escaping @Sendable () -> Void) {
        queue.async(execute: body)
    }

    /// Something the user asked for, announced before it reaches the queue so a read already
    /// running can stand down.
    func user(_ body: @escaping @Sendable () -> Void) {
        lock.lock(); userWorkCount += 1; lock.unlock()
        queue.async { [self] in
            defer { lock.lock(); userWorkCount -= 1; lock.unlock() }
            body()
        }
    }
}
