// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit

/// Draws the app's marks: the serpent (menu bar, app icon, About and setup windows) and the
/// per-model mouse silhouettes (the popover header). The silhouette-per-model mapping lives in
/// `RazerDevices`, the registry, so adding a mouse doesn't touch drawing code.
enum MenuBarIcon {

    /// Razer yellow-green is the brand's; this is a battery-charging yellow, picked to read
    /// against a menu bar rather than to match the logo. Two of them, because one doesn't
    /// work in both places: system yellow disappears into a white menu bar, and the darker
    /// amber that fixes that looks muddy on black.
    static let chargingYellowOnDark = NSColor(red: 1.00, green: 0.84, blue: 0.13, alpha: 1)  // #FFD621
    static let chargingYellowOnLight = NSColor(red: 0.85, green: 0.58, blue: 0.00, alpha: 1) // #D99400

    /// The charging mark's body and bolt colours. Dynamic, so they resolve against whatever
    /// appearance the image is being drawn for, at the moment it is drawn.
    ///
    /// This is what lets one charging image serve every menu bar. `drawSerpent` returns a
    /// drawing-handler image, and AppKit runs the handler again whenever it is drawn under a
    /// different appearance, so the mark recolours itself when the menu bar flips. (Checked
    /// by forcing a status item's appearance back and forth, and by `MenuBarIconTests`.)
    /// It should also give each display's copy of the status item colours for that display's
    /// menu bar, if AppKit draws those copies under their own appearance, but that part has
    /// not been seen on two displays with different menu bars.
    ///
    /// Earlier builds picked the colours once, from the status item's `effectiveAppearance`,
    /// and watched that property to redraw. That watch is what broke (issue #25): setting a
    /// status item's image makes AppKit re-snapshot the item and report `effectiveAppearance`
    /// as changed even when it hasn't, so the redraw re-triggered itself forever and held
    /// 50-100% of a core. Nothing needs to observe the appearance now, and nothing should.
    private static let chargingBody = NSColor(name: nil) { isDark($0) ? .white : .black }
    private static let chargingBolt = NSColor(name: nil) {
        isDark($0) ? chargingYellowOnDark : chargingYellowOnLight
    }

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    // MARK: Serpent

