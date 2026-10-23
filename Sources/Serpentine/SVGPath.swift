// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import CoreGraphics
import Foundation

/// Turns SVG path data (the `d` attribute) into a `CGPath`, so an icon drawn elsewhere can be
/// pasted in as it is and still be drawn natively: stroked, coloured per appearance, at any size.
/// Covers the commands icon sets use: M L H V C S Q T A Z, absolute and relative. The result is
/// in the SVG's own coordinates (y down); the caller scales and flips it.
enum SVGPath {
    static func parse(_ d: String) -> CGPath {
        let path = CGMutablePath()
        var tokens = Tokens(d)
        var command: Character = "M"
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        // The previous curve's second control point, for S and T.
        var lastCubic: CGPoint?
        var lastQuad: CGPoint?

        while let next = tokens.peek() {
            if case .command(let c) = next {
                tokens.advance()
                command = c
                if c == "Z" || c == "z" {
                    path.closeSubpath()
                    current = subpathStart
                    lastCubic = nil; lastQuad = nil
                    continue
                }
            }
            let relative = command.isLowercase
            func point() -> CGPoint? {
                guard let x = tokens.number(), let y = tokens.number() else { return nil }
                return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }
            var cubic: CGPoint?, quad: CGPoint?
            switch command.uppercased().first {
            case "M":
                guard let p = point() else { return path }
                path.move(to: p)
                current = p; subpathStart = p
                // Further pairs after a moveto are linetos.
                command = relative ? "l" : "L"
            case "L":
                guard let p = point() else { return path }
                path.addLine(to: p); current = p
            case "H":
                guard let x = tokens.number() else { return path }
                current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: current)
            case "V":
                guard let y = tokens.number() else { return path }
                current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: current)
            case "C":
                guard let c1 = point(), let c2 = point(), let p = point() else { return path }
                path.addCurve(to: p, control1: c1, control2: c2)
                cubic = c2; current = p
            case "S":
                let c1 = lastCubic.map { reflect($0, about: current) } ?? current
                guard let c2 = point(), let p = point() else { return path }
                path.addCurve(to: p, control1: c1, control2: c2)
                cubic = c2; current = p
            case "Q":
                guard let c = point(), let p = point() else { return path }
                path.addQuadCurve(to: p, control: c)
                quad = c; current = p
            case "T":
                let c = lastQuad.map { reflect($0, about: current) } ?? current
                guard let p = point() else { return path }
                path.addQuadCurve(to: p, control: c)
                quad = c; current = p
            case "A":
                guard let rx = tokens.number(), let ry = tokens.number(), let rotation = tokens.number(),
                      let large = tokens.flag(), let sweep = tokens.flag(), let p = point() else { return path }
                addArc(to: path, from: current, to: p, rx: rx, ry: ry, degrees: rotation,
                       large: large, sweep: sweep)
                current = p
            default:
                return path
            }
            lastCubic = cubic
            lastQuad = quad
        }
        return path
    }

    private static func reflect(_ p: CGPoint, about c: CGPoint) -> CGPoint {
        CGPoint(x: 2 * c.x - p.x, y: 2 * c.y - p.y)
    }

    /// An elliptical arc as cubic Béziers, per the SVG spec's endpoint-to-centre conversion
    /// (SVG 1.1, appendix F.6.5), in pieces of at most a quarter turn.
    private static func addArc(to path: CGMutablePath, from p1: CGPoint, to p2: CGPoint,
                               rx: CGFloat, ry: CGFloat, degrees: CGFloat, large: Bool, sweep: Bool) {
        var rx = abs(rx), ry = abs(ry)
        guard rx > 0, ry > 0, p1 != p2 else { path.addLine(to: p2); return }
        let phi = degrees * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p1.x - p2.x) / 2, dy = (p1.y - p2.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy
        // Radii too small to reach are scaled up until they just do.
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 { rx *= lambda.squareRoot(); ry *= lambda.squareRoot() }
        let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coef = (max(0, num) / den).squareRoot()
        if large == sweep { coef = -coef }
        let cxp = coef * rx * y1p / ry
        let cyp = -coef * ry * x1p / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (p1.x + p2.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p1.y + p2.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        }
        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }

        func at(_ t: CGFloat) -> CGPoint {
            CGPoint(x: cx + rx * cos(t) * cosPhi - ry * sin(t) * sinPhi,
                    y: cy + rx * cos(t) * sinPhi + ry * sin(t) * cosPhi)
        }
        func tangent(_ t: CGFloat) -> CGPoint {
            CGPoint(x: -rx * sin(t) * cosPhi - ry * cos(t) * sinPhi,
                    y: -rx * sin(t) * sinPhi + ry * cos(t) * cosPhi)
        }
        let pieces = max(1, Int((abs(delta) / (.pi / 2)).rounded(.up)))
        let step = delta / CGFloat(pieces)
        let k = 4 / 3 * tan(step / 4)
        var t = theta1
        for i in 0..<pieces {
            let a = at(t), b = at(t + step)
            let ta = tangent(t), tb = tangent(t + step)
            path.addCurve(to: i == pieces - 1 ? p2 : b,
                          control1: CGPoint(x: a.x + k * ta.x, y: a.y + k * ta.y),
                          control2: CGPoint(x: b.x - k * tb.x, y: b.y - k * tb.y))
            t += step
        }
    }

    /// Path data is commands and numbers with optional separators, where "1.5.5" is two
    /// numbers and an arc's flags may be written with no space at all ("a1 1 0 01 1 1").
    private struct Tokens {
        enum Token { case command(Character), number }
        private let chars: [Character]
        private var i = 0

        init(_ s: String) { chars = Array(s) }

        private mutating func skipSeparators() {
            while i < chars.count, chars[i].isWhitespace || chars[i] == "," { i += 1 }
        }

        mutating func peek() -> Token? {
            skipSeparators()
            guard i < chars.count else { return nil }
            let c = chars[i]
            return c.isLetter && c != "e" && c != "E" ? .command(c) : .number
        }

        mutating func advance() { i += 1 }

        mutating func flag() -> Bool? {
            skipSeparators()
            guard i < chars.count, chars[i] == "0" || chars[i] == "1" else { return nil }
            defer { i += 1 }
            return chars[i] == "1"
        }

        mutating func number() -> CGFloat? {
            skipSeparators()
            let start = i
            if i < chars.count, chars[i] == "-" || chars[i] == "+" { i += 1 }
            var seenDot = false, seenDigit = false
            while i < chars.count {
                let c = chars[i]
                if c.isNumber { seenDigit = true; i += 1 }
                else if c == ".", !seenDot { seenDot = true; i += 1 }
                else if c == "e" || c == "E", seenDigit {
                    i += 1
                    if i < chars.count, chars[i] == "-" || chars[i] == "+" { i += 1 }
                    while i < chars.count, chars[i].isNumber { i += 1 }
                    break
                } else { break }
            }
            guard seenDigit, let value = Double(String(chars[start..<i])) else { i = start; return nil }
            return CGFloat(value)
        }
    }
}
