// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import SwiftUI
import AppKit
import RazerProtocol
import RazerDeviceKit

/// DPI: a mouse with DPI modes gets Single and Stages (`dpiModesCard`), the rest the preset
/// stages, a slider and a recallable custom value (`presetDpiCard`).
struct DPICard: View {
    @ObservedObject var controller: MouseController

    @State private var dpiValue: Double = 1600
    /// Recallable custom DPI — persisted per-mouse, and never above the mouse's max.
    @State private var customDPI: Int = 8000
    @State private var editingDpiStage: Int?
    @State private var editingDpiValue = false
    @State private var dpiStageDraft = ""
    @State private var dpiStageError: String?
    @FocusState private var dpiStageFieldFocused: Bool

    private let defaultStages = [400, 800, 1600, 3200, 6400]
    /// The connected mouse's actual configured DPI stages, or sensible defaults.
    private var displayedStages: [Int] {
        controller.dpiStages.isEmpty ? defaultStages : controller.dpiStages
    }

    var body: some View {
        dpiCard
            .onAppear {
                if controller.dpi != 0 { dpiValue = Double(controller.dpi) }
                loadCustomDPI()
            }
            .onChange(of: controller.dpi) { _, new in if new != 0 { dpiValue = Double(new) } }
            // A failed device write leaves the controller's values unchanged, so no value-driven
            // onChange fires — snap the optimistic slider state back to reality explicitly.
            .onChange(of: controller.lastWriteFailure) { _, _ in
                if controller.dpi != 0 { dpiValue = Double(controller.dpi) }
            }
            .onChange(of: controller.deviceKey) { _, _ in loadCustomDPI() } // reload/clamp per mouse
            .onChange(of: controller.deviceMaxDPI) { _, _ in loadCustomDPI() }
    }

    private var supportsBasiliskBluetooth: Bool {
        controller.capabilities.stageEditingOverBluetooth
    }

    // MARK: Custom DPI (per-mouse, clamped to the model's max)

    /// nil while no device key is known — persisting then would land in a "default" slot
    /// shared by every mouse and never migrated to the real key once it resolves.
    private var deviceSettings: DeviceSettings? {
        controller.deviceKey.map { DeviceSettings(deviceKey: $0) }
    }

    private func loadCustomDPI() {
        let stored = deviceSettings?.customDPI ?? min(8000, controller.deviceMaxDPI)
        let clamped = min(max(stored, 100), controller.deviceMaxDPI) // reset if it exceeds this mouse's max
        customDPI = clamped
        if clamped != stored { deviceSettings?.customDPI = clamped }
    }

    private func saveCustomDPI(_ value: Int) {
        customDPI = value
        deviceSettings?.customDPI = value
    }

    private var dpiCard: some View {
        Group {
            if controller.supportsDpiModes { dpiModesCard } else { presetDpiCard }
        }
    }

    // MARK: DPI modes (Single / Stages)