    /// The snake from Health Icons (`animal-snake`, MIT, © 2021 Resolve to Save Lives; see
    /// NOTICE.md), as published, on its 48×48 grid. Filled even-odd: the eyes are holes.
    /// A stand-in until Serpentine has its own mark; swapping it is a matter of this string
    /// and `serpentGrid`.
    static let serpentPathData = """
        M33.68 17.768c1.169.892 2.372 1.1 4.159-.687c.707-.707 5.293-8.142 3.535-9.899c-1.757-1.757-8.839 2.475-9.9 3.535c-1.788 1.789-1.577 2.993-.682 4.163l-.706.706a3.43 3.43 0 0 0-1.031 2.46c0 .825.279 1.562.563 2.13c.456.913 1.203 1.894 1.823 2.708q.176.23.334.44c.77 1.027 1.277 1.802 1.472 2.429c.086.274.077.42.064.486a.5.5 0 0 1-.092.194c-.2-.075-.534-.249-1.018-.609c-1.165-.865-2.517-2.27-4.058-3.874l-.264-.274c-1.554-1.615-3.318-3.43-4.994-4.55c-.84-.56-1.844-1.08-2.936-1.209a3.97 3.97 0 0 0-3.363 1.169c-.875.875-1.3 1.948-1.31 3.086c-.01 1.062.338 2.06.763 2.91c.837 1.673 2.295 3.39 3.58 4.86l.586.666v.001c1.134 1.288 2.103 2.39 2.725 3.351c.188.292.308.518.384.685a2.6 2.6 0 0 1-.658-.128c-.862-.264-1.925-.86-3.14-1.638a90 90 0 0 1-1.112-.73c-.808-.535-1.645-1.09-2.34-1.48c-.52-.291-1.147-.603-1.785-.752c-.606-.142-1.773-.251-2.693.669c-.81.81-1.078 1.779-1.161 2.573c-.065.625-.026 1.302.003 1.791l.012.217c.052.98-.005 1.424-.198 1.727c-.24.275-.501.623-.79 1.059c-.068.103-.229.312-.443.591c-1.035 1.347-3.327 4.33-2.631 5.026c.84.84 5.597-2.556 6.361-3.32c.67-.67.997-1.18 1.102-1.598c.71-1.374.64-2.805.594-3.695q-.007-.15-.016-.283l-.018-.346c.488.29 1.013.639 1.608 1.034c.412.273.858.57 1.35.884c1.223.785 2.69 1.657 4.126 2.096c1.434.44 3.405.597 4.93-.928c.912-.912 1.128-2.063.954-3.106c-.155-.93-.615-1.799-1.08-2.519c-.798-1.234-2.004-2.603-3.116-3.864l-.543-.617c-1.34-1.53-2.443-2.875-3.013-4.015c-.278-.556-.343-.902-.342-1.083c.001-.104.014-.17.14-.296q.02-.021.023-.027l.004-.005l.006.001q.006.003.031.006c.18.022.561.147 1.183.563c1.246.832 2.7 2.3 4.334 3.997l.354.368c1.442 1.502 3.018 3.143 4.465 4.218c.778.578 1.713 1.145 2.73 1.356c1.152.239 2.39.002 3.37-.977c.686-.687 1.142-1.496 1.32-2.403c.175-.887.057-1.726-.17-2.451c-.429-1.374-1.36-2.661-2.09-3.635q-.223-.298-.425-.563c-.62-.82-1.082-1.429-1.355-1.975c-.012-.024.201-.285.485-.62m.875-5.596a.75.75 0 1 1-1.06-1.06a.75.75 0 0 1 1.06 1.06m1.693 3.197a.75.75 0 1 0 1.06-1.06a.75.75 0 0 0-1.06 1.06
        """
    static let serpentGrid: CGFloat = 48
    /// A `CGPath` is immutable once built, so sharing one across threads is safe; Swift can't
    /// see that, as CoreGraphics doesn't mark it `Sendable`.
    nonisolated(unsafe) private static let serpentPath = SVGPath.parse(serpentPathData)

    /// The serpent for the menu bar and the app's own windows.
    ///
    /// The idle mark is a **template** image: macOS recolors it for a light or dark menu bar,
    /// and inverts it while the item is highlighted, all for free.
    ///
    /// The charging mark cannot be, because a template image throws colour away. So the bolt's
    /// yellow costs us the automatic recolouring, and the colours are dynamic instead; see
    /// `chargingBody`.
    static func serpent(pointSize: CGFloat = 16, charging: Bool = false) -> NSImage {
        guard charging else {
            let img = drawSerpent(size: pointSize)
            img.isTemplate = true
            return img
        }
        let img = drawSerpent(size: pointSize, color: chargingBody, charging: true, boltColor: chargingBolt)
        img.isTemplate = false
        return img
    }

    /// `boltColor` defaults to `color` so every non-menu-bar caller draws a single-colour mark.
    private static func drawSerpent(size s: CGFloat, color: NSColor = .black, charging: Bool = false,
                                    boltColor: NSColor? = nil) -> NSImage {
        // Flipped, so the SVG's y-down coordinates draw as they are.
        NSImage(size: NSSize(width: s, height: s), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let unit = s / serpentGrid
            ctx.saveGState()
            ctx.scaleBy(x: unit, y: unit)
            if charging {
                // The snake runs corner to corner, tail bottom left, head top right, which
                // leaves the bottom-right corner free for the bolt. Shrunk a little toward the
                // top left so the two don't touch: overlapping, they read as neither.
                ctx.saveGState()
                ctx.scaleBy(x: 0.86, y: 0.86)
                ctx.addPath(serpentPath)
                ctx.setFillColor(color.cgColor)
                ctx.fillPath(using: .evenOdd)
                ctx.restoreGState()

                let bolt = CGMutablePath()
                bolt.move(to: CGPoint(x: 41.5, y: 25))   // top tip
                bolt.addLine(to: CGPoint(x: 33, y: 38.5)) // down-left to the waist
                bolt.addLine(to: CGPoint(x: 39, y: 38.5))
                bolt.addLine(to: CGPoint(x: 37, y: 47))   // bottom tip
                bolt.addLine(to: CGPoint(x: 46, y: 33.5)) // up-right to the waist
                bolt.addLine(to: CGPoint(x: 40, y: 33.5))
                bolt.closeSubpath()
                ctx.addPath(bolt)
                ctx.setFillColor((boltColor ?? color).cgColor)
                ctx.fillPath()
            } else {
                ctx.addPath(serpentPath)
                ctx.setFillColor(color.cgColor)
                ctx.fillPath(using: .evenOdd)
            }
            ctx.restoreGState()
            return true
        }
    }

