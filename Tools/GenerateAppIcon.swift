#!/usr/bin/env swift

// Generates the NB-Exercise app icon: a Vitruvian Man figure (two sets of arms
// and legs, inscribed in a circle and square) wearing an "NB" tracksuit, with
// the raised pair of arms holding dumbbells.
//
// Usage: xcrun --sdk macosx swift Tools/GenerateAppIcon.swift <output-directory>
// Emits Icon-light.png, Icon-dark.png and Icon-tinted.png at 1024x1024.

import AppKit
import Foundation

let canvas: CGFloat = 1024

// MARK: - Palette

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

func white(_ value: CGFloat) -> NSColor {
    NSColor(srgbRed: 1, green: 1, blue: 1, alpha: value)
}

struct Palette {
    var backgroundTop: NSColor?
    var backgroundBottom: NSColor?
    var guideLine: NSColor
    var suit: NSColor
    var trim: NSColor
    var skin: NSColor
    var placket: NSColor
    var plate: NSColor
    var bar: NSColor
    var mark: NSColor

    /// Full-bleed icon shown against a light home screen.
    static let light = Palette(
        backgroundTop: rgb(0x1B3358),
        backgroundBottom: rgb(0x081222),
        guideLine: rgb(0x4E80BE, 0.50),
        suit: rgb(0xF3F7FC),
        trim: rgb(0xD8253C),
        skin: rgb(0xF6DFC3),
        placket: rgb(0xAEBDCE),
        plate: rgb(0xD8253C),
        bar: rgb(0xC3CEDC),
        mark: rgb(0xD8253C)
    )

    /// Dark variant: no background, the system supplies its own backdrop.
    static let dark = Palette(
        backgroundTop: nil,
        backgroundBottom: nil,
        guideLine: rgb(0x5E90CE, 0.55),
        suit: rgb(0xEEF4FB),
        trim: rgb(0xFF4459),
        skin: rgb(0xF3D9B8),
        placket: rgb(0x8FA0B4),
        plate: rgb(0xFF4459),
        bar: rgb(0xA9B7C7),
        mark: rgb(0xFF4459)
    )

    /// Tinted variant: grayscale, the system colourises by luminance. The suit
    /// sits mid-grey so the bright trim, dumbbells and "NB" still read.
    static let tinted = Palette(
        backgroundTop: nil,
        backgroundBottom: nil,
        guideLine: white(0.32),
        suit: white(0.52),
        trim: white(1.00),
        skin: white(0.78),
        placket: white(0.30),
        plate: white(1.00),
        bar: white(0.68),
        mark: white(1.00)
    )
}

// MARK: - Geometry
//
// All coordinates are expressed in a top-left origin space, matching how the
// figure reads on screen. The context is flipped once up front.

let centre = CGPoint(x: 512, y: 512)
let circleRadius: CGFloat = 388
let squareRect = CGRect(x: 152, y: 180, width: 720, height: 720)

let headCentre = CGPoint(x: 512, y: 274)
let headRadius: CGFloat = 60

let shoulderLeft = CGPoint(x: 404, y: 382)
let shoulderRight = CGPoint(x: 620, y: 382)
let hipLeft = CGPoint(x: 470, y: 644)
let hipRight = CGPoint(x: 554, y: 644)

// Lower arms reach the left and right edges of the square.
let armWideLeft = [shoulderLeft, CGPoint(x: 276, y: 396), CGPoint(x: 168, y: 404)]
let armWideRight = [shoulderRight, CGPoint(x: 748, y: 396), CGPoint(x: 856, y: 404)]

// Raised arms reach the circle, and hold the dumbbells.
let armRaisedLeft = [shoulderLeft, CGPoint(x: 318, y: 306), CGPoint(x: 244, y: 232)]
let armRaisedRight = [shoulderRight, CGPoint(x: 706, y: 306), CGPoint(x: 780, y: 232)]

// Closed legs reach the bottom of the square, spread legs reach the circle.
let legClosedLeft = [hipLeft, CGPoint(x: 474, y: 780), CGPoint(x: 478, y: 890)]
let legClosedRight = [hipRight, CGPoint(x: 550, y: 780), CGPoint(x: 546, y: 890)]
let legSpreadLeft = [hipLeft, CGPoint(x: 392, y: 748), CGPoint(x: 322, y: 848)]
let legSpreadRight = [hipRight, CGPoint(x: 632, y: 748), CGPoint(x: 702, y: 848)]

let armWidth: CGFloat = 34
let legWidth: CGFloat = 40
let trimInset: CGFloat = 12

// MARK: - Drawing helpers

