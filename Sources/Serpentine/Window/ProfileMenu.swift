// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import SwiftUI
import RazerProtocol

/// The profiles, in the title bar: the one in use as the label, a menu to switch, and Manage
/// Profiles… for adding, renaming, resetting and deleting in a sheet. A mouse that keeps its
/// profiles in slots (`usesSlotProfiles`) gets its slots; any other mouse its saved profiles.
struct ProfileMenu: View {
    @ObservedObject var controller: MouseController
    @ObservedObject var remapper: ButtonRemapper

    @State private var managing = false
    @State private var adding = false

    var body: some View {
        if controller.usesSlotProfiles || controller.supportsProfiles || controller.onboardSlotsUnread {
            menu
                .sheet(isPresented: $managing) {
                    SheetPage(title: "Profiles", onDone: { managing = false }) {
                        if controller.usesSlotProfiles {
                            SlotProfilesList(controller: controller)
                        } else {
                            VStack(alignment: .leading, spacing: 16) {
                                // The + to save the current setup, and the chips to apply one.
                                QuickProfiles(controller: controller, remapper: remapper,
                                              isAddingProfile: $adding, onManage: nil)
                                if !controller.profiles.isEmpty {
                                    ProfilesView(controller: controller, remapper: remapper)
                                }
                            }
                        }
                    }
                }
        }
    }

    private var menu: some View {
        Menu {
            if controller.onboardSlotsUnread {
                Text("Couldn't read the profiles from the mouse")
            } else if controller.usesSlotProfiles {
                ForEach(controller.onboardSlotList, id: \.self) { slot in
                    Toggle(controller.slotName(slot), isOn: Binding(
                        get: { controller.activeOnboardSlot == slot },
                        set: { if $0 { controller.switchToSlot(slot) } }))
                }
            } else {
                ForEach(controller.profiles) { profile in
                    Toggle(profile.name, isOn: Binding(
                        get: { controller.activeProfileID == profile.id },
                        set: { if $0 { controller.applyProfile(profile, remapper: remapper) } }))
                }
            }
            if !controller.onboardSlotsUnread {
                if controller.usesSlotProfiles || !controller.profiles.isEmpty { Divider() }
                Button("Manage Profiles…") { managing = true }
            }
        } label: {
            Label(label, systemImage: "person.crop.square")
        }
        .labelStyle(.titleAndIcon)
        .help(controller.usesSlotProfiles ? "The mouse's profiles" : "Saved profiles")
        .disabled(!controller.connected)
    }

    private var label: String {
        if controller.usesSlotProfiles { return controller.activeOnboardSlot.map(controller.slotName) ?? "Profile" }
        return controller.profiles.first { $0.id == controller.activeProfileID }?.name
            ?? (controller.profiles.isEmpty ? "Profiles" : "No Profile")
    }
}
