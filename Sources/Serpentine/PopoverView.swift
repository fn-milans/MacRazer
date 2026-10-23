// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import SwiftUI
import AppKit
import RazerProtocol
import RazerDeviceKit

/// Reports the main page's measured height so the popover can size to it.
private struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct PopoverView: View {
    @ObservedObject var controller: MouseController
    @ObservedObject var remapper: ButtonRemapper
    var launchAtLogin: LaunchAtLogin
    /// Settings › Appearance; only the Razer Green glass edge is drawn here. The rest is the
    /// popover's appearance and backdrop, which the app delegate sets.
    @ObservedObject var appearance: AppearanceSettings
    @Environment(\.colorScheme) private var colorScheme
    /// Opening a window is the owner's job — the popover doesn't know about window controllers.
    /// Deliberately not defaulted: a no-op default would let a future call site forget the
    /// handler and ship a gear button that depresses and does nothing, with no compiler error.
    /// The preview passes an explicit `{}`.
    var onOpenSettings: () -> Void

    enum Page { case main, color, buttons, usage, profiles }
    @State private var page: Page = .main
    /// The popover is on screen. Its hosting controller outlives each showing, so views here
    /// stay mounted while it's closed; anything periodic has to check this.
    @State private var isShown = false
    @State private var brightnessValue: Double = 100
    /// Local mirror of `controller.lightingColor` — only because `ColorPickerPage` needs a
    /// `Binding<Color>`. The controller's published value is the source of truth (lighting
    /// state is device-confirmed there); this follows it via `onChange`.
    @State private var color: Color = .razerGreen
    @State private var versionHovered = false
    @State private var gearHovered = false

    /// Popover sizes to the MAIN page content (no empty space); sub-pages match that height
    /// (but never less than `subPageMinHeight`). Buttons page scrolls if taller; colour page
    /// is centred.
    private let popoverWidth: CGFloat = 320
    /// With its sections collapsed the main page can be short, and sub-pages that scroll (the
    /// usage charts, the button list) would be squeezed into it. Below this they grow instead.
    /// Not the colour page: it's a fixed-size picker, centred, and would only gain empty space.
    private let subPageMinHeight: CGFloat = 560
    @State private var mainHeight: CGFloat = 0
    @State private var isAddingProfile = false
    @State private var sleepTimeoutValue: Double = 300
    @State private var lowBatteryValue: Double = 33
    /// The corner radius NSPopover gives its body, so the green edge sits on the outline.
    /// Measured from a capture on macOS 26; the content view is exactly the body.
    static let popoverCornerRadius: CGFloat = 10

    var body: some View {
        ZStack {
            switch page {
            case .main: mainPage.transition(.move(edge: .leading))
            case .color: colorPage.transition(.move(edge: .trailing))
            case .buttons: buttonsPage.transition(.move(edge: .trailing))
            case .usage: usagePage.transition(.move(edge: .trailing))
            case .profiles: profilesPage.transition(.move(edge: .trailing))
            }
        }
        .frame(width: popoverWidth)
        .frame(height: page == .main ? nil : (mainHeight > 0 ? max(mainHeight, page == .color ? 0 : subPageMinHeight) : nil))
        // While a sub-page is showing, the main page is unmounted and the preference reverts
        // to its 0 default — keep the last real measurement so sub-pages stay locked to the
        // main page's height instead of resizing once the transition finishes.
        .onPreferenceChange(HeightKey.self) { if $0 > 0 { mainHeight = $0 } }
        .animation(.easeInOut(duration: 0.26), value: page)
        .overlay {
            if appearance.look(systemIsDark: colorScheme == .dark).hasGreenEdge {
                // Follows the body's rounded outline; the arrow above it has no edge.
                RoundedRectangle(cornerRadius: Self.popoverCornerRadius)
                    .strokeBorder(Color.razerGreen.opacity(0.45), lineWidth: 1)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
        // Closing the popover resets navigation: reopening onto a stale sub-page (whose
        // gating card may have been disabled in the meantime — e.g. Profiles after a
        // disconnect) is disorienting.
        .onAppear { isShown = true }
        .onDisappear { page = .main; isShown = false }
    }

    // MARK: Sub-pages

    private var colorPage: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            ColorPickerPage(color: $color, onBack: { page = .main }) { rgb in
                controller.setStaticColor(rgb)
            }
            .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
        }
    }

    private var buttonsPage: some View {
        // Isolated behind .equatable() so the controller's legitimate periodic publishes
        // (a new battery sample every ~15s while discharging) can't re-render this subtree:
        // a re-render dismisses an open SwiftUI Menu, collapsing the shortcut picker while
        // the user is still choosing. This page only depends on the remapper, whose own
        // publishes (detected buttons, mappings) still update it normally.
        ButtonsPage(controller: controller, remapper: remapper, onBack: { page = .main }).equatable()
    }

    private struct ButtonsPage: View, Equatable {
        let controller: MouseController
        let remapper: ButtonRemapper
        let onBack: () -> Void

        /// The closure is deliberately excluded: it's recreated on every parent render and
        /// always does the same thing (navigate back).
        nonisolated static func == (a: Self, b: Self) -> Bool { a.remapper === b.remapper }

        var body: some View {
            ScrollView {
                RemapView(remapper: remapper, controller: controller, onBack: onBack)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var usagePage: some View {
        ScrollView {
            UsageGraphView(controller: controller, onBack: { page = .main })
                .frame(maxWidth: .infinity)
        }
    }

    private var profilesPage: some View {
        ScrollView {
            ProfilesView(controller: controller, remapper: remapper, onBack: { page = .main })
                .frame(maxWidth: .infinity)
        }
    }

    /// ⌘R — the same shortcut the right-click menu's "Refresh Now" shows. Bound once for the
    /// whole main page rather than to a control inside one card, so it works whichever cards
    /// are showing (a mouse without a battery has no battery card and no refresh button).
    private var refreshShortcut: some View {
        Button("Refresh") { controller.refreshAll() }
            .keyboardShortcut("r")
            .disabled(controller.isRefreshing)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    private var mainPage: some View {
        VStack(alignment: .leading, spacing: 10) {
            DeviceHeaderCard(controller: controller)
            // A Razer mouse on Bluetooth can't be controlled (no control protocol over BT) —
            // explain it instead of just showing "offline".
            if controller.bluetoothMouse != nil && !controller.connected { BluetoothNoticeCard(controller: controller) }
            if controller.noMouseKnown {
                // A last reading is still worth showing (the snapshot is persisted, so most
                // returning users have one); the empty-state card still says what to do.
                if controller.lastBatterySnapshot != nil { batteryCard.opacity(0.55) }
                NoMouseCard(controller: controller)
            } else {
                // Battery stays readable (last-known) but dims when offline; its refresh button
                // stays active so you can retry.
                if controller.deviceHasBattery {
                    batteryCard.opacity(controller.connected ? 1 : 0.55)
                }
                // Live mouse-config sections: dim AND disable while disconnected.
                DPICard(controller: controller)
                    .disabled(!controller.connected)
                    .opacity(controller.connected ? 1 : 0.45)
                // Dims with DPI, but its rows still open and close offline so the last-known
                // settings stay readable; the controls inside them (and the Buttons page,
                // which needs the mouse) are what's disabled.
                settingsGroup
                    .opacity(controller.connected ? 1 : 0.45)
            }
            footer
        }
        .padding(12)
        .frame(width: popoverWidth)
        .background(refreshShortcut)
        .background(GeometryReader { g in Color.clear.preference(key: HeightKey.self, value: g.size.height) })
        .onAppear {
            brightnessValue = Double(controller.brightness)
            if let timeout = controller.sleepTimeout { sleepTimeoutValue = Double(timeout) }
            if let threshold = controller.lowBatteryThreshold { lowBatteryValue = Double(threshold) }
            color = controller.lightingColor.swiftUIColor
        }
        .onChange(of: controller.lightingColor) { _, new in color = new.swiftUIColor }
        .onChange(of: controller.brightness) { _, new in brightnessValue = Double(new) }
        // A failed device write leaves the controller's values unchanged, so no value-driven
        // onChange fires — snap the optimistic slider state back to reality explicitly.
        .onChange(of: controller.lastWriteFailure) { _, _ in
            brightnessValue = Double(controller.brightness)
            if let timeout = controller.sleepTimeout { sleepTimeoutValue = Double(timeout) }
            if let threshold = controller.lowBatteryThreshold { lowBatteryValue = Double(threshold) }
        }
        // A half-typed profile name shouldn't survive its row closing and reappear later.
        .onChange(of: expandedSections.contains(.profiles)) { _, open in
            if !open { isAddingProfile = false }
        }
        // …or when the row disappears instead of closing (a mouse without profiles).
        .onChange(of: controller.supportsProfiles) { _, supported in
            if !supported { isAddingProfile = false }
        }
        .onChange(of: controller.sleepTimeout) { _, new in if let new { sleepTimeoutValue = Double(new) } }
        .onChange(of: controller.lowBatteryThreshold) { _, new in if let new { lowBatteryValue = Double(new) } }
    }

    private var batteryCard: some View {
        BatteryCard(controller: controller, isShown: isShown, onShowUsage: { page = .usage })
    }

    // MARK: Grouped settings

    /// The settings below DPI, each a compact card of its own, the way Control Center lists
    /// its modules. A row shows its current value; the settings rows expand in place to
    /// their controls, each independently of the others, and Buttons opens its page. Which
    /// sections are open is remembered across showings.
    private enum DisclosureSection: String, CaseIterable { case polling, lighting, power, profiles }
    private enum GroupRow: Hashable { case section(DisclosureSection), buttons }
    /// The open sections, comma-separated: `@AppStorage` can't hold a set.
    @AppStorage(Preferences.popoverExpandedSections) private var expandedSectionsRaw = ""
    private var expandedSections: Set<DisclosureSection> {
        Set(expandedSectionsRaw.split(separator: ",").compactMap { DisclosureSection(rawValue: String($0)) })
    }

    private func toggle(_ section: DisclosureSection) {
        var open = expandedSections
        if open.contains(section) { open.remove(section) } else { open.insert(section) }
        // Written in declaration order so the stored string is stable.
        expandedSectionsRaw = DisclosureSection.allCases.filter { open.contains($0) }.map(\.rawValue).joined(separator: ",")
    }

    /// Rows in display order, skipping what this mouse can't do. Profiles come last: they
    /// bundle the rows above them (plus remaps) into presets.
    private var groupRows: [GroupRow] {
        var rows: [GroupRow] = []
        if controller.supportsPollRate { rows.append(.section(.polling)) }
        if controller.deviceHasLighting { rows.append(.section(.lighting)) } // none on e.g. the Atheris
        if controller.supportsSleepTimeout || controller.lowBatteryThreshold != nil { rows.append(.section(.power)) }
        rows.append(.buttons)
        if controller.supportsProfiles { rows.append(.section(.profiles)) }
        return rows
    }

    private var settingsGroup: some View {
        let rows = groupRows
        // Same 10 pt rhythm as the cards above, so each section reads as its own card.
        return VStack(spacing: 10) {
            // Keyed by row, not position, so a row appearing or vanishing (another mouse, the
            // poll rate turning out to be supported) doesn't shift the others' identity.
            ForEach(rows, id: \.self) { row in
                // Each row is its own card, open or closed, rather than one card split by
                // separators: an open section's controls stay clearly inside their row.
                cardSurface(Group {
                    switch row {
                    case .section(.polling):
                        disclosureRow(.polling, title: "Polling rate", symbol: "timer", tint: .blue,
                                      value: "\(controller.displayedPollRate) Hz") {
                            PollingRateControls(controller: controller)
                        }
                    case .section(.lighting):
                        disclosureRow(.lighting, title: "Lighting", symbol: "light.max", tint: .orange,
                                      value: LightingControls.summary(controller, brightness: brightnessValue)) {
                            LightingControls(controller: controller, brightnessValue: $brightnessValue,
                                             color: $color, onPickColor: { page = .color })
                        }
                    case .section(.power):
                        disclosureRow(.power, title: "Power Management", symbol: "moon.zzz", tint: .indigo,
                                      value: controller.supportsSleepTimeout
                                          ? PowerControls.sleepTimeoutSummary(controller, value: sleepTimeoutValue)
                                          : PowerControls.lowBatterySummary(controller, value: lowBatteryValue),
                                      valueColor: controller.sleepTimeoutError == nil ? .secondary : .batteryLow) {
                            PowerControls(controller: controller, sleepTimeoutValue: $sleepTimeoutValue,
                                          lowBatteryValue: $lowBatteryValue)
                        }
                    case .section(.profiles):
                        disclosureRow(.profiles, title: "Profiles", symbol: "person.crop.square.on.square.angled",
                                      tint: .purple, value: profilesSummary,
                                      valueColor: controller.profileApplyFailed ? .batteryLow : .secondary) {
                            QuickProfiles(controller: controller, remapper: remapper,
                                          isAddingProfile: $isAddingProfile, onManage: { page = .profiles })
                        }
                    case .buttons:
                        Button { page = .buttons } label: {
                            groupRowLabel(title: "Buttons", symbol: "keyboard", tint: .razerGreenText,
                                          value: buttonsSummary,
                                          valueColor: buttonsNeedAccess ? .batteryMid : .secondary,
                                          expanded: false)
                        }
                        .buttonStyle(.plain)
                        .disabled(!controller.connected)
                        .accessibilityLabel("Configure Buttons")
                        .accessibilityValue(buttonsSummary)
                    }
                }
                .frame(maxWidth: .infinity))
            }
        }
    }

    private func disclosureRow<Content: View>(_ section: DisclosureSection, title: String, symbol: String,
                                              tint: Color, value: String, valueColor: Color = .secondary,
                                              @ViewBuilder content: () -> Content) -> some View {
        let expanded = expandedSections.contains(section)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { toggle(section) }
            } label: {
                groupRowLabel(title: title, symbol: symbol, tint: tint, value: value,
                              valueColor: valueColor, expanded: expanded)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(value)
            .accessibilityHint(expanded ? "Collapses the \(title) settings" : "Shows the \(title) settings")
            if expanded {
                content()
                    .disabled(!controller.connected)
                    .padding(.horizontal, 12)
                    // Clear of the header, so a still-highlighted header doesn't sit right on
                    // top of the controls it opened.
                    .padding(.top, 6)
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }
        }
    }

    /// One row of the group: a tinted icon, the name, the current value and a chevron that
    /// turns down while the row is expanded.
    private func groupRowLabel(title: String, symbol: String, tint: Color, value: String,
                               valueColor: Color, expanded: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(tint.opacity(0.22), in: RoundedRectangle(cornerRadius: 6))
            Text(title).font(.system(size: 12, weight: .medium))
            Spacer(minLength: 6)
            Text(value)
                .font(.system(size: 11.5)).monospacedDigit()
                .foregroundStyle(valueColor)
                .lineLimit(1)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
        }
        // The hover wash is an inset rounded shape, like a menu item's or a Control Center
        // row's, rather than an edge-to-edge band: a full-width band ran past the inset
        // separators and read as unfinished. Same 12 × 9 overall padding as before.
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .hoverHighlight(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }

    /// Saved remaps do nothing without Accessibility access and the event tap, so the row
    /// says so instead of counting them.
    private var buttonsNeedAccess: Bool {
        !remapper.remappingPermissionsGranted && !remapper.mappings.values.filter { $0 != .passthrough }.isEmpty
    }

    private var buttonsSummary: String {
        if buttonsNeedAccess { return "Needs access" }
        // Resetting a button to "Default" stores `.passthrough` rather than removing it.
        let count = remapper.mappings.values.filter { $0 != .passthrough }.count
        return count == 0 ? "" : "\(count) remapped"
    }

    private var profilesSummary: String {
        // A failed apply turns this red (see the row) rather than replacing it, so the row
        // still says which profile is actually active; the error text is in the expanded
        // section.
        // A mouse whose slots are its profiles is always on one of them.
        if controller.usesSlotProfiles {
            return controller.activeOnboardSlot.map(controller.slotName) ?? ""
        }
        if controller.profiles.isEmpty { return "None saved" }
        return controller.profiles.first { $0.id == controller.activeProfileID }?.name ?? "None active"
    }

    // MARK: Footer

    private var appVersion: String { AppInfo.displayVersion }

    private var footer: some View {
        HStack(spacing: 4) {
            Link(destination: ProjectLinks.releases) {
                Text(verbatim: "v\(appVersion)")
                    .font(.system(size: 11))
                    // Nothing at rest marks it as a link — the footer should stay quiet — so
                    // hover has to carry the whole affordance: colour and underline together,
                    // since colour alone is easy to miss at 11pt in tertiary grey.
                    .foregroundStyle(versionHovered ? AnyShapeStyle(Color.razerGreenText) : AnyShapeStyle(.tertiary))
                    .underline(versionHovered)
            }
            .buttonStyle(.plain)
            .onHover { versionHovered = $0 }
            .help("Open Serpentine's releases on GitHub")
            Text(verbatim: "· unofficial").font(.system(size: 11)).foregroundStyle(.tertiary)
            Spacer()
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12.5))
                    // Same hover treatment as the version link beside it — a footer this
                    // quiet needs the cue, and two different ones would be noise.
                    .foregroundStyle(gearHovered ? AnyShapeStyle(Color.razerGreenText) : AnyShapeStyle(.secondary))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { gearHovered = $0 }
            .help("Serpentine settings (⌘,)")
            .accessibilityLabel("Settings")
            // The same shortcut as the right-click menu's "Settings…", and every Mac app's.
            .keyboardShortcut(",")
            .padding(.trailing, 6)
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }
}