    // MARK: Mouse silhouettes

    /// Same silhouette family, but shaped/detailed to match the specific connected model
    /// (by USB product ID) instead of always drawing the generic Cobra body. Falls back to
    /// the generic Cobra shape for an unknown or absent device.
    /// No charging variant here on purpose: this is the popover's header mark, and the card
    /// directly below it already spells out the charging state in words.
    static func mouseModel(pid: Int?, razerCutout: Bool = true, pointSize: CGFloat = 20) -> NSImage {
        let img = drawMouse(size: pointSize, razerCutout: razerCutout,
                            silhouette: RazerDevices.silhouette(pid: pid))
        img.isTemplate = true
        return img
    }

    private static func drawMouse(size s: CGFloat, razerCutout: Bool, silhouette: RazerMouseSilhouette,
                                  color: NSColor = .black) -> NSImage {
        NSImage(size: NSSize(width: s, height: s), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let cx = rect.midX, cy = rect.midY
            let lw = s * 0.055
            // Body scale varies per model so the header icon reads as a different mouse:
            // Atheris is Razer's smallest/lowest-profile model here, Cobra Pro/HyperSpeed
            // the largest.
            let scale: CGFloat = silhouette == .atheris ? 0.84 : (silhouette == .cobraPro ? 1.05 : 1.0)
            // Normalised point: (x, y) in roughly [-0.5, 0.5], y up.
            func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: cx + x * scale * s, y: cy + y * scale * s) }

            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(lw)
            ctx.setLineJoin(.round)
            ctx.setLineCap(.round)

            // Gaming-mouse body: narrow domed top, slight waist, wide rounded base.
            let body = CGMutablePath()
            body.move(to: P(0, 0.45))
            body.addCurve(to: P(0.24, 0.40), control1: P(0.12, 0.46), control2: P(0.19, 0.43))
            body.addCurve(to: P(0.29, 0.12), control1: P(0.30, 0.34), control2: P(0.30, 0.22))
            body.addCurve(to: P(0.34, -0.26), control1: P(0.28, 0.00), control2: P(0.33, -0.12))
            body.addCurve(to: P(0, -0.46), control1: P(0.35, -0.41), control2: P(0.20, -0.46))
            body.addCurve(to: P(-0.34, -0.26), control1: P(-0.20, -0.46), control2: P(-0.35, -0.41))
            body.addCurve(to: P(-0.29, 0.12), control1: P(-0.33, -0.12), control2: P(-0.28, 0.00))
            body.addCurve(to: P(-0.24, 0.40), control1: P(-0.30, 0.22), control2: P(-0.30, 0.34))
            body.addCurve(to: P(0, 0.45), control1: P(-0.19, 0.43), control2: P(-0.12, 0.46))
            body.closeSubpath()
            ctx.addPath(body)

            // Scroll-wheel pill at top-centre.
            let wheelW = s * 0.075
            let wheel = CGPath(roundedRect: CGRect(x: cx - wheelW / 2, y: cy + 0.16 * scale * s,
                                                   width: wheelW, height: 0.18 * s),
                               cornerWidth: wheelW / 2, cornerHeight: wheelW / 2, transform: nil)
            ctx.addPath(wheel)

            // Button-split line below the wheel.
            ctx.move(to: P(0, 0.13))
            ctx.addLine(to: P(0, -0.10))

