// 生成 AppIcon.iconset：简约风格——深色圆角方块 + 两道白色斜杠「//」
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)

    // macOS 图标网格：内容区约占 80%，圆角约 22.5%
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let squircle = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [NSColor(white: 0.20, alpha: 1), NSColor(white: 0.08, alpha: 1)])!
        .draw(in: squircle, angle: -90)
    // 细微的内描边，让深色图标在深色 Dock 上也有轮廓
    NSColor(white: 1, alpha: 0.08).setStroke()
    squircle.lineWidth = max(1, s * 0.004)
    squircle.stroke()

    // 两道斜杠
    let w = rect.width
    let lineWidth = w * 0.085
    let height = w * 0.42
    let slant = height * 0.42
    let gap = w * 0.16
    let cx = rect.midX, cy = rect.midY
    NSColor.white.setStroke()
    for i in 0..<2 {
        let dx = (CGFloat(i) - 0.5) * gap
        let p = NSBezierPath()
        p.move(to: NSPoint(x: cx + dx - slant / 2, y: cy - height / 2))
        p.line(to: NSPoint(x: cx + dx + slant / 2, y: cy + height / 2))
        p.lineWidth = lineWidth
        p.lineCapStyle = .round
        p.stroke()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
