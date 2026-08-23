// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// The picture chat apps, Slack and Twitter show when someone links the repository: GitHub's
/// Settings › General › Social preview image, which has to be uploaded by hand — there is no
/// API for it. Worth doing, because the fallback is a grey card of the repo name and the
/// contributor count: GitHub never uses a README's hero image, however big it is.
///
/// Drawn in code like the app icon and the disk image background, out of the two pictures
/// already in docs/ — the icon, the name and the pitch on the left, the screenshot bled off
/// the right edge under a scrim that fades it into the background. It is cropped rather than
/// shrunk, so it still reads at the size a chat bubble gives it.
enum SocialCard {

    // GitHub asks for 1280×640 and scales that down per surface.
    static let width: CGFloat = 1280
    static let height: CGFloat = 640

    private static let title = "Nimbus Leviton Bar"
    private static let pitch = "Every Leviton Decora Smart Wi-Fi dimmer, switch, fan "
        + "controller and plug on your account, one click away in the menu bar."
    private static let slug = "github.com/njoubert/nimbus-leviton-bar"
    private static let accent = NSColor(srgbRed: 0.949, green: 0.698, blue: 0.243, alpha: 1)

    /// How wide a strip the screenshot gets. It is scaled to fill that strip and cropped,
    /// so a narrower panel means a smaller — more of the app — crop: pick the width that
    /// leaves the dropdown recognisable rather than a close-up of three rows.
    private static let panelWidth: CGFloat = 560
    /// How far past that fill scale to push it, and what survives the crop:
    /// (0,0) is the screenshot's bottom-left, (1,1) its top-right.
    private static let shotZoom: CGFloat = 1      // the dropdown at its own size
    private static let shotAnchor = CGPoint(x: 0.5, y: 1)     // the top: the bar's tally, All Devices, the first rooms

    private static let ink = NSColor(srgbRed: 0.031, green: 0.043, blue: 0.063, alpha: 1)
    private static let inkLift = NSColor(srgbRed: 0.067, green: 0.086, blue: 0.114, alpha: 1)
    private static let mist = NSColor(srgbRed: 0.604, green: 0.655, blue: 0.71, alpha: 1)
    private static let faint = NSColor(srgbRed: 0.388, green: 0.443, blue: 0.498, alpha: 1)

    private static let panel = CGRect(x: width - panelWidth, y: 0, width: panelWidth, height: height)
    private static let fadeWidth: CGFloat = 300
    private static let column: CGFloat = 78
    private static let columnWidth: CGFloat = 440

    /// Draw in a non-flipped (y up) context of `width`×`height` points.
    static func draw(icon: NSImage?, screenshot: NSImage?) {
        let all = CGRect(x: 0, y: 0, width: width, height: height)
        gradient(from: CGPoint(x: 0, y: height), to: CGPoint(x: width, y: 0),
                 stops: [(0, inkLift.cgColor), (1, ink.cgColor)], rect: all)
        glow(center: CGPoint(x: column + 40, y: height * 0.66), radius: 340, alpha: 0.13)

        // The screenshot fills the right panel, dissolving into the background at its left
        // edge so the text has quiet ground under it wherever the crop happens to be busy.
        // The fade is a mask on the picture, not a scrim over it: a flat scrim cannot match
        // a background that is itself a gradient, and leaves a visible seam.
        if let screenshot { cover(screenshot, in: panel) }

        // Left column: icon, name, pitch, where to find it — as one vertically centred block.
        let titleText = text(title, font: .systemFont(ofSize: 50, weight: .bold),
                             color: .white, tracking: -0.9, lineSpacing: 2)
        let pitchText = text(pitch, font: .systemFont(ofSize: 20.5, weight: .regular),
                             color: mist, tracking: 0, lineSpacing: 4.5)
        let slugText = text(slug, font: .monospacedSystemFont(ofSize: 15.5, weight: .regular),
                            color: faint, tracking: 0, lineSpacing: 0)
        let iconSide: CGFloat = 96
        let (titleH, pitchH, slugH) = (height(titleText), height(pitchText), height(slugText))
        let block = iconSide + 26 + titleH + 16 + pitchH + 26 + slugH
        var top = (height + block) / 2

        icon?.draw(in: CGRect(x: column, y: top - iconSide, width: iconSide, height: iconSide),
                   from: .zero, operation: .sourceOver, fraction: 1)
        top -= iconSide + 26
        top = place(titleText, height: titleH, top: top) - 16
        top = place(pitchText, height: pitchH, top: top) - 26
        _ = place(slugText, height: slugH, top: top)

        // A rule of the app's own colour along the bottom, fading out under the screenshot.
        gradient(from: CGPoint(x: 0, y: 0), to: CGPoint(x: width, y: 0),
                 stops: [(0, accent.cgColor), (0.55, accent.withAlphaComponent(0.45).cgColor),
                         (1, accent.withAlphaComponent(0).cgColor)],
                 rect: CGRect(x: 0, y: 0, width: width, height: 6))
    }

