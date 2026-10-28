// Builds Scout's Icon Composer icon (AppIcon.icon) from the Compass design: the dial and the star
// as separate layers, so macOS 26 can mask the icon to its own shape and add Liquid Glass.
// Usage: swift make-app-icon.swift <path/to/AppIcon.icon>
import AppKit

let bundle = URL(fileURLWithPath: CommandLine.arguments[1])
let assets = bundle.appendingPathComponent("Assets")
try? FileManager.default.removeItem(at: bundle)
try! FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

let S: CGFloat = 1024
let C = CGPoint(x: 512, y: 512)
let k: CGFloat = 1024 / 824   // the variants were drawn on an 824 pt tile; Icon Composer layers fill the whole canvas

func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: a)
}

func circle(_ c: CGPoint, _ r: CGFloat) -> NSBezierPath {
    NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
}

func layer(_ name: String, _ body: () -> Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    body()
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: assets.appendingPathComponent("\(name).png"))
}

layer("dial") {
    hex(0xF6F1E4).setFill(); circle(C, 300 * k).fill()
    hex(0x0B5E5A, 0.18).setStroke()
    let ring = circle(C, 262 * k); ring.lineWidth = 6 * k; ring.stroke()
    for i in 0..<16 where i % 4 != 0 {
        let a = CGFloat(i) * .pi / 8
        let tick = NSBezierPath()
        tick.move(to: CGPoint(x: C.x + cos(a) * 262 * k, y: C.y + sin(a) * 262 * k))
        tick.line(to: CGPoint(x: C.x + cos(a) * 282 * k, y: C.y + sin(a) * 282 * k))
        tick.lineWidth = 8 * k; tick.lineCapStyle = .round
        hex(0x0B5E5A, 0.35).setStroke(); tick.stroke()
    }
}

layer("star") {
    let long = 250 * k, short = 62 * k
    for i in 0..<4 {
        let angle = CGFloat(i) * .pi / 2 + .pi / 2   // north first
        let tip = CGPoint(x: C.x + cos(angle) * long, y: C.y + sin(angle) * long)
        let l = CGPoint(x: C.x + cos(angle + .pi / 2) * short, y: C.y + sin(angle + .pi / 2) * short)
        let r = CGPoint(x: C.x + cos(angle - .pi / 2) * short, y: C.y + sin(angle - .pi / 2) * short)
        let left = NSBezierPath(); left.move(to: C); left.line(to: l); left.line(to: tip); left.close()
        let right = NSBezierPath(); right.move(to: C); right.line(to: tip); right.line(to: r); right.close()
        let north = i == 0
        (north ? hex(0xFF8A3D) : hex(0x1F6F6A)).setFill(); left.fill()
        (north ? hex(0xE8590C) : hex(0x0E4744)).setFill(); right.fill()
    }
    hex(0xF6F1E4).setFill(); circle(C, 22 * k).fill()
}

let json = """
{
  "fill" : {
    "linear-gradient" : [
      "srgb:0.07843,0.63922,0.60392,1.00000",
      "srgb:0.04314,0.36863,0.35294,1.00000"
    ]
  },
  "groups" : [
    {
      "layers" : [
        { "image-name" : "star.png", "name" : "star" }
      ],
      "shadow" : { "kind" : "neutral", "opacity" : 0.5 },
      "translucency" : { "enabled" : false, "value" : 0.5 }
    },
    {
      "layers" : [
        { "image-name" : "dial.png", "name" : "dial" }
      ],
      "shadow" : { "kind" : "neutral", "opacity" : 0.5 },
      "translucency" : { "enabled" : false, "value" : 0.5 }
    }
  ],
  "supported-platforms" : {
    "squares" : [ "macOS" ]
  }
}
"""
try! json.write(to: bundle.appendingPathComponent("icon.json"), atomically: true, encoding: .utf8)
print("ok")
