import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = root.appendingPathComponent(".build/HeroOOS.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
func png(size: Int, draw: (CGFloat) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(CGFloat(size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
for points in [16, 32, 128, 256, 512] {
    for density in [1, 2] {
        let size = points * density
        let data = png(size: size) { s in
            NSColor(srgbRed: 0.08, green: 0.12, blue: 0.13, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: s * 0.04, y: s * 0.04, width: s * 0.92, height: s * 0.92), xRadius: s * 0.2, yRadius: s * 0.2).fill()
            for row in 0..<3 {
                let y = s * (0.29 + Double(row) * 0.2)
                NSColor(srgbRed: 0.25, green: 0.79, blue: 0.64, alpha: 1).setStroke()
                let box = NSBezierPath(roundedRect: NSRect(x: s * 0.24, y: y, width: s * 0.105, height: s * 0.105), xRadius: s * 0.022, yRadius: s * 0.022)
                box.lineWidth = s * 0.02; box.stroke()
                NSColor.white.setStroke()
                let line = NSBezierPath(); line.lineWidth = s * 0.035; line.lineCapStyle = .round
                line.move(to: NSPoint(x: s * 0.43, y: y + s * 0.053)); line.line(to: NSPoint(x: s * (row == 0 ? 0.65 : 0.76), y: y + s * 0.053)); line.stroke()
            }
        }
        let name = "icon_\(points)x\(points)\(density == 2 ? "@2x" : "").png"
        try data.write(to: iconset.appendingPathComponent(name))
    }
}
