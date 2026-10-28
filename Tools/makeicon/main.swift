import AppKit
import CoreImage

// Pulsar's app icon: a neutron star seen edge-on — hot core, two emission beams, faint pulse rings.
//
// Drawn in code so it stays reviewable and regenerable at any size, and because a megabyte of
// binary PNG has no place in a repository whose entire point is being small.


/// Render into an offscreen layer, blur it, and hand it back. Soft light needs a real blur;
/// stacking translucent copies just produces visible banding.
func blurredLayer(size: CGFloat, radius: CGFloat, draw: (CGContext, NSRect) -> Void) -> NSBitmapImageRep? {
    let px = Int(size)
    guard let layer = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: layer)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.clear(NSRect(x: 0, y: 0, width: size, height: size))
    draw(ctx, NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()

    guard let input = CIImage(bitmapImageRep: layer) else { return layer }
    let blurred = input.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
    let centre = CIVector(x: input.extent.midX, y: input.extent.midY)
    let cropped = blurred.clampedToExtent()
        .applyingFilter("CICrop", parameters: ["inputRectangle": CIVector(cgRect: input.extent)])
        .transformed(by: CGAffineTransform(translationX: -input.extent.minX, y: -input.extent.minY))
    _ = centre

    let context = CIContext(options: [.useSoftwareRenderer: false])
    guard let cg = context.createCGImage(cropped, from: cropped.extent) else { return layer }
    let out = NSBitmapImageRep(cgImage: cg)
    return out
}

func drawIcon(in size: CGFloat) -> NSBitmapImageRep {
    let px = Int(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                               pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    guard let ctx = NSGraphicsContext.current?.cgContext else { return rep }

    let inset = size * 0.045
    let body = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let squircle = NSBezierPath(roundedRect: body, xRadius: size * 0.225, yRadius: size * 0.225)

    // Deep space: near-black with a cold blue cast.
    NSGradient(colors: [
        NSColor(srgbRed: 0.04, green: 0.05, blue: 0.10, alpha: 1),
        NSColor(srgbRed: 0.09, green: 0.12, blue: 0.24, alpha: 1),
    ])!.draw(in: squircle, angle: -90)

    let centre = NSPoint(x: body.midX, y: body.midY)
    let beamLength = body.width * 0.55
    let halfAngle = CGFloat.pi / 30        // narrow cone: a beam, not a spotlight
    let axis = CGFloat.pi / 4              // two beams on one diagonal

    // The mark is the same four-point star as the menu-bar glyph, so the Dock icon and the menu
    // bar read as one product. Same geometry: four long points, four short, inner radius 30%.
    func starPath(radius outer: CGFloat) -> NSBezierPath {
        let inner = outer * 0.30
        let path = NSBezierPath()
        for step in 0..<8 {
            let angle = CGFloat(step) * .pi / 4 + .pi / 2        // first point straight up
            let r = step.isMultiple(of: 2) ? outer : inner
            let point = NSPoint(x: centre.x + cos(angle) * r, y: centre.y + sin(angle) * r)
            step == 0 ? path.move(to: point) : path.line(to: point)
        }
        path.close()
        return path
    }

    let outer = body.width * 0.34
    let star = starPath(radius: outer)

    // A soft bloom behind the star does the work a flat fill cannot: it separates the mark from the
    // background and gives it the glow the menu-bar version gets for free from the system tint.
    if let bloom = blurredLayer(size: size, radius: size * 0.042, draw: { layerCtx, _ in
        NSColor(srgbRed: 0.55, green: 0.80, blue: 1.0, alpha: 0.85).setFill()
        starPath(radius: outer * 1.02).fill()
    }) {
        bloom.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
                   from: NSRect(x: 0, y: 0, width: size, height: size),
                   operation: .plusLighter, fraction: 0.70,
                   respectFlipped: false, hints: nil)
    }

    // The star itself: white at the core, cooling to blue at the points.
    NSGraphicsContext.saveGraphicsState()
    star.addClip()
    NSGradient(colorsAndLocations:
        (NSColor.white, 0.0),
        (NSColor(srgbRed: 0.80, green: 0.92, blue: 1.0, alpha: 1.0), 0.45),
        (NSColor(srgbRed: 0.45, green: 0.75, blue: 1.0, alpha: 1.0), 1.0),
    )!.draw(in: NSRect(x: centre.x - outer, y: centre.y - outer,
                       width: outer * 2, height: outer * 2),
            relativeCenterPosition: .zero)
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/Pulsar.iconset"
try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

let variants: [(name: String, pixels: CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    let rep = drawIcon(in: variant.pixels)
    guard let data = rep.representation(using: .png, properties: [:]) else { continue }
    let path = (outputDir as NSString).appendingPathComponent("\(variant.name).png")
    try? data.write(to: URL(fileURLWithPath: path))
}

print("wrote \(variants.count) sizes to \(outputDir)")
