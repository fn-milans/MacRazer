// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import SwiftUI
import AppKit
import RazerProtocol
import RazerDeviceKit

extension MouseController {
    /// The mouse reports 0 when it hasn't answered yet; the controls show that as 1000, the
    /// firmware default, and so does everything that reads it.
    var displayedPollRate: Int { pollRate == 0 ? 1000 : pollRate }
}

/// The polling rate picker, with what the chosen rate is good for.
struct PollingRateControls: View {
    @ObservedObject var controller: MouseController

    var body: some View { pollContent }

    private var pollRates: [Int] {
        controller.capabilities.pollingRates
    }

    /// The Polling rate row's expanded content; the row itself shows the current rate.
    private var pollContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: Binding(
                get: { displayedPollRate },
                set: { controller.setPollRate($0) }
            )) {
                ForEach(pollRates, id: \.self) { Text(verbatim: "\($0)").tag($0) }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .labelsHidden()
            .frame(maxWidth: .infinity)

            if let tip = pollRateTip(displayedPollRate) {
                Text(tip)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showsPollRateBatteryHint {
                Label("1000 Hz uses the most battery. 500 Hz feels about the same "
                      + "for everyday use.", systemImage: "leaf")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
    }

    private var displayedPollRate: Int { controller.displayedPollRate }

    /// What the selected rate is good for. The battery trade-off is only mentioned for a
    /// mouse that has one: on a wired mouse it's a promise about nothing.
    private func pollRateTip(_ hz: Int) -> String? {
        let battery = controller.deviceHasBattery
        switch hz {
        case 2000, 4000, 8000:
            return battery ? "HyperPolling: the quickest response, best on a high refresh rate display. "
                             + "Uses the battery much faster and more CPU."
                           : "HyperPolling: the quickest response, best on a high refresh rate display. Uses more CPU."
        case 1000: return "Smoothest and quickest to respond. Best for gaming."
        case 250: return battery ? "Easy on the battery, still smooth for everyday work."
                                 : "Smooth enough for everyday work."
        case 500: return battery ? "Smooth for everyday work, and easier on the battery."
                                 : "Smooth for everyday work."
        case 125: return battery ? "Lasts longest on a charge. The pointer can feel less smooth, "
                                    + "especially on high refresh rate displays."
                                 : "The pointer can feel less smooth, especially on high "
                                    + "refresh rate displays."
        default: return nil
        }
    }

    /// Same conditions as the lighting hint: a battery mouse, not charging. Reads the raw
    /// `controller.pollRate`, not `displayedPollRate`: 0 means the rate hasn't been read yet,
    /// and advising a switch to 500 Hz on a mouse that may already be there reads as broken.
    private var showsPollRateBatteryHint: Bool {
        controller.deviceHasBattery && !controller.charging && controller.pollRate == 1000
    }

}
