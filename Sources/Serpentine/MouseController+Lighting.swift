// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation
import AppKit
import CoreBluetooth
import RazerProtocol
import RazerDeviceKit

// MARK: - Lighting

/// Effect, colour and brightness, per zone on mice that have zones (`ZonedLighting`).
extension MouseController {
    /// io-queue only. One zone's effect, colour and brightness. A colourless effect keeps
    /// the colour last known for the zone.
    func readZoneSync(_ zone: LightingZone, on dev: any RazerTransport) -> ZoneLighting? {
        guard let effect = (try? dev.sendWithRetry(ZonedLighting.getEffect(zone: zone))).flatMap(ZonedLighting.parseEffect),
              let raw = try? dev.sendWithRetry(RazerCommands.getBrightness(led: zone.rawValue)).arguments[2] else { return nil }
        let color = effect.color ?? zoneColors[zone] ?? RGB(r: 0x44, g: 0xD6, b: 0x2C)
        zoneColors[zone] = color
        return ZoneLighting(effect: effect.effect, color: color,
                            brightness: RazerCommands.brightnessPercent(fromRaw: raw))
    }

    /// Main thread. Publishes the zones' lighting, and the selected zone's in the controls.
    func showZoneLighting(_ zones: [LightingZone: ZoneLighting]) {
        update(\.zoneLighting, zones)
        guard let shown = zones[selectedLightingZone ?? .logo] else { return }
        update(\.effect, shown.lightingEffect)
        update(\.lightingColor, shown.color)
        update(\.brightness, shown.brightness)
    }

    /// Main thread. Points the lighting controls at one zone, or all of them.
    func selectLightingZone(_ zone: LightingZone?) {
        selectedLightingZone = zone
        showZoneLighting(zoneLighting)
    }

    /// The zones a lighting change goes to.
    var targetZones: [LightingZone] { selectedLightingZone.map { [$0] } ?? lightingZones }

    /// Whether every zone shows the same lighting.
    var zonesMatch: Bool { Set(zoneLighting.values.map { [$0.effect, "\($0.color)", "\($0.brightness)"] }).count <= 1 }

    /// Main thread. Writes `change` into each target zone and publishes what landed.
    func setZones(_ change: @escaping (ZoneLighting) -> ZoneLighting) {
        let zones = targetZones
        let fallback = ZoneLighting(effect: effect, color: lightingColor, brightness: brightness)
        let wanted = Dictionary(uniqueKeysWithValues: zones.map { ($0, change(zoneLighting[$0] ?? fallback)) })
        let before = zoneLighting
        io.user { [weak self] in
            guard let self else { return }
            guard let dev = try? self.ensureDevice() else {
                self.publish { self.lastWriteFailure = Date() }
                return
            }
            var landed: [LightingZone: ZoneLighting] = [:]
            for (zone, lit) in wanted {
                let old = before[zone]
                var ok = true
                if old?.effect != lit.effect || old?.color != lit.color {
                    ok = (try? dev.sendWithRetry(ZonedLighting.setEffect(lit.lightingEffect, color: lit.color, zone: zone))) != nil
                }
                if ok, old?.brightness != lit.brightness {
                    ok = (try? dev.sendWithRetry(RazerCommands.setBrightness(
                        RazerCommands.brightnessRaw(fromPercent: lit.brightness), led: zone.rawValue))) != nil
                }
                if ok { landed[zone] = lit; self.zoneColors[zone] = lit.color }
            }
            let done = landed
            self.publish {
                var all = self.zoneLighting
                for (zone, lit) in done { all[zone] = lit }
                self.showZoneLighting(all)
                if done.count < wanted.count { self.lastWriteFailure = Date() }
                if !done.isEmpty { self.clearActiveProfileIfNeeded() }
            }
        }
    }

    func setBrightness(_ percent: Int) {
        let pct = max(0, min(percent, 100))
        if !zoneLighting.isEmpty {
            setZones { var z = $0; z.brightness = pct; return z }
            return
        }
        io.user { [weak self] in
            guard let self else { return }
            let ok = (try? {
                let dev = try self.ensureDevice()
                let led = RazerDevices.brightnessLed(pid: dev.productID)
                let raw = RazerCommands.brightnessRaw(fromPercent: pct)
                _ = try dev.sendWithRetry(RazerCommands.setBrightness(raw, led: led))
                if RazerDevices.verifiesBrightnessWrite(pid: dev.productID) {
                    let readback = try dev.sendWithRetry(RazerCommands.getBrightness(led: led)).arguments[2]
                    guard readback == raw else { throw HIDDevice.HIDError.commandFailed }
                }
                return true
            }()) != nil
            self.publish {
                guard ok else { self.lastWriteFailure = Date(); return }
                self.brightness = pct; self.clearActiveProfileIfNeeded()
            }
        }
    }

    /// Sets the lighting effect (using the current `lightingColor` for `.staticColor`).
    /// Like the other setters: the device write happens on `io`, and `effect` is published
    /// only on success — the picker never claims lighting the mouse didn't take.
    func setEffect(_ newEffect: LightingEffect) {
        // NSSegmentedControl can fire its action on a click of the already-selected
        // segment; a no-change "set" must not resend the command or un-mark the active
        // profile (the config didn't change).
        if !zoneLighting.isEmpty {
            setZones { var z = $0; z.effect = newEffect.rawValue; return z }
            return
        }
        guard newEffect != effect else { return }
        sendLighting(report(for: newEffect, color: lightingColor)) {
            self.effect = newEffect
        }
    }

    /// Sets a static colour (switching the effect to `.staticColor` if needed).
    func setStaticColor(_ rgb: RGB) {
        // A zone keeps an effect that has a colour of its own, and takes the new colour.
        if !zoneLighting.isEmpty {
            setZones { var z = $0; z.color = rgb; if !z.lightingEffect.usesColor { z.effect = LightingEffect.staticColor.rawValue }; return z }
            return
        }
        guard !(effect == .staticColor && lightingColor == rgb) else { return } // no-change re-click
        sendLighting(RazerCommands.setStatic(rgb: rgb)) {
            self.effect = .staticColor
            self.lightingColor = rgb
        }
    }

    func report(for effect: LightingEffect, color: RGB) -> RazerReport {
        switch effect {
        case .staticColor: return RazerCommands.setStatic(rgb: color)
        case .spectrum: return RazerCommands.setSpectrum()
        case .wave: return RazerCommands.setWave()
        // Offered only on mice with lighting zones, which don't come here (`setZones`).
        case .breathing, .reactive: return RazerCommands.setStatic(rgb: color)
        case .off: return RazerCommands.setNone()
        }
    }

    /// Every lighting change the user makes goes through here, so it is the one place the
    /// effect and colour controls need to preempt a background read.
    func sendLighting(_ report: RazerReport, onSuccess: @escaping @Sendable () -> Void) {
        io.user { [weak self] in
            guard let self else { return }
            let ok = (try? {
                let device = try self.ensureDevice()
                _ = try device.sendWithRetry(report)
                return true
            }()) != nil
            self.publish {
                guard ok else { self.lastWriteFailure = Date(); return }
                onSuccess()
                self.clearActiveProfileIfNeeded()
            }
        }
    }
}
