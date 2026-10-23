// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import Combine
import ApplicationServices
import CoreGraphics
import RazerProtocol

// MARK: - Event tap

/// The CGEvent tap that sees the buttons and acts on the remaps only the app can do.
extension ButtonRemapper {
    func installTapIfNeeded() {
        guard accessibilityGranted else { return }
        let includeKeyboard = shouldCaptureKeyboard && !keyboardTapRefused
        guard tap == nil || tapIncludesKeyboard != includeKeyboard else {
            if let tap {
                if !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
                eventTapAvailable = CGEvent.tapIsEnabled(tap: tap)
                refreshKeyboardCaptureStatus()
            }
            return
        }
        removeTap()
        installTap(includeKeyboard: includeKeyboard)
    }

    var shouldCaptureKeyboard: Bool {
        isBasiliskV3XHyperSpeed && dpiCycleSoftwareAction != nil
    }

    func installTap(includeKeyboard: Bool) {
        // otherMouse = middle/wheel-click + extra buttons — the only events we remap.
        // Primary left/right clicks are deliberately never tapped.
        let types: [CGEventType] = includeKeyboard
            ? [.otherMouseDown, .otherMouseUp, .keyDown, .keyUp]
            : [.otherMouseDown, .otherMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask), callback: Self.tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            // macOS may reject keyboard capture while allowing mouse events. Keep ordinary
            // button remapping available even when the optional F20 bridge cannot run, and
            // remember the refusal: otherwise every state change would tear down the working
            // mouse-only tap to try the keyboard one again.
            if includeKeyboard {
                installTap(includeKeyboard: false)
                // Only a refusal if mouse events still work. When both fail, the cause is
                // something else (Accessibility not effective yet), so try both again later.
                keyboardTapRefused = tap != nil
            }
            return
        }

        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.runLoopSource = src
        self.tapIncludesKeyboard = includeKeyboard
        eventTapAvailable = true
        refreshKeyboardCaptureStatus()
    }

    static func includesKeyboardEvents(_ mask: CGEventMask) -> Bool {
        let required = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        return mask & required == required
    }

    func refreshKeyboardCaptureStatus() {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success else {
            keyboardCaptureAvailable = false; return
        }
        var entries = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        guard CGGetEventTapList(count, &entries, &count) == .success else {
            keyboardCaptureAvailable = false; return
        }
        keyboardCaptureAvailable = entries.prefix(Int(count)).contains {
            $0.tappingProcess == getpid() && $0.enabled && Self.includesKeyboardEvents($0.eventsOfInterest)
        }
    }

    /// Runs on the main run loop (the tap source is scheduled there). Internal rather than
    /// private so tests can hand it synthetic events.
    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        // Skip events we ourselves posted (e.g. a remap-to-middle-click re-enters the tap).
        if event.getIntegerValueField(.eventSourceUserData) == Self.magic {
            return Unmanaged.passUnretained(event)
        }
        if type == .keyDown || type == .keyUp {
            return handleDpiBridge(type: type, event: event)
        }
        let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))

        // Only the extra buttons are remappable (the tap is scoped to otherMouse events,
        // but keep the guard as a defensive net).
        guard type == .otherMouseDown || type == .otherMouseUp else {
            return Unmanaged.passUnretained(event)
        }

        // Saved in the mouse: what arrives is already the remapped action (or the button's
        // own job). Remapping it again here would act twice.
        if savedInMouse.contains(button), !suppressedTapButtons.contains(button) {
            if type == .otherMouseDown, lastDetectedButton != button || !seenButtons.contains(button) {
                lastDetectedButton = button
                seenButtons.insert(button)
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .otherMouseUp, suppressedTapButtons.remove(button) != nil {
            if mappings[button] == .hyperShift { hyperShiftHeld = false }
            return nil // its press was taken over, so its release goes too
        }
        if let action = activeAction(for: button) {
            guard remappingPaused else {
                if type == .otherMouseDown {
                    suppressedTapButtons.insert(button)
                    if action == .hyperShift { hyperShiftHeld = true } else { apply(action) }
                }
                return nil // suppress the original button (both down and up)
            }
            // This press still goes through unchanged: the tap can't tell which device sent
            // it, so it may not be our mouse at all. The check brings the mapping back for the
            // next press, a moment later, if it is.
            if type == .otherMouseDown { onPressWhilePaused?() }
        }

        // Unmapped → remember it for the UI, and let it through unchanged.
        if type == .otherMouseDown, lastDetectedButton != button || !seenButtons.contains(button) {
            lastDetectedButton = button
            seenButtons.insert(button)
        }
        return Unmanaged.passUnretained(event)
    }

    func apply(_ action: RemapAction) {
        if let actionEmitter { actionEmitter(action); return }
        switch action {
        case .passthrough: break
        case .keystroke(let kc, let mods, _): postKeystroke(keyCode: kc, flags: CGEventFlags(rawValue: mods))
        case .mouseButton(let b, _): postMouseClick(b)
        case .doubleClick: postDoubleClick()
        case .mediaKey(let code, _): postMediaKey(code)
        case .hyperShift: break // a modifier: `hyperShiftHeld` is set where its presses arrive
        case .cycleProfile, .turboClick, .turboKey, .dpiClutch, .cycleScrollMode, .scroll, .dpiStage:
            break // the mouse does these itself
        case .disabled: break // the press is swallowed and nothing is sent
        }
    }

    func postKeystroke(keyCode: UInt16, flags: CGEventFlags) {
        let down = CGEvent(keyboardEventSource: postSource, virtualKey: CGKeyCode(keyCode), keyDown: true)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: postSource, virtualKey: CGKeyCode(keyCode), keyDown: false)
        up?.flags = flags
        up?.post(tap: .cghidEventTap)
    }

    func postMouseClick(_ button: Int) {
        let pos = CGEvent(source: nil)?.location ?? .zero
        let mb = CGMouseButton(rawValue: UInt32(button)) ?? .center
        let downType: CGEventType = button == 0 ? .leftMouseDown : (button == 1 ? .rightMouseDown : .otherMouseDown)
        let upType: CGEventType = button == 0 ? .leftMouseUp : (button == 1 ? .rightMouseUp : .otherMouseUp)
        for (type, clickState) in [(downType, 1), (upType, 1)] {
            let e = CGEvent(mouseEventSource: postSource, mouseType: type, mouseCursorPosition: pos, mouseButton: mb)
            // Without a click count, apps reading NSEvent.clickCount see 0 and may not
            // treat the synthesized press as a click at all (e.g. middle-click-closes-tab).
            e?.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
            e?.post(tap: .cghidEventTap)
        }
    }

    func postDoubleClick() {
        let pos = CGEvent(source: nil)?.location ?? .zero
        for clicks in [1, 2] {
            let down = CGEvent(mouseEventSource: postSource, mouseType: .leftMouseDown, mouseCursorPosition: pos, mouseButton: .left)
            down?.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
            down?.post(tap: .cghidEventTap)
            let up = CGEvent(mouseEventSource: postSource, mouseType: .leftMouseUp, mouseCursorPosition: pos, mouseButton: .left)
            up?.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
            up?.post(tap: .cghidEventTap)
        }
    }

    func postMediaKey(_ code: Int) {
        func post(_ down: Bool) {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data1 = (code << 16) | ((down ? 0xA : 0xB) << 8)
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags,
                               timestamp: 0, windowNumber: 0, context: nil,
                               subtype: 8, data1: data1, data2: -1)?.cgEvent?.post(tap: .cghidEventTap)
        }
        post(true); post(false)
    }
}
