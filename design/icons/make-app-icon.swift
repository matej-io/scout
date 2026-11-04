// Builds Scout's Icon Composer icon (AppIcon.icon) from the Folder Compass design: the folder and the star
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

/// Draws in the 1024 canvas the variants used (824 pt tile), scaled about the centre to fill the layer.
func tileSpace(_ body: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let t = NSAffineTransform()
    t.translateX(by: C.x, yBy: C.y); t.scale(by: k); t.translateX(by: -C.x, yBy: -C.y)
    t.concat()
    body()
    NSGraphicsContext.restoreGraphicsState()
}

/// Folder silhouette: rounded body with a tab on the top-left that slopes down into the body.
func folder() -> NSBezierPath {
    let x0: CGFloat = 200, x1: CGFloat = 824, y0: CGFloat = 262, y1: CGFloat = 702, yT: CGFloat = 762
    let r: CGFloat = 46, tabR: CGFloat = 36
    let tabTop: CGFloat = x0 + 220, tabFoot: CGFloat = x0 + 300   // where the tab slope starts / lands
    let p = NSBezierPath()
    p.move(to: CGPoint(x: x0 + r, y: y0))
    p.appendArc(from: CGPoint(x: x1, y: y0), to: CGPoint(x: x1, y: y1), radius: r)
    p.appendArc(from: CGPoint(x: x1, y: y1), to: CGPoint(x: tabFoot, y: y1), radius: r)
    p.line(to: CGPoint(x: tabFoot, y: y1))
    p.curve(to: CGPoint(x: tabTop, y: yT), controlPoint1: CGPoint(x: tabFoot - 40, y: y1), controlPoint2: CGPoint(x: tabTop + 40, y: yT))
    p.appendArc(from: CGPoint(x: x0, y: yT), to: CGPoint(x: x0, y: y0), radius: tabR)
    p.appendArc(from: CGPoint(x: x0, y: y0), to: CGPoint(x: x1, y: y0), radius: r)
    p.close()
    return p
}

layer("folder") {
    tileSpace { hex(0xF6F1E4).setFill(); folder().fill() }
}

layer("star") {
    tileSpace {
        let c = CGPoint(x: 512, y: 482)   // centre of the folder body
        let long: CGFloat = 196, short: CGFloat = 50
        for i in 0..<4 {
            let angle = CGFloat(i) * .pi / 2 + .pi / 2   // north first
            let tip = CGPoint(x: c.x + cos(angle) * long, y: c.y + sin(angle) * long)
            let l = CGPoint(x: c.x + cos(angle + .pi / 2) * short, y: c.y + sin(angle + .pi / 2) * short)
            let r = CGPoint(x: c.x + cos(angle - .pi / 2) * short, y: c.y + sin(angle - .pi / 2) * short)
            let left = NSBezierPath(); left.move(to: c); left.line(to: l); left.line(to: tip); left.close()
            let right = NSBezierPath(); right.move(to: c); right.line(to: tip); right.line(to: r); right.close()
            let north = i == 0
            (north ? hex(0xFF8A3D) : hex(0x1F6F6A)).setFill(); left.fill()
            (north ? hex(0xE8590C) : hex(0x0E4744)).setFill(); right.fill()
        }
        hex(0xF6F1E4).setFill(); circle(c, 18).fill()
    }
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
        { "image-name" : "folder.png", "name" : "folder" }
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