            // Thumb buttons on the left edge: two on Cobra/Cobra Pro, one on the smaller Atheris.
            let bw = s * 0.115, bh = s * 0.072
            let thumbYs: [CGFloat] = silhouette == .atheris ? [0.12] : [0.175, 0.065]
            for yy in thumbYs {
                let r = CGRect(x: cx - 0.405 * scale * s, y: cy + yy * scale * s - bh / 2, width: bw, height: bh)
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: bh * 0.45, cornerHeight: bh * 0.45, transform: nil))
            }

            // Cobra Pro/HyperSpeed add a visible on-the-fly DPI clutch button behind the wheel.
            if silhouette == .cobraPro {
                let dpi = CGRect(x: cx - wheelW * 0.55, y: cy - 0.02 * s, width: wheelW * 1.1, height: s * 0.05)
                ctx.addPath(CGPath(roundedRect: dpi, cornerWidth: s * 0.025, cornerHeight: s * 0.025, transform: nil))
            }
            ctx.strokePath()

            // Triskelion mark near the base.
            if razerCutout {
                let center = P(0, -0.29)
                let r = s * 0.105
                for k in 0..<3 {
                    let a = CGFloat(k) * (2 * .pi / 3) - .pi / 2
                    let perp = a + .pi / 2
                    func pt(_ along: CGFloat, _ side: CGFloat) -> CGPoint {
                        CGPoint(x: center.x + cos(a) * r * along + cos(perp) * s * side,
                                y: center.y + sin(a) * r * along + sin(perp) * s * side)
                    }
                    let blade = CGMutablePath()
                    blade.move(to: pt(0.0, -0.01))
                    blade.addCurve(to: pt(1.0, 0.035), control1: pt(0.35, 0.07), control2: pt(0.85, 0.07))
                    ctx.addPath(blade)
                }
                ctx.setLineWidth(lw * 0.85)
                ctx.strokePath()
            }
            return true
        }
    }

    // MARK: App icon

    /// The app icon: the serpent on a rounded-square background.
    static func appIcon(size: CGFloat, bg: NSColor, mark: NSColor) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let radius = size * 0.225
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
            bg.setFill(); rect.fill()
            let m = size * 0.72
            drawSerpent(size: m, color: mark)
                .draw(in: NSRect(x: (size - m) / 2, y: (size - m) / 2, width: m, height: m))
            return true
        }
    }

    static func writeAppIcon(to path: String, size: CGFloat, bg: NSColor, mark: NSColor) {
        let image = appIcon(size: size, bg: bg, mark: mark)
        let px = Int(size)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: CGFloat(px), height: CGFloat(px)))
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    // MARK: Previews

    /// Render a mark to a PNG file (used by the `icon` and `icon-models` CLI commands for
    /// visual verification). No `silhouette` draws the serpent.
    @discardableResult
    static func writePreview(to path: String, size: CGFloat, silhouette: RazerMouseSilhouette? = nil,
                             razerCutout: Bool = true, charging: Bool = false,
                             lightMenuBar: Bool = false) -> Bool {
        // Charging previews reproduce a real menu-bar pairing — body and bolt colour both
        // depend on it, and the light one is the harder of the two to get right (yellow on
        // white). They use the shipping dynamic colours, drawn under that menu bar's
        // appearance below, so the preview can't disagree with the menu bar. Non-charging
        // keeps the brand green: it's a shape check, not a colour one.
        let green = NSColor(red: 0x44/255, green: 0xD6/255, blue: 0x2C/255, alpha: 1)
        let image: NSImage
        if let silhouette {
            image = drawMouse(size: size, razerCutout: razerCutout, silhouette: silhouette, color: green)
        } else {
            image = drawSerpent(size: size, color: charging ? chargingBody : green, charging: charging,
                                boltColor: charging ? chargingBolt : nil)
        }
        let px = Int(size)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return false }

        NSAppearance(named: lightMenuBar ? .aqua : .darkAqua)?.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            // Backdrop matches the menu bar being previewed — a light-mode mark on a dark
            // square would tell you nothing about the contrast that actually matters.
            (lightMenuBar ? NSColor(white: 0.93, alpha: 1) : NSColor(white: 0.12, alpha: 1)).setFill()
            NSRect(x: 0, y: 0, width: CGFloat(px), height: CGFloat(px)).fill()
            image.draw(in: NSRect(x: 0, y: 0, width: CGFloat(px), height: CGFloat(px)))
            NSGraphicsContext.restoreGraphicsState()
        }

        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            return true
        } catch {
            FileHandle.standardError.write(Data("[Serpentine] icon write failed: \(error)\n".utf8))
            return false
        }
    }
}
