import AppKit
import CoreImage

// logomark — renders Pulsar's four-point star as a transparent PNG for terminals and docs.
//
// Same geometry as the app icon (inner radius 30%, first point up) and the same bloom, but with no
// squircle: a terminal or a dark document already supplies the background, and a rounded tile in
// the middle of a splash looks like a pasted screenshot.

func render(size: CGFloat, radius glow: CGFloat) -> NSBitmapImageRep {
    let px = Int(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)

    let centre = CGPoint(x: size / 2, y: size / 2)
    let outer = size * 0.42
    let inner = outer * 0.30

    func star(scale: CGFloat) -> CGPath {
        let path = CGMutablePath()
        for step in 0..<8 {
            let angle = CGFloat(step) * .pi / 4 + .pi / 2       // first point straight up
            let r = (step.isMultiple(of: 2) ? outer : inner) * scale
            let point = CGPoint(x: centre.x + cos(angle) * r, y: centre.y + sin(angle) * r)
            step == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }

    // 1. bloom — the wide, soft halo first, so the solid star sits on top of it
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: size * 0.16,
                  color: NSColor(srgbRed: 0.45, green: 0.78, blue: 1.0, alpha: 0.95).cgColor)
    ctx.setFillColor(NSColor(srgbRed: 0.55, green: 0.82, blue: 1.0, alpha: 0.55).cgColor)
    ctx.addPath(star(scale: 0.96))
    ctx.fillPath()
    ctx.restoreGState()

    // 2. pulse rings — a neutron star's radio beams sweeping out, kept faint
    ctx.saveGState()
    ctx.setStrokeColor(NSColor(srgbRed: 0.40, green: 0.70, blue: 1.0, alpha: 0.16).cgColor)
    ctx.setLineWidth(size * 0.004)
    for (index, fraction) in [0.60, 0.74, 0.88].enumerated() {
        ctx.setAlpha(0.20 - CGFloat(index) * 0.05)
        ctx.strokeEllipse(in: CGRect(x: centre.x - outer * fraction, y: centre.y - outer * fraction,
                                     width: outer * fraction * 2, height: outer * fraction * 2))
    }
    ctx.restoreGState()

    // 3. the star itself, white-hot core shading to blue at the tips
    ctx.saveGState()
    let path = star(scale: 1.0)
    ctx.addPath(path)
    ctx.clip()
    let colours = [
        NSColor(srgbRed: 0.72, green: 0.90, blue: 1.00, alpha: 1.0).cgColor,
        NSColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1.0).cgColor,
        NSColor(srgbRed: 0.72, green: 0.90, blue: 1.00, alpha: 1.0).cgColor,
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colours,
                              locations: [0.0, 0.5, 1.0])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: centre.x - outer, y: centre.y - outer),
                           end: CGPoint(x: centre.x + outer, y: centre.y + outer),
                           options: [])
    ctx.restoreGState()

    // 4. a small, very bright core
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: size * 0.05, color: NSColor.white.cgColor)
    ctx.setFillColor(NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.95).cgColor)
    let core = size * 0.045
    ctx.fillEllipse(in: CGRect(x: centre.x - core, y: centre.y - core, width: core * 2, height: core * 2))
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let size = CGFloat(Double(CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "1024") ?? 1024)
let out = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "/tmp/pulsar-logomark.png"

let rep = render(size: size, radius: size * 0.04)
guard let data = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("could not encode PNG\n".data(using: .utf8)!)
    exit(1)
}
try data.write(to: URL(fileURLWithPath: out))
print("wrote \(out) (\(Int(size))x\(Int(size)), \(data.count / 1024) KB)")
