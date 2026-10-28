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

    // Soft inner rim: keeps the tile distinguishable on a dark wallpaper without a hard outline.
    NSColor(white: 1, alpha: 0.07).setStroke()
    squircle.lineWidth = max(size * 0.006, 0.5)
    squircle.stroke()

    let centre = NSPoint(x: body.midX, y: body.midY)
    let beamLength = body.width * 0.55
    let halfAngle = CGFloat.pi / 30        // narrow cone: a beam, not a spotlight
    let axis = CGFloat.pi / 4              // two beams on one diagonal

    // Beams and pulse rings are drawn into a separate layer and blurred, then composited under a
    // sharp core. That is what makes them read as light rather than opaque wedges.
    if let layer = blurredLayer(size: size, radius: size * 0.022, draw: { layerCtx, _ in
        let beamLength = body.width * 0.55
        let halfAngle = CGFloat.pi / 28
        let axis = CGFloat.pi / 4

        for direction in [axis, axis + .pi] {
            let cone = NSBezierPath()
            cone.move(to: centre)
            cone.line(to: NSPoint(x: centre.x + cos(direction - halfAngle) * beamLength,
                                  y: centre.y + sin(direction - halfAngle) * beamLength))
            cone.line(to: NSPoint(x: centre.x + cos(direction + halfAngle) * beamLength,
                                  y: centre.y + sin(direction + halfAngle) * beamLength))
            cone.close()
            layerCtx.saveGState()
            cone.addClip()
            NSGradient(colorsAndLocations:
                (NSColor(srgbRed: 0.80, green: 0.94, blue: 1.0, alpha: 0.95), 0.0),
                (NSColor(srgbRed: 0.45, green: 0.72, blue: 1.0, alpha: 0.38), 0.24),
                (NSColor(srgbRed: 0.28, green: 0.48, blue: 1.0, alpha: 0.0), 0.70),
            )!.draw(in: NSRect(x: centre.x - beamLength, y: centre.y - beamLength,
                               width: beamLength * 2, height: beamLength * 2),
                    relativeCenterPosition: .zero)
            layerCtx.restoreGState()
        }

        if size >= 128 {
            for (ringRadius, alpha) in [(body.width * 0.29, CGFloat(0.26)), (body.width * 0.39, CGFloat(0.13))] {
                let ring = NSBezierPath(ovalIn: NSRect(x: centre.x - ringRadius, y: centre.y - ringRadius,
                                                       width: ringRadius * 2, height: ringRadius * 2))
                ring.lineWidth = max(size * 0.006, 0.5)
                NSColor(srgbRed: 0.58, green: 0.82, blue: 1.0, alpha: alpha).setStroke()
                ring.stroke()
            }
        }
    }) {
        layer.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
                   from: NSRect(x: 0, y: 0, width: size, height: size),
                   operation: .plusLighter, fraction: 1.0,
                   respectFlipped: false, hints: nil)
    }

    // The star: small bright core with a tight glow.
    let coreRadius = body.width * 0.10
    let glowRadius = coreRadius * 2.8
    NSGradient(colorsAndLocations:
        (NSColor(srgbRed: 0.95, green: 0.97, blue: 1.0, alpha: 0.98), 0.0),
        (NSColor(srgbRed: 0.62, green: 0.66, blue: 1.0, alpha: 0.42), 0.22),
        (NSColor(srgbRed: 0.35, green: 0.66, blue: 1.0, alpha: 0.28), 0.45),
        (NSColor(srgbRed: 0.20, green: 0.40, blue: 0.90, alpha: 0.0), 1.0),
    )!.draw(in: NSBezierPath(ovalIn: NSRect(x: centre.x - glowRadius, y: centre.y - glowRadius,
                                            width: glowRadius * 2, height: glowRadius * 2)),
            relativeCenterPosition: .zero)

    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: centre.x - coreRadius, y: centre.y - coreRadius,
                                width: coreRadius * 2, height: coreRadius * 2)).fill()

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