    /// The DPI card of a mouse with DPI modes: one value, or five stages with one active,
    /// held in the mouse's stage table so it looks and works the same on every link. The
    /// slider and the number edit the DPI in use: the single value, or the active stage.
    private var dpiModesCard: some View {
        let single = controller.dpiStages.count == 1
        return card {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("DPI", "scope")
                Spacer()
                dpiValueField
            }
            Picker("", selection: Binding(
                get: { single },
                set: { setDpiMode(single: $0) }
            )) {
                Text("Single").tag(true)
                Text("Stages").tag(false)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .disabled(controller.dpiStages.isEmpty || controller.isUpdatingDpiStages)
            Slider(value: snapped($dpiValue, to: 50, from: 100), in: 100...Double(controller.deviceMaxDPI)) { editing in
                if !editing { setCurrentDPI(Int(dpiValue)) }
            }
            .tint(.razerGreen)
            .controlSize(.small)
            .disabled(controller.dpiStages.isEmpty)
            if !single && !controller.dpiStages.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(controller.dpiStages.enumerated()), id: \.offset) { index, value in
                        stageChip(value, index: index)
                    }
                }
            }
            if let dpiStageError {
                Text(dpiStageError).font(.system(size: 10.5)).foregroundStyle(Color.batteryLow)
            } else if let error = controller.dpiStagesError {
                Text(error).font(.system(size: 10.5)).foregroundStyle(Color.batteryLow)
            }
        }
        }
    }

    /// The DPI in use, which a click turns into a field for typing an exact value.
    private var dpiValueField: some View {
        Group {
            if editingDpiValue {
                TextField("DPI", text: $dpiStageDraft)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 60)
                    .focused($dpiStageFieldFocused)
                    .onSubmit { commitDpiValue() }
                    .onExitCommand { editingDpiValue = false }
                    .onAppear { dpiStageFieldFocused = true }
            } else {
                Button {
                    guard !controller.dpiStages.isEmpty else { return }
                    dpiStageError = nil
                    dpiStageDraft = String(Int(dpiValue))
                    editingDpiStage = nil
                    editingDpiValue = true
                } label: { Text(verbatim: "\(Int(dpiValue))") }
                .buttonStyle(.plain)
                .help("Click to type an exact DPI")
            }
        }
        .font(.system(size: 12, weight: .medium)).monospacedDigit()
        .onChange(of: dpiStageFieldFocused) { _, focused in if !focused { editingDpiValue = false } }
    }

    /// One stage: a click makes it active, Edit DPI in its menu changes its value.
    private func stageChip(_ value: Int, index: Int) -> some View {
        let active = controller.activeDpiStage == index
        let editing = editingDpiStage == index
        return Group {
            if editing {
                TextField("DPI", text: $dpiStageDraft)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .monospacedDigit()
                    .focused($dpiStageFieldFocused)
                    .onSubmit { commitStageValue(index: index) }
                    .onExitCommand { editingDpiStage = nil }
                    .onAppear { dpiStageFieldFocused = true }
            } else {
                Button {
                    guard !active else { return }
                    dpiValue = Double(value)
                    controller.setDPITable(controller.dpiStages, active: index)
                } label: {
                    Text(verbatim: "\(value)")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .font(.system(size: 10.5, weight: active ? .semibold : .regular).monospacedDigit())
        .foregroundStyle(active ? Color.onRazerGreen : Color.secondary)
        .frame(maxWidth: .infinity)
        .frame(height: 24)
        .background(active ? Color.razerGreen : Color.primary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 6))
        .hoverHighlight(RoundedRectangle(cornerRadius: 6))
        .contextMenu {
            Button("Edit DPI") {
                dpiStageError = nil
                dpiStageDraft = String(value)
                editingDpiValue = false
                editingDpiStage = index
                dpiStageFieldFocused = true
            }
        }
        .help("Stage \(index + 1) · Right-click to edit")
        .accessibilityLabel(editing ? "Stage \(index + 1) DPI" : "\(value) DPI, stage \(index + 1)")
        .accessibilityAddTraits(active ? .isSelected : [])
        .disabled(controller.isUpdatingDpiStages || (editingDpiStage != nil && !editing))
    }

    /// A typed DPI, or nil with the reason shown under the card.
    private func typedDPI() -> Int? {
        guard let value = Int(dpiStageDraft.trimmingCharacters(in: .whitespaces)),
              (100...controller.deviceMaxDPI).contains(value) else {
            dpiStageError = "DPI must be between 100 and \(controller.deviceMaxDPI)."
            return nil
        }
        dpiStageError = nil
        return value
    }

    private func commitDpiValue() {
        defer { editingDpiValue = false; dpiStageFieldFocused = false }
        guard let value = typedDPI() else { return }
        dpiValue = Double(value)
        setCurrentDPI(value)
    }

    private func commitStageValue(index: Int) {
        guard editingDpiStage == index else { return }
        defer { editingDpiStage = nil; dpiStageFieldFocused = false }
        guard let value = typedDPI(), controller.dpiStages.indices.contains(index),
              controller.dpiStages[index] != value else { return }
        var stages = controller.dpiStages
        stages[index] = value
        if index == controller.activeDpiStage { dpiValue = Double(value) }
        controller.setDPITable(stages, active: controller.activeDpiStage ?? 0)
    }

    /// The DPI in use becomes `value`: the single value, or the active stage's.
    private func setCurrentDPI(_ value: Int) {
        var stages = controller.dpiStages
        guard !stages.isEmpty else { return }
        let active = min(controller.activeDpiStage ?? 0, stages.count - 1)
        guard stages[active] != value else { return }
        stages[active] = value
        controller.setDPITable(stages, active: active)
    }

    /// Single keeps the DPI in use; Stages brings back the five stages this slot had,
    /// with the one nearest the current DPI active.
    private func setDpiMode(single: Bool) {
        let stages = controller.dpiStages
        guard !stages.isEmpty, single != (stages.count == 1) else { return }
        let current = stages[min(controller.activeDpiStage ?? 0, stages.count - 1)]
        if single {
            deviceSettings?.rememberDpiStages(stages, slot: activeSlot)
            controller.setDPITable([current], active: 0)
        } else {
            let remembered = deviceSettings?.rememberedDpiStages(slot: activeSlot)
            let restored = (remembered?.count == RazerCommands.maxDPIStages ? remembered! : defaultStages)
                .map { min($0, controller.deviceMaxDPI) }
            let nearest = restored.indices.min { abs(restored[$0] - current) < abs(restored[$1] - current) } ?? 0
            dpiValue = Double(restored[nearest])
            controller.setDPITable(restored, active: nearest)
        }
    }

    /// The slot whose stages Single mode sets aside; 1 on mice without slots.
    private var activeSlot: Int { controller.activeOnboardSlot ?? 1 }

    private var presetDpiCard: some View {
        card {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("DPI", "scope")
                Spacer()
                Text(verbatim: "\(Int(dpiValue))")
                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
            }
            if controller.supportsFreeDPI {
                Slider(value: snapped($dpiValue, to: 50, from: 100), in: 100...Double(controller.deviceMaxDPI)) { editing in
                    if !editing {
                        let v = Int(dpiValue)
                        controller.setDPI(v)
                        if !displayedStages.contains(v) { saveCustomDPI(v) } // remember the manual value
                    }
                }
                .tint(.razerGreen)
                .controlSize(.small)
            }
            HStack(spacing: 6) {
                ForEach(Array(displayedStages.enumerated()), id: \.offset) { index, value in
                    dpiChip(value, index: index)
                }
                if controller.supportsFreeDPI { customChip }
            }
            if let dpiStageError {
                Text(dpiStageError).font(.system(size: 10.5)).foregroundStyle(Color.batteryLow)
            } else if let error = controller.dpiStagesError {
                Text(error).font(.system(size: 10.5)).foregroundStyle(Color.batteryLow)
            }
        }
        }
    }

    /// A fixed-preset DPI chip.
    private func dpiChip(_ value: Int, index: Int) -> some View {
        let active = Int(dpiValue) == value
        let editing = editingDpiStage == index
        return Group {
            if editing {
                TextField("DPI", text: $dpiStageDraft)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .monospacedDigit()
                    .focused($dpiStageFieldFocused)
                    .onSubmit { commitDpiStage(index: index) }
                    .onAppear { dpiStageFieldFocused = true }
            } else {
                Button {
                    dpiValue = Double(value)
                    controller.setDPI(value)
                } label: {
                    // Fill the chip so the whole hover-highlighted area is clickable.
                    Text(verbatim: "\(value)")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 10.5, weight: active ? .semibold : .regular).monospacedDigit())
        .foregroundStyle(active ? Color.onRazerGreen : Color.secondary)
        .frame(maxWidth: .infinity)
        .frame(height: 24)
        .background(active ? Color.razerGreen : Color.primary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 6))
        .hoverHighlight(RoundedRectangle(cornerRadius: 6))
        .contextMenu {
            if supportsBasiliskBluetooth {
                Button("Edit DPI") { beginDpiStageEdit(index: index, value: value) }
            }
        }
        // The stage editor lives in a context menu, which nothing on the chip hints at.
        .help(supportsBasiliskBluetooth ? "Stage \(index + 1) · Right-click to edit" : "Stage \(index + 1)")
        .accessibilityLabel(editing ? "Stage \(index + 1) DPI" : "\(value) DPI, stage \(index + 1)")
        .accessibilityAddTraits(active ? .isSelected : [])
        .disabled(controller.isUpdatingDpiStages || (editingDpiStage != nil && !editing))
    }

    private func beginDpiStageEdit(index: Int, value: Int) {
        guard supportsBasiliskBluetooth, !controller.isUpdatingDpiStages else { return }
        dpiStageError = nil
        dpiStageDraft = String(value)
        editingDpiStage = index
        dpiStageFieldFocused = true
    }

    private func commitDpiStage(index: Int) {
        guard editingDpiStage == index else { return }
        defer { editingDpiStage = nil; dpiStageFieldFocused = false }
        guard let value = Int(dpiStageDraft.trimmingCharacters(in: .whitespaces)),
              (100...controller.deviceMaxDPI).contains(value) else {
            dpiStageError = "DPI must be between 100 and \(controller.deviceMaxDPI)."
            return
        }
        guard controller.dpiStages.indices.contains(index), controller.dpiStages[index] != value else { return }
        dpiStageError = nil
        controller.setDPIStageValue(value, at: index)
    }

    /// The custom DPI chip — shows the saved manual value, green outline to mark it as the
    /// custom slot, filled green when the current DPI is a custom (non-preset) value.
    private var customChip: some View {
        let active = !displayedStages.contains(Int(dpiValue))
        return Button {
            dpiValue = Double(customDPI)
            controller.setDPI(customDPI)
        } label: {
            Text(verbatim: "\(active ? Int(dpiValue) : customDPI)")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.system(size: 10.5, weight: active ? .semibold : .regular).monospacedDigit())
        .foregroundStyle(active ? Color.onRazerGreen : Color.razerGreenText)
        .frame(maxWidth: .infinity)
        .frame(height: 24)
        .background(active ? Color.razerGreen : Color.razerGreen.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(active ? Color.clear : Color.razerGreen.opacity(0.55), lineWidth: 1))
        .hoverHighlight(RoundedRectangle(cornerRadius: 6))
        .help("Your custom DPI. Set it with the slider.")
        .accessibilityLabel("Custom, \(active ? Int(dpiValue) : customDPI) DPI")
        .accessibilityAddTraits(active ? .isSelected : [])
    }

}
