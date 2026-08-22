// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import AppKit
import CoreGraphics

/// The app icon, drawn in code (no .icns checked in): a dark macOS squircle with a Decora
/// paddle switch — the rectangular rocker Leviton's Smart Wi-Fi dimmers have — lit from
/// behind in warm light, with the little status LED the real ones carry.
/// `build.sh app` renders it to an .iconset → .icns; `build.sh icon` refreshes docs/icon.png.
enum AppIcon {

    // Apple's macOS icon grid in a 1024-pt reference canvas: 824×824 body, radius 185.4.
    private static let ref: CGFloat = 1024
    private static let bodyInset: CGFloat = 100
    private static let bodyRadius: CGFloat = 185.4

    private static let warm = rgb(0xFF, 0xC2, 0x5C)     // the light
    private static let warmDeep = rgb(0xFF, 0x8A, 0x2A)
    private static let paddle = rgb(0xF4, 0xF1, 0xEA)   // Leviton "white" plastic
    private static let paddleShade = rgb(0xC9, 0xC4, 0xB8)
    private static let led = rgb(0x5C, 0xE0, 0x8C)

    /// The scale of the current render: shadow offsets and blurs are in *base* space (Core
    /// Graphics does not transform them with the CTM), so every `setShadow` below multiplies
    /// by this — otherwise a 28-pt blur meant for the 1024 canvas is 28 device pixels at
    /// every size, which at the 128-pt icon is a quarter of the inset and gets clipped at the
    /// bottom edge into a hard line.
    nonisolated(unsafe) private static var scale: CGFloat = 1

