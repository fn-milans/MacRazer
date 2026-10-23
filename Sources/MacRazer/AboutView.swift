// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import SwiftUI

/// About MacRazer.
///
/// More than a version number, because this app has things it genuinely owes the people
/// reading it: it uses Razer's trademarks descriptively and must say it isn't Razer's, and its
/// mouse protocol was ported from OpenRazer — which is why the project is GPL at all, and why
/// their credit belongs somewhere a user can actually see rather than only in `NOTICE.md`.
struct AboutView: View {
    /// Not optional: a defaulted no-op would let a caller ship a Done button that depresses
    /// and does nothing, with no compiler error.
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            unofficialSection
            openRazerSection
            licenseSection
            footer
        }
        .padding(22)
        .frame(width: 460)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 13).fill(Color.razerGreenBright.opacity(0.20))
                Image(nsImage: MenuBarIcon.mouse(pointSize: 32, razerCutout: true))
                    .renderingMode(.template).resizable().scaledToFit()
                    .frame(width: 32, height: 32)
                    .foregroundStyle(Color.razerGreenBright)
            }
            .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text("MacRazer").font(.system(size: 22, weight: .semibold))
                Text("Version \(AppInfo.displayVersion) (build \(AppInfo.displayBuild))")
                    .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                // The credit for the project this was forked from.
                HStack(spacing: 4) {
                    Text("A fork of").font(.system(size: 12)).foregroundStyle(.secondary)
                    Link("MacRazer by SorcRR", destination: ProjectLinks.original)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.razerGreenText)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Sections

    private var unofficialSection: some View {
        titledSection("Unofficial") {
            sectionNote("An independent community project. Not affiliated with, authorized by, "
                        + "or endorsed by Razer Inc.")
            // "Used here only to describe compatibility" is the conventional descriptive-use
            // wording and the reason this app may put Razer's marks on screen at all, so it
            // stays as written. Only the semicolon became a full stop.
            sectionNote("“Razer”, “Cobra”, “HyperSpeed”, “Synapse” and “Chroma” are trademarks of "
                        + "Razer Inc., used here only to describe compatibility. The app's mouse "
                        + "mark is its own. It does not display Razer's logo.")
        }
    }

    private var openRazerSection: some View {
        titledSection("Built on OpenRazer") {
            sectionNote("Everything this app says to your mouse was ported from OpenRazer's Linux "
                        + "driver: the command bytes, the report structure, the CRC, the Cobra "
                        + "command set. They did the hard reverse engineering.")
            sectionNote("Cobra HyperSpeed support follows their PR #2583 by dyharlan, reviewed by "
                        + "z3ntu, which worked out that the mouse reuses the Cobra Pro protocol.")
            HStack(spacing: 14) {
                Link("OpenRazer", destination: ProjectLinks.openRazer)
                Link("PR #2583", destination: ProjectLinks.cobraHyperSpeedPR)
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Color.razerGreenText)
        }
    }

    private var licenseSection: some View {
        titledSection("License") {
            sectionNote("GPL-2.0-or-later. It has to be GPL, because it builds on OpenRazer, "
                        + "which is GPL.")
            sectionNote("Provided as is, with no warranty of any kind. It talks to your mouse over "
                        + "HID and only sends the same feature reports OpenRazer and Synapse do, "
                        + "but you run it at your own risk.")
            Link("View the source", destination: ProjectLinks.repo)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.razerGreenText)
        }
    }

    // MARK: Footer

    /// Issues rather than an email address: reports land somewhere they can be tracked, and
    /// there is no address in a public binary for scrapers to harvest.
    private var footer: some View {
        HStack(spacing: 10) {
            Link(destination: ProjectLinks.issues) {
                Label("Report an Issue", systemImage: "exclamationmark.bubble")
            }
            .buttonStyle(.bordered)
            Spacer(minLength: 0)
            Button("Done") { onDone() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(RazerProminentButtonStyle())
        }
        .controlSize(.small)
        .font(.system(size: 11.5))
    }
}