/// Strokes a limb twice — once wide in the trim colour, once narrower in the
/// suit colour — so a stripe of piping shows along both edges.
func drawLimb(_ ctx: CGContext, _ points: [CGPoint], width: CGFloat, palette: Palette) {
    let path = CGMutablePath()
    path.move(to: points[0])
    path.addQuadCurve(to: points[2], control: points[1])

    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    ctx.addPath(path)
    ctx.setStrokeColor(palette.trim.cgColor)
    ctx.setLineWidth(width)
    ctx.strokePath()

    ctx.addPath(path)
    ctx.setStrokeColor(palette.suit.cgColor)
    ctx.setLineWidth(width - trimInset)
    ctx.strokePath()
}

func drawFoot(_ ctx: CGContext, from ankle: CGPoint, to toe: CGPoint, palette: Palette) {
    ctx.setLineCap(.round)
    ctx.setStrokeColor(palette.trim.cgColor)
    ctx.setLineWidth(30)
    ctx.move(to: ankle)
    ctx.addLine(to: toe)
    ctx.strokePath()
}

func fillCircle(_ ctx: CGContext, at point: CGPoint, radius: CGFloat, color: NSColor) {
    ctx.setFillColor(color.cgColor)
    ctx.fillEllipse(in: CGRect(x: point.x - radius, y: point.y - radius,
                               width: radius * 2, height: radius * 2))
}

func fillRoundedRect(_ ctx: CGContext, centre: CGPoint, size: CGSize, radius: CGFloat, color: NSColor) {
    let rect = CGRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2,
                      width: size.width, height: size.height)
    ctx.setFillColor(color.cgColor)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.fillPath()
}

/// Draws text upright inside the flipped context by locally undoing the flip.
func drawCentredText(_ string: String, at point: CGPoint, size: CGFloat, color: NSColor) {
    guard let context = NSGraphicsContext.current else { return }
    let ctx = context.cgContext
    ctx.saveGState()
    ctx.translateBy(x: point.x, y: point.y)
    ctx.scaleBy(x: 1, y: -1)

    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: .black),
        .foregroundColor: color,
        .kern: 1.0
    ]
    let attributed = NSAttributedString(string: string, attributes: attributes)
    let bounds = attributed.size()
    attributed.draw(at: NSPoint(x: -bounds.width / 2, y: -bounds.height / 2))

    ctx.restoreGState()
}

func torsoPath() -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 394, y: 366))
    // Collar dip at the neck.
    path.addQuadCurve(to: CGPoint(x: 474, y: 352), control: CGPoint(x: 428, y: 348))
    path.addQuadCurve(to: CGPoint(x: 512, y: 386), control: CGPoint(x: 494, y: 376))
    path.addQuadCurve(to: CGPoint(x: 550, y: 352), control: CGPoint(x: 530, y: 376))
    path.addQuadCurve(to: CGPoint(x: 630, y: 366), control: CGPoint(x: 596, y: 348))
    // Right side down to the hip.
    path.addLine(to: CGPoint(x: 618, y: 440))
    path.addQuadCurve(to: CGPoint(x: 580, y: 556), control: CGPoint(x: 600, y: 500))
    path.addQuadCurve(to: CGPoint(x: 592, y: 646), control: CGPoint(x: 588, y: 606))
    // Hem.
    path.addLine(to: CGPoint(x: 432, y: 646))
    // Left side back up to the shoulder.
    path.addQuadCurve(to: CGPoint(x: 444, y: 556), control: CGPoint(x: 436, y: 606))
    path.addQuadCurve(to: CGPoint(x: 406, y: 440), control: CGPoint(x: 424, y: 500))
    path.closeSubpath()
    return path
}

func drawDumbbell(_ ctx: CGContext, at hand: CGPoint, palette: Palette) {
    fillRoundedRect(ctx, centre: hand, size: CGSize(width: 116, height: 15), radius: 7.5, color: palette.bar)
    for offset in [-44, 44] as [CGFloat] {
        let plateCentre = CGPoint(x: hand.x + offset, y: hand.y)
        fillRoundedRect(ctx, centre: plateCentre, size: CGSize(width: 28, height: 68), radius: 10, color: palette.plate)
    }
    for offset in [-24, 24] as [CGFloat] {
        let collarCentre = CGPoint(x: hand.x + offset, y: hand.y)
        fillRoundedRect(ctx, centre: collarCentre, size: CGSize(width: 13, height: 38), radius: 5, color: palette.bar)
    }
}

// MARK: - Icon composition

