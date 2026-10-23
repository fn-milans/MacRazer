// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import SwiftUI
import RazerProtocol

/// The profiles, in the title bar: the one in use as the label, and a menu to switch, add,
/// rename, reset or delete, with the full list a sheet away. A mouse that keeps its profiles in
/// slots (`usesSlotProfiles`) gets its slots; any other mouse its saved profiles.
struct ProfileMenu: View {
    @ObservedObject var controller: MouseController
    @ObservedObject var remapper: ButtonRemapper

    /// A name being asked for: a new profile, or a new name for the one in use.
    private enum NameRequest: Identifiable {
        case add, rename
        var id: Self { self }
    }

    private enum Confirmation: Identifiable {
        case reset, delete
        var id: Self { self }
    }

    @State private var nameRequest: NameRequest?
    @State private var name = ""
    @State private var confirmation: Confirmation?
    @State private var managing = false

    var body: some View {
        if controller.usesSlotProfiles || controller.supportsProfiles || controller.onboardSlotsUnread {
            menu
                .alert(nameRequest == .rename ? "Rename Profile" : "New Profile",
                       isPresented: Binding(get: { nameRequest != nil }, set: { if !$0 { nameRequest = nil } }),
                       presenting: nameRequest) { request in
                    TextField("Name", text: $name)
                    Button(request == .add ? "Add" : "Rename") { commitName(request) }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Cancel", role: .cancel) {}
                } message: { request in
                    Text(request == .add ? addMessage : "")
                }
                .confirmationDialog(confirmationTitle,
                                    isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
                                    titleVisibility: .visible, presenting: confirmation) { kind in
                    Button(kind == .reset ? "Reset" : "Delete", role: .destructive) { confirm(kind) }
                    Button("Cancel", role: .cancel) {}
                } message: { kind in
                    Text(kind == .reset
                         ? "Its settings and remaps go back to how the mouse came."
                         : "It is removed\(controller.usesSlotProfiles ? " from the mouse" : "").")
                }
                .sheet(isPresented: $managing) {
                    SheetPage(title: "Profiles", onDone: { managing = false }) {
                        if controller.usesSlotProfiles {
                            SlotProfilesList(controller: controller)
                        } else {
                            ProfilesView(controller: controller, remapper: remapper)
                        }
                    }
                }
        }
    }

    // MARK: Menu

    private var menu: some View {
        Menu {
            if controller.usesSlotProfiles {
                Section("In the mouse") {
                    ForEach(controller.onboardSlotList, id: \.self) { slot in
                        Toggle(controller.slotName(slot), isOn: Binding(
                            get: { controller.activeOnboardSlot == slot },
                            set: { if $0 { controller.switchToSlot(slot) } }))
                    }
                }
                Divider()
                Button("New Profile…") { ask(.add) }
                    .disabled(controller.onboardSlotList.count >= OnboardSlots.maxSlots)
                if let slot = controller.activeOnboardSlot {
                    Button("Rename “\(controller.slotName(slot))”…") { ask(.rename) }
                    Button("Reset “\(controller.slotName(slot))” to Factory…") { confirmation = .reset }
                    Button("Delete “\(controller.slotName(slot))”…") { confirmation = .delete }
                        .disabled(slot == Int(OnboardSlots.first))
                }
            } else if controller.onboardSlotsUnread {
                Text("Couldn't read the profiles from the mouse")
            } else {
                if !controller.profiles.isEmpty {
                    Section("Saved") {
                        ForEach(controller.profiles) { profile in
                            Toggle(profile.name, isOn: Binding(
                                get: { controller.activeProfileID == profile.id },
                                set: { if $0 { controller.applyProfile(profile, remapper: remapper) } }))
                        }
                    }
                    Divider()
                }
                Button("Save Current Setup as Profile…") { ask(.add) }
                    // 0 is "not read yet": a profile saved now would apply as 100 DPI.
                    .disabled(controller.dpi == 0)
                if let active = activeProfile {
                    Button("Rename “\(active.name)”…") { ask(.rename) }
                    Button("Delete “\(active.name)”…") { confirmation = .delete }
                }
            }
            if !controller.onboardSlotsUnread, controller.usesSlotProfiles || !controller.profiles.isEmpty {
                Divider()
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
        return activeProfile?.name ?? (controller.profiles.isEmpty ? "Profiles" : "No Profile")
    }

    private var activeProfile: MouseProfile? {
        controller.profiles.first { $0.id == controller.activeProfileID }
    }

    private var addMessage: String {
        controller.usesSlotProfiles
            ? "A new profile in the mouse, as it came from the factory."
            : "DPI, polling rate, lighting and button remaps as they are now."
    }

    private var confirmationTitle: String {
        let name = controller.usesSlotProfiles
            ? controller.activeOnboardSlot.map(controller.slotName) ?? "this profile"
            : activeProfile?.name ?? "this profile"
        return confirmation == .reset ? "Reset “\(name)” to factory?" : "Delete “\(name)”?"
    }

    // MARK: Actions

    private func ask(_ request: NameRequest) {
        switch request {
        case .add:
            if controller.usesSlotProfiles {
                let next = OnboardSlots.nextFreeSlot(existing: Set(controller.onboardSlotList)) ?? OnboardSlots.maxSlots
                name = SlotNames.defaultName(next)
            } else {
                let names = Set(controller.profiles.map(\.name))
                var i = controller.profiles.count + 1
                while names.contains("Profile \(i)") { i += 1 }
                name = "Profile \(i)"
            }
        case .rename:
            name = label
        }
        nameRequest = request
    }

    private func commitName(_ request: NameRequest) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        switch (request, controller.usesSlotProfiles) {
        case (.add, true): controller.addSlotProfile(name: trimmed)
        case (.add, false): controller.saveCurrentAsProfile(name: trimmed, remapper: remapper)
        case (.rename, true):
            if let slot = controller.activeOnboardSlot { controller.renameSlotProfile(slot, to: trimmed) }
        case (.rename, false):
            if let active = activeProfile { controller.renameProfile(active.id, to: trimmed) }
        }
    }

    private func confirm(_ kind: Confirmation) {
        if controller.usesSlotProfiles {
            guard let slot = controller.activeOnboardSlot else { return }
            if kind == .reset { controller.resetSlotProfile(slot) } else { controller.deleteSlotProfile(slot) }
        } else if let active = activeProfile, kind == .delete {
            controller.deleteProfile(active.id, remapper: remapper)
        }
    }
}
