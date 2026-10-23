// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

// serpentine-cli: diagnostics against a real mouse over USB (the cable or the 2.4 GHz
// dongle), for checking a new model before it goes in the registry. See CONTRIBUTING.md.
// Battery reads may time out over the wireless dongle — the known issue from
// openrazer/openrazer#2583.

import Foundation
import RazerProtocol
import RazerDeviceKit

let args = Array(CommandLine.arguments.dropFirst())
let usage = "Usage: serpentine-cli <info | battery | dpi [x] [y] | poll [hz] | stages [d1,d2,…] [active] | rgb <static rrggbb|spectrum|wave|off> | brightness [pct]>"

guard let command = args.first else {
    print(usage)
    exit(64)
}

/// Status and diagnostics: which device opened, why it didn't, how to fix that. They go to
/// stderr so stdout carries only a command's results, and a redirect gets the results alone
/// while the person still sees the rest.
func status(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}

/// Turn a permission-denied failure into the fix, instead of leaving a bare hex code on
/// screen. The app already does this (`MouseController.needsInputMonitoring`); every catch
/// routes through here so it does too. Returns whether the error was a permission problem,
/// so callers can suppress advice that would then be misleading.
@discardableResult
func printPermissionHintIfDenied(_ error: Error) -> Bool {
    guard HIDDevice.errorLooksPermissionDenied(String(describing: error)) else { return false }
    status("  → macOS is refusing HID access (Input Monitoring).")
    status("    Running via `swift run serpentine-cli …`? The grant belongs to the terminal that")
    status("    launched it, not to the SwiftPM binary — grant Terminal (or iTerm/your IDE) in")
    status("    System Settings › Privacy & Security › Input Monitoring, then start a new")
    status("    terminal session and retry.")
    status("    Running Serpentine.app? Grant Serpentine itself there, then relaunch it — macOS")
    status("    only applies the grant to a freshly-launched app.")
    return true
}

func openDevice() -> HIDDevice? {
    // These commands only speak USB. With the mouse on Bluetooth and the dongle still plugged
    // in, they would open the idle dongle and every read would time out with no hint why.
    if let bt = HIDDevice.bluetoothRazerMouse() {
        status("Note: \(bt.name) is connected over Bluetooth, which these commands can't reach.")
        status("      If that's the mouse to probe, switch it to the dongle or plug in the cable.")
    }
    do {
        let dev = try HIDDevice.open(vendorId: Razer.vendorId)
        status("✓ Opened \(dev.productName) (VID 0x1532, PID 0x\(String(format: "%04x", dev.productID)))")
        return dev
    } catch {
        status("✗ \(error)")
        printPermissionHintIfDenied(error)
        return nil
    }
}

