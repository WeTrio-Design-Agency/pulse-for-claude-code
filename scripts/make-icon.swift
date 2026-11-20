// Renders Resources/AppIcon.icns: dark squircle, a progress ring, an orange spark. Run: swift scripts/make-icon.swift
import AppKit

func draw(_ px: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: px, height: px), flipped: false) { r in
        let s = px / 1024
        let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
        let path = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
        NSGradient(starting: NSColor(calibratedWhite: 0.24, alpha: 1), ending: NSColor(calibratedWhite: 0.09, alpha: 1))!
            .draw(in: path, angle: -90)
        let c = NSPoint(x: tile.midX, y: tile.midY)
        let radius = 255 * s
        let track = NSBezierPath()
        track.appendArc(withCenter: c, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = 64 * s
        NSColor(calibratedWhite: 1, alpha: 0.14).setStroke()
        track.stroke()
        let arc = NSBezierPath()
        arc.appendArc(withCenter: c, radius: radius, startAngle: 90, endAngle: 90 - 0.72 * 360, clockwise: true)
        arc.lineWidth = 64 * s
        arc.lineCapStyle = .round
        NSColor(srgbRed: 0.04, green: 0.52, blue: 1, alpha: 1).setStroke()
        arc.stroke()
        let spark = NSBezierPath()
        for i in 0..<8 {
            let a = CGFloat(i) * .pi / 4 + .pi / 8
            spark.move(to: NSPoint(x: c.x + cos(a) * 30 * s, y: c.y + sin(a) * 30 * s))
            spark.line(to: NSPoint(x: c.x + cos(a) * 128 * s, y: c.y + sin(a) * 128 * s))
        }
        spark.lineWidth = 38 * s
        spark.lineCapStyle = .round
        NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1).setStroke()
        spark.stroke()
        return true
    }
}

let fm = FileManager.default
let set = URL(fileURLWithPath: "build/AppIcon.iconset")
try? fm.removeItem(at: set)
try! fm.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let img = draw(px)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px), pixelsHigh: Int(px), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        img.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! rep.representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent(name))
    }
}
