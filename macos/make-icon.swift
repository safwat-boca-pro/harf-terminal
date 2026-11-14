// Renders the Harf mark into AppIcon.icns. Run: swift make-icon.swift (needs iconutil).
import AppKit

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let s = CGFloat(px) / 1024
    let cg = ctx.cgContext
    cg.translateBy(x: 0, y: CGFloat(px)); cg.scaleBy(x: s, y: -s) // y-down, 1024 units
    func hex(_ v: UInt32) -> NSColor { NSColor(srgbRed: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1) }
    hex(0xfaf8f4).setFill()
    NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185).fill()
    // Mark: 96x120 design units, scaled 5x, centred.
    cg.translateBy(x: 512 - 240, y: 512 - 300); cg.scaleBy(x: 5, y: 5)
    let arch = NSBezierPath()
    arch.move(to: NSPoint(x: 0, y: 48))
    arch.appendArc(withCenter: NSPoint(x: 48, y: 48), radius: 48, startAngle: 180, endAngle: 0, clockwise: false) // y-down: top half
    arch.line(to: NSPoint(x: 96, y: 110))
    arch.appendArc(withCenter: NSPoint(x: 86, y: 110), radius: 10, startAngle: 0, endAngle: 90, clockwise: false)
    arch.line(to: NSPoint(x: 10, y: 120))
    arch.appendArc(withCenter: NSPoint(x: 10, y: 110), radius: 10, startAngle: 90, endAngle: 180, clockwise: false)
    arch.close()
    hex(0x0e6b6b).setFill(); arch.fill()
    let chev = NSBezierPath()
    chev.move(to: NSPoint(x: 71, y: 50)); chev.line(to: NSPoint(x: 49, y: 72)); chev.line(to: NSPoint(x: 71, y: 94))
    chev.lineWidth = 11; chev.lineCapStyle = .round; chev.lineJoinStyle = .round
    NSColor.white.setStroke(); chev.stroke()
    hex(0xe3a21a).setFill()
    NSBezierPath(roundedRect: NSRect(x: 19, y: 53, width: 14, height: 38), xRadius: 4, yRadius: 4).fill()
    return rep.representation(using: .png, properties: [:])!
}

let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: dir)
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: dir.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: dir.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns")
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", dir.path, "-o", out.path]
try! p.run(); p.waitUntilExit()
