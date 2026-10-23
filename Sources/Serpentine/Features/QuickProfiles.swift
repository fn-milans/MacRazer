// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import SwiftUI
import AppKit
import RazerProtocol
import RazerDeviceKit

/// Quick-switch chips for saved profiles, or the mouse's own slots on a mouse that keeps them.
struct QuickProfiles: View {
    @ObservedObject var controller: MouseController
    @ObservedObject var remapper: ButtonRemapper
    /// The popover's: it ends adding when the row closes or disappears.
    @Binding var isAddingProfile: Bool
    var onManage: () -> Void
    @State private var newProfileName = ""

    var body: some View { profilesContent }

    /// Quick-switch chips, shown when the Profiles row is expanded: a chip per saved profile
    /// (filled green when active) plus a "+" chip to save the current setup. Switching never
    /// needs a page navigation; only the rarely-needed rename/delete flow lives behind
    /// "Manage Profiles…". A mouse whose slots are its profiles lists and manages them right
    /// here instead (`SlotProfilesList`).
    private var profilesContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if controller.usesSlotProfiles {
                // The mouse's slots are its profiles, listed and managed right here.
                SlotProfilesList(controller: controller)
            } else if controller.onboardSlotsUnread {
                // Its profiles live in the mouse; never offer app-side snapshots instead.
                Text("Couldn't read the profiles from the mouse. If they don't appear in a moment, reconnect the mouse.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if controller.profiles.isEmpty && !isAddingProfile {
                HStack(spacing: 8) {
                    Text("Save your current setup as a profile")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    addProfileChip
                }
            } else {
                // Wraps to new rows — a plain HStack overflows the fixed-width popover
                // once a handful of profiles exist.
                FlowLayout(spacing: 6) {
                    ForEach(controller.profiles) { profileChip($0) }
                    if !isAddingProfile { addProfileChip }
                }
            }
            if isAddingProfile, !controller.onboardSlotsUnread { addProfileField }
            if controller.profileApplyFailed, !controller.usesSlotProfiles, !controller.onboardSlotsUnread {
                Text("Couldn't apply that. The mouse isn't responding.")
                    .font(.system(size: 10.5)).foregroundStyle(Color.batteryLow)
            }
            if !controller.profiles.isEmpty, !controller.usesSlotProfiles, !controller.onboardSlotsUnread {
                Button("Manage Profiles…") { onManage() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.razerGreenText)
            }
        }
    }

    private func profileChip(_ profile: MouseProfile) -> some View {
        let active = profile.id == controller.activeProfileID
        return Button {
            // Local effect/color state follows via the activeProfileID onChange once the
            // apply actually succeeds — nothing optimistic here.
            controller.applyProfile(profile, remapper: remapper)
        } label: {
            Text(profile.name)
                .padding(.horizontal, 10)
                .frame(maxHeight: .infinity)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .font(.system(size: 10.5, weight: active ? .semibold : .regular))
        .foregroundStyle(active ? Color.onRazerGreen : Color.secondary)
        .frame(height: 24)
        .background(active ? Color.razerGreen : Color.primary.opacity(0.08), in: Capsule())
        .hoverHighlight(Capsule())
        .lineLimit(1)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    /// Default name that never collides with an existing profile (count+1 repeats after
    /// deletions).
    private var suggestedProfileName: String {
        let names = Set(controller.profiles.map(\.name))
        var i = controller.profiles.count + 1
        while names.contains("Profile \(i)") { i += 1 }
        return "Profile \(i)"
    }

    private var addProfileChip: some View {
        Button {
            newProfileName = suggestedProfileName
            isAddingProfile = true
        } label: {
            // The circle is part of the label, so the whole of it takes the click, not just
            // the glyph a plain button would otherwise hit-test.
            Image(systemName: "plus").font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.razerGreenText)
                .frame(width: 24, height: 24)
                .background(Color.razerGreen.opacity(0.12), in: Circle())
                .overlay(Circle().stroke(Color.razerGreen.opacity(0.55), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        // dpi == 0 = the first settings read hasn't landed yet; a snapshot taken now
        // would save a profile that later applies as 100 DPI.
        .disabled(controller.dpi == 0)
        .help(controller.dpi == 0 ? "Waiting for the mouse's current settings…" : "Save current setup as a profile")
    }

    private var addProfileField: some View {
        HStack(spacing: 6) {
            TextField("Profile name", text: $newProfileName, onCommit: saveNewProfile)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            Button("Save", action: saveNewProfile)
                .buttonStyle(RazerProminentButtonStyle())
                .controlSize(.small)
                .disabled(newProfileName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel") { isAddingProfile = false }
                .buttonStyle(.plain)
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .transition(.opacity)
    }

    private func saveNewProfile() {
        let name = newProfileName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        controller.saveCurrentAsProfile(name: name, remapper: remapper)
        isAddingProfile = false
    }

}