    static func draw(in ctx: CGContext, size: CGFloat) {
        ctx.saveGState()
        scale = size / ref
        ctx.scaleBy(x: scale, y: scale)

        let body = CGRect(x: bodyInset, y: bodyInset, width: ref - 2 * bodyInset, height: ref - 2 * bodyInset)
        let shape = CGPath(roundedRect: body, cornerWidth: bodyRadius, cornerHeight: bodyRadius, transform: nil)

        // Shadow, as macOS icons carry their own. Kept small enough to fade out inside the
        // canvas: a shadow still visible at the edge is clipped to a hard line, which shows
        // as a grey box on light backgrounds (e.g. the disk image window).
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -12 * scale), blur: 28 * scale,
                      color: NSColor(calibratedWhite: 0, alpha: 0.45).cgColor)
        ctx.addPath(shape); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(shape); ctx.clip()

        // Body: deep warm graphite, lit from the top.
        fillLinear(ctx, from: CGPoint(x: 512, y: body.maxY), to: CGPoint(x: 512, y: body.minY),
                   stops: [(0, rgb(0x3A, 0x33, 0x2E)), (0.5, rgb(0x1E, 0x1A, 0x18)), (1, rgb(0x0D, 0x0B, 0x0A))],
                   rect: body)

        // The light: a warm bloom behind the paddle, as if the room behind the plate is lit.
        drawGlow(ctx, center: CGPoint(x: 512, y: 512), radius: 600, color: warmDeep, alpha: 0.35)

        drawPaddle(ctx)

        // Top-edge highlight.
        ctx.addPath(shape)
        ctx.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.14).cgColor)
        ctx.setLineWidth(3)
        ctx.strokePath()
        ctx.restoreGState()

        ctx.restoreGState()
    }

    /// A Decora paddle: tall rounded rectangle, the top half proud (pressed = on), a thin
    /// seam across the middle, and the green status LED near the bottom, left of centre —
    /// where Leviton puts it.
    private static func drawPaddle(_ ctx: CGContext) {
        let plate = CGRect(x: 322, y: 212, width: 380, height: 600)
        let plateShape = CGPath(roundedRect: plate, cornerWidth: 42, cornerHeight: 42, transform: nil)

        // Light leaking out around the plate: the plate's own shape, blurred wide in warm
        // light, drawn twice so the halo is bright at the edge and still reaches outwards.
        for (blur, alpha) in [(CGFloat(120), CGFloat(0.9)), (CGFloat(46), CGFloat(1.0))] {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: blur * scale, color: warm.copy(alpha: alpha))
            ctx.addPath(plateShape); ctx.setFillColor(warm); ctx.fillPath()
            ctx.restoreGState()
        }
        // And the plate's own shadow onto the body, below.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -14 * scale), blur: 30 * scale, color: NSColor(calibratedWhite: 0, alpha: 0.35).cgColor)
        ctx.addPath(plateShape); ctx.setFillColor(paddle); ctx.fillPath()
        ctx.restoreGState()

        // Plastic: faint vertical gradient, a little darker at the bottom.
        ctx.saveGState()
        ctx.addPath(plateShape); ctx.clip()
        fillLinear(ctx, from: CGPoint(x: 0, y: plate.maxY), to: CGPoint(x: 0, y: plate.minY),
                   stops: [(0, paddle), (0.55, paddle), (1, paddleShade)], rect: plate)

        // Lower half sits deeper: a soft shadow under the seam.
        let seamY = plate.midY + 40
        fillLinear(ctx, from: CGPoint(x: 0, y: seamY), to: CGPoint(x: 0, y: seamY - 70),
                   stops: [(0, rgb(0, 0, 0).copy(alpha: 0.18)!), (1, rgb(0, 0, 0).copy(alpha: 0)!)],
                   rect: CGRect(x: plate.minX, y: seamY - 70, width: plate.width, height: 70))
        ctx.setStrokeColor(rgb(0, 0, 0).copy(alpha: 0.22)!)
        ctx.setLineWidth(4)
        ctx.move(to: CGPoint(x: plate.minX + 26, y: seamY)); ctx.addLine(to: CGPoint(x: plate.maxX - 26, y: seamY))
        ctx.strokePath()

        // Top edge catch-light.
        ctx.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.9).cgColor)
        ctx.setLineWidth(6)
        ctx.addPath(CGPath(roundedRect: plate.insetBy(dx: 3, dy: 3), cornerWidth: 40, cornerHeight: 40, transform: nil))
        ctx.strokePath()
        ctx.restoreGState()

        // Status LED, glowing.
        let dot = CGRect(x: plate.minX + 52, y: plate.minY + 58, width: 30, height: 30)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 22 * scale, color: led.copy(alpha: 0.9))
        ctx.setFillColor(led)
        ctx.fillEllipse(in: dot)
        ctx.restoreGState()
    }

    // MARK: Helpers

    private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> CGColor {
        CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    private static func fillLinear(_ ctx: CGContext, from: CGPoint, to: CGPoint,
                                   stops: [(CGFloat, CGColor)], rect: CGRect) {
        guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 colors: stops.map { $0.1 } as CFArray,
                                 locations: stops.map { $0.0 }) else { return }
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    private static func drawGlow(_ ctx: CGContext, center: CGPoint, radius: CGFloat, color: CGColor, alpha: CGFloat) {
        guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 colors: [color.copy(alpha: alpha)!, color.copy(alpha: 0)!] as CFArray,
                                 locations: [0, 1]) else { return }
        ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    }

    // MARK: Rasterising

    static func cgImage(px: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setAllowsAntialiasing(true)
        ctx.interpolationQuality = .high
        draw(in: ctx, size: CGFloat(px))
        return ctx.makeImage()
    }

    static func pngData(px: Int) -> Data? {
        guard let cg = cgImage(px: px) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    /// Write an .iconset directory for `iconutil -c icns`.
    static func writeIconset(to dir: String) throws {
        let fm = FileManager.default
        try? fm.removeItem(atPath: dir)
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let variants: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                                      (256, 1), (256, 2), (512, 1), (512, 2)]
        for (pt, scale) in variants {
            let name = scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
            guard let data = pngData(px: pt * scale) else { continue }
            try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
    }
}