func renderIcon(palette: Palette) -> NSBitmapImageRep {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
                                     bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0),
          let graphicsContext = NSGraphicsContext(bitmapImageRep: rep) else {
        fatalError("Unable to create bitmap context")
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext
    let ctx = graphicsContext.cgContext

    // Work in a top-left origin space for the rest of the drawing.
    ctx.translateBy(x: 0, y: canvas)
    ctx.scaleBy(x: 1, y: -1)

    // Background.
    if let top = palette.backgroundTop, let bottom = palette.backgroundBottom {
        let colors = [top.cgColor, bottom.cgColor] as CFArray
        if let space = CGColorSpace(name: CGColorSpace.sRGB),
           let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient,
                                   start: CGPoint(x: 0, y: 0),
                                   end: CGPoint(x: canvas, y: canvas),
                                   options: [])
        }
        // Soft glow behind the figure.
        let glow = [white(0.10).cgColor, white(0).cgColor] as CFArray
        if let space = CGColorSpace(name: CGColorSpace.sRGB),
           let radial = CGGradient(colorsSpace: space, colors: glow, locations: [0, 1]) {
            ctx.drawRadialGradient(radial,
                                   startCenter: CGPoint(x: 512, y: 430), startRadius: 0,
                                   endCenter: CGPoint(x: 512, y: 430), endRadius: 620,
                                   options: [])
        }
    }

    // Vitruvian circle and square.
    ctx.setStrokeColor(palette.guideLine.cgColor)
    ctx.setLineWidth(7)
    ctx.strokeEllipse(in: CGRect(x: centre.x - circleRadius, y: centre.y - circleRadius,
                                 width: circleRadius * 2, height: circleRadius * 2))
    ctx.stroke(squareRect)

    // Back pair of limbs.
    drawLimb(ctx, armRaisedLeft, width: armWidth, palette: palette)
    drawLimb(ctx, armRaisedRight, width: armWidth, palette: palette)
    drawLimb(ctx, legSpreadLeft, width: legWidth, palette: palette)
    drawLimb(ctx, legSpreadRight, width: legWidth, palette: palette)
    drawFoot(ctx, from: legSpreadLeft[2], to: CGPoint(x: 280, y: 868), palette: palette)
    drawFoot(ctx, from: legSpreadRight[2], to: CGPoint(x: 744, y: 868), palette: palette)

    // Front pair of limbs.
    drawLimb(ctx, armWideLeft, width: armWidth, palette: palette)
    drawLimb(ctx, armWideRight, width: armWidth, palette: palette)
    drawLimb(ctx, legClosedLeft, width: legWidth, palette: palette)
    drawLimb(ctx, legClosedRight, width: legWidth, palette: palette)
    drawFoot(ctx, from: legClosedLeft[2], to: CGPoint(x: 436, y: 896), palette: palette)
    drawFoot(ctx, from: legClosedRight[2], to: CGPoint(x: 588, y: 896), palette: palette)

    // Open hands on the wide arms.
    fillCircle(ctx, at: armWideLeft[2], radius: 17, color: palette.skin)
    fillCircle(ctx, at: armWideRight[2], radius: 17, color: palette.skin)

    // Neck, then the jacket over it.
    ctx.setFillColor(palette.skin.cgColor)
    ctx.fill(CGRect(x: 489, y: 320, width: 46, height: 62))

    let torso = torsoPath()
    ctx.addPath(torso)
    ctx.setFillColor(palette.suit.cgColor)
    ctx.fillPath()
    ctx.addPath(torso)
    ctx.setStrokeColor(palette.trim.cgColor)
    ctx.setLineWidth(9)
    ctx.strokePath()

    // Placket below the collar.
    ctx.setLineCap(.round)
    ctx.setStrokeColor(palette.placket.cgColor)
    ctx.setLineWidth(6)
    ctx.move(to: CGPoint(x: 512, y: 392))
    ctx.addLine(to: CGPoint(x: 512, y: 466))
    ctx.strokePath()

    drawCentredText("NB", at: CGPoint(x: 512, y: 540), size: 78, color: palette.mark)

    // Head with a headband.
    fillCircle(ctx, at: headCentre, radius: headRadius, color: palette.skin)
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: headCentre.x - headRadius, y: headCentre.y - headRadius,
                              width: headRadius * 2, height: headRadius * 2))
    ctx.clip()
    ctx.setFillColor(palette.trim.cgColor)
    ctx.fill(CGRect(x: headCentre.x - headRadius, y: 238, width: headRadius * 2, height: 22))
    ctx.restoreGState()

    // Dumbbells in the raised hands.
    drawDumbbell(ctx, at: armRaisedLeft[2], palette: palette)
    drawDumbbell(ctx, at: armRaisedRight[2], palette: palette)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// MARK: - Entry point

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: GenerateAppIcon.swift <output-directory>\n".utf8))
    exit(1)
}
let outputDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)

for (name, palette) in [("Icon-light", Palette.light),
                        ("Icon-dark", Palette.dark),
                        ("Icon-tinted", Palette.tinted)] {
    let rep = renderIcon(palette: palette)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("Unable to encode \(name)")
    }
    let url = outputDirectory.appendingPathComponent("\(name).png")
    try data.write(to: url)
    print("wrote \(url.path)")
}