    // MARK: Pieces

    /// Fill `rect` with the image, cropping whatever the aspect ratios disagree about
    /// rather than letterboxing it — `shotAnchor` picks which end survives.
    private static func cover(_ img: NSImage, in rect: CGRect) {
        let size = img.size
        guard size.width > 0, size.height > 0 else { return }
        let scale = max(rect.width / size.width, rect.height / size.height) * shotZoom
        let drawn = CGSize(width: size.width * scale, height: size.height * scale)
        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext.current?.cgContext, let mask = fade(width: Int(rect.width)) {
            ctx.clip(to: rect, mask: mask)
        } else {
            NSBezierPath(rect: rect).setClip()
        }
        NSGraphicsContext.current?.imageInterpolation = .high
        img.draw(in: CGRect(x: rect.minX + (rect.width - drawn.width) * shotAnchor.x,
                            y: rect.minY + (rect.height - drawn.height) * shotAnchor.y,
                            width: drawn.width, height: drawn.height),
                 from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A grey ramp — transparent at the left edge, solid after `fadeWidth` — stretched over
    /// the panel to feather the screenshot into the background.
    private static func fade(width: Int) -> CGImage? {
        let gray = CGColorSpaceCreateDeviceGray()
        guard width > 0,
              let ctx = CGContext(data: nil, width: width, height: 1, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: gray,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let g = CGGradient(colorsSpace: gray,
                                 colors: [CGColor(gray: 0, alpha: 1), CGColor(gray: 0.35, alpha: 1),
                                          CGColor(gray: 1, alpha: 1)] as CFArray,
                                 locations: [0, 0.5, 1]) else { return nil }
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: fadeWidth, y: 0),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        return ctx.makeImage()
    }

    private static func text(_ s: String, font: NSFont, color: NSColor,
                             tracking: CGFloat, lineSpacing: CGFloat) -> NSAttributedString {
        let ps = NSMutableParagraphStyle()
        ps.lineBreakMode = .byWordWrapping
        ps.lineSpacing = lineSpacing
        return NSAttributedString(string: s, attributes: [
            .font: font, .foregroundColor: color, .kern: tracking, .paragraphStyle: ps])
    }

    private static func height(_ a: NSAttributedString) -> CGFloat {
        ceil(a.boundingRect(with: NSSize(width: columnWidth, height: .greatestFiniteMagnitude),
                            options: [.usesLineFragmentOrigin]).height)
    }

    /// Draw the block with its top edge at `top`; returns the y of its bottom edge.
    private static func place(_ a: NSAttributedString, height h: CGFloat, top: CGFloat) -> CGFloat {
        a.draw(with: CGRect(x: column, y: top - h, width: columnWidth, height: h),
               options: [.usesLineFragmentOrigin])
        return top - h
    }

    private static func gradient(from: CGPoint, to: CGPoint, stops: [(CGFloat, CGColor)], rect: CGRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext,
              let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 colors: stops.map { $0.1 } as CFArray,
                                 locations: stops.map { $0.0 }) else { return }
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.drawLinearGradient(g, start: from, end: to,
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    private static func glow(center: CGPoint, radius: CGFloat, alpha: CGFloat) {
        guard let ctx = NSGraphicsContext.current?.cgContext,
              let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 colors: [accent.withAlphaComponent(alpha).cgColor,
                                          accent.withAlphaComponent(0).cgColor] as CFArray,
                                 locations: [0, 1]) else { return }
        ctx.drawRadialGradient(g, startCenter: center, startRadius: 0,
                               endCenter: center, endRadius: radius, options: [])
    }

    // MARK: Rasterising

    /// Render the card from the pictures in docs/ and write it as a PNG.
    static func write(to path: String, icon iconPath: String, screenshot shotPath: String) throws {
        guard let icon = NSImage(contentsOfFile: iconPath) else {
            throw Failure("cannot read \(iconPath)")
        }
        guard let shot = NSImage(contentsOfFile: shotPath) else {
            throw Failure("cannot read \(shotPath)")
        }
        guard let ctx = CGContext(data: nil, width: Int(width), height: Int(height),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw Failure("cannot make the bitmap")
        }
        ctx.setAllowsAntialiasing(true)
        ctx.interpolationQuality = .high
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        draw(icon: icon, screenshot: shot)
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = ctx.makeImage(),
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            throw Failure("cannot encode the PNG")
        }
        // GitHub refuses a social preview over 1 MB, and a busier screenshot is what would
        // push it there — say so here rather than letting the upload fail on the web page.
        if data.count > 1_000_000 {
            fputs("warning: \(path) is \(data.count / 1024) KB; GitHub's limit is 1 MB\n", stderr)
        }
        try data.write(to: URL(fileURLWithPath: path))
    }

    struct Failure: LocalizedError {
        let what: String
        init(_ what: String) { self.what = what }
        var errorDescription: String? { what }
    }
}