switch command {
case "info":
    // List every HID interface the dongle exposes, so we can see which one is the control
    // interface (vendor usage page / largest feature report).
    let devices = HIDDevice.matchingDevices(vendorId: Razer.vendorId)
    if devices.isEmpty {
        print("No Razer devices found (VID 0x1532).")
        exit(1)
    }
    print("Found \(devices.count) HID interface(s) for VID 0x1532:")
    for (i, dev) in devices.enumerated() {
        print("  [\(i)] \(HIDDevice.describe(dev))")
    }

case "battery":
    guard let dev = openDevice() else { exit(1) }
    defer { dev.close() }
    do {
        let battery = try DeviceProbe.battery(dev)
        let resp = battery.response
        let raw = battery.value
        let pct = RazerCommands.batteryPercent(fromRaw: raw)
        print("Battery: \(pct)%  (raw byte = \(raw), status = 0x\(String(resp.status, radix: 16)))")
        print("Full response args[0..8]: \(resp.arguments[0..<9].map { String(format: "%02x", $0) }.joined(separator: " "))")
    } catch {
        print("Battery read failed: \(error)")
        // Only blame the dongle when it isn't a permission problem — sending someone to
        // re-seat hardware over a TCC denial wastes their time.
        if !printPermissionHintIfDenied(error) {
            print("(This is the documented wireless-dongle timeout. Try: re-seat the dongle, ")
            print(" move the mouse to wake it, or test over wired USB-C to compare.)")
        }
        exit(2)
    }

case "dpi":
    guard let dev = openDevice() else { exit(1) }
    defer { dev.close() }
    do {
        // Read current DPI first.
        let before = try DeviceProbe.readDPI(dev).value
        print("Current DPI: x=\(before.x) y=\(before.y)")

        // If a value was given, set it and read back to confirm it persisted.
        if let arg = args.dropFirst().first, let x = UInt16(arg) {
            let y = args.dropFirst(2).first.flatMap { UInt16($0) } ?? x
            print("Setting DPI to x=\(x) y=\(y) …")
            let check = try DeviceProbe.writeDPI(dev, DeviceProbe.DPI(x: x, y: y))
            print("  set status = 0x\(String(check.setResponse.status, radix: 16))")
            let after = check.readBack.value
            print("Read-back DPI: x=\(after.x) y=\(after.y)")
            if check.confirmed {
                print("✓ DPI write confirmed (persisted to onboard memory)")
            } else {
                print("⚠︎ Read-back doesn't match requested value — investigate.")
            }
        } else {
            print("(pass a value to set, e.g. `dpi 3200` or `dpi 1600 1600`)")
        }
    } catch {
        print("DPI command failed: \(error)")
        printPermissionHintIfDenied(error)
        exit(2)
    }

case "stages":
    // Read (and optionally write) the onboard DPI stage table the mouse's DPI button cycles.
    guard let dev = openDevice() else { exit(1) }
    defer { dev.close() }
    do {
        let before = try DeviceProbe.readStages(dev).value
        print("Current stages: \(before.stages) (active byte = \(before.activeByte))")
        if let arg = args.dropFirst().first {
            let tokens = arg.split(separator: ",")
            let stages = tokens.compactMap { Int($0) }
            // Reject the whole argument on any junk token — silently dropping "3200o"
            // would shrink the onboard table the DPI button cycles.
            guard !stages.isEmpty, stages.count == tokens.count,
                  stages.count <= RazerCommands.maxDPIStages else {
                print("Usage: stages 400,800,1600[,…]   (1-\(RazerCommands.maxDPIStages) comma-separated numbers)")
                exit(64)
            }
            let active = args.dropFirst(2).first.flatMap { Int($0) } ?? 0
            print("Setting stages \(stages) (active \(active)) …")
            let write = try DeviceProbe.writeStages(dev, stages: stages, activeStage: active)
            print("  set status = 0x\(String(write.setResponse.status, radix: 16))")
            let after = write.readBack.value
            print("Read-back: \(after.stages) (active byte = \(after.activeByte))")
        } else {
            print("(pass values to set, e.g. `stages 400,800,1600 1` — last number is the active stage index)")
        }
    } catch {
        print("Stages command failed: \(error)")
        printPermissionHintIfDenied(error)
        exit(2)
    }

case "poll":
    guard let dev = openDevice() else { exit(1) }
    defer { dev.close() }
    do {
        let before = try DeviceProbe.readPollingRate(dev).value
        print("Current polling rate: \(before)Hz")
        if let arg = args.dropFirst().first, let hz = Int(arg) {
            guard RazerCommands.supportedPollingRates.contains(hz) else {
                print("Unsupported rate. Choose one of: \(RazerCommands.supportedPollingRates.map { "\($0)" }.joined(separator: ", "))Hz")
                exit(64)
            }
            print("Setting polling rate to \(hz)Hz …")
            let check = try DeviceProbe.writePollingRate(dev, hz: hz)
            print("  set status = 0x\(String(check.setResponse.status, radix: 16))")
            print("Read-back: \(check.readBack.value)Hz")
            print(check.confirmed ? "✓ Polling rate write confirmed" : "⚠︎ Read-back doesn't match.")
        } else {
            print("(pass a value to set: \(RazerCommands.supportedPollingRates.map { "\($0)" }.joined(separator: "/"))Hz, e.g. `poll 1000`)")
        }
    } catch {
        print("Poll-rate command failed: \(error)")
        printPermissionHintIfDenied(error)
        exit(2)
    }

case "brightness":
    guard let dev = openDevice() else { exit(1) }
    defer { dev.close() }
    func dump(_ r: RazerReport) -> String {
        "status=0x\(String(r.status, radix: 16)) args[0..5]=" + r.arguments[0..<6].map { String(format: "%02x", $0) }.joined(separator: " ")
    }
    do {
        // Every LED group, LOGO first. A refusal on any one of them, LOGO included, is
        // expected on some models (the Basilisk V3 X HyperSpeed lights only its scroll wheel
        // and answers 0x03 for LOGO), so the sweep reports it and carries on: the whole point
        // is to discover which LEDs answer on a model we don't know yet.
        for answer in DeviceProbe.brightnessSweep(dev) {
            let label = "GET brightness (led \(answer.name)=0x\(String(format: "%02x", answer.led)))"
            switch answer.result {
            case .success(let reading):
                print("\(label): \(dump(reading.response))"
                      + " → \(RazerCommands.brightnessPercent(fromRaw: reading.value))%")
            case .failure(let error):
                print("\(label): refused — \(error)")
            }
        }
        if let arg = args.dropFirst().first, let pct = Int(arg) {
            let led = RazerDevices.brightnessLed(pid: dev.productID)
            // The sweep records a refusal per group and carries on; this write throws on one
            // instead, because here it is a real failure to report, not a group that simply
            // doesn't answer.
            let raw = RazerCommands.brightnessRaw(fromPercent: pct)
            print("SET brightness \(pct)% (raw \(raw)) on led 0x\(String(format: "%02x", led)) …")
            let check = try DeviceProbe.writeBrightness(dev, raw: raw, led: led)
            print("  set: \(dump(check.setResponse))")
            print("  read-back: \(dump(check.readBack.response)) → \(RazerCommands.brightnessPercent(fromRaw: check.readBack.value))%")
        }
    } catch {
        // The sweep above handles its own refusals per LED, so only the optional write can
        // reach this — saying "probe failed" would point at the part that just succeeded.
        print("Brightness write failed: \(error)")
        printPermissionHintIfDenied(error)
        exit(2)
    }

case "rgb":
    guard let dev = openDevice() else { exit(1) }
    defer { dev.close() }
    let effect = args.dropFirst().first ?? "help"
    func parseHex(_ s: String) -> RGB? {
        let h = s.hasPrefix("#") ? String(s.dropFirst()) : s
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return RGB(r: UInt8((v >> 16) & 0xFF), g: UInt8((v >> 8) & 0xFF), b: UInt8(v & 0xFF))
    }
    do {
        let report: RazerReport
        switch effect {
        case "static":
            guard let hex = args.dropFirst(2).first, let rgb = parseHex(hex) else {
                print("Usage: rgb static <rrggbb>   e.g. `rgb static ff0000` (red)")
                exit(64)
            }
            print("Setting static \(hex) …")
            report = RazerCommands.setStatic(rgb: rgb)
        case "spectrum":
            print("Setting spectrum cycle …"); report = RazerCommands.setSpectrum()
        case "wave":
            print("Setting wave …"); report = RazerCommands.setWave()
        case "off":
            print("Turning lighting off …"); report = RazerCommands.setNone()
        default:
            print("Usage: rgb <static rrggbb | spectrum | wave | off>")
            exit(64)
        }
        let resp = try DeviceProbe.applyLighting(dev, report)
        let ok = resp.status == RazerStatus.successful.rawValue
        print("  status = 0x\(String(resp.status, radix: 16)) \(ok ? "✓" : "⚠︎")")
    } catch {
        print("RGB command failed: \(error)")
        printPermissionHintIfDenied(error)
        exit(2)
    }

default:
    print("Unknown command: \(command)")
    print(usage)
    exit(64)
}
