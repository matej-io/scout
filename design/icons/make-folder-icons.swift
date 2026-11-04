// Renders the Folder Compass variants of Scout's icon: the Compass design with the cream dial
// replaced by a folder silhouette — one with the star upright, one tilted 20°.
// Usage: swift make-folder-icons.swift <output-dir>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let S: CGFloat = 1024
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let C = CGPoint(x: 512, y: 512)

// MARK: helpers

func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: a)
}

/// Apple-style continuous-corner tile (superellipse).
func squircle(_ r: CGRect, n: CGFloat = 5) -> NSBezierPath {
    let p = NSBezierPath()
    let a = r.width / 2, b = r.height / 2, c = CGPoint(x: r.midX, y: r.midY)
    for i in 0...360 {
        let t = CGFloat(i) * .pi / 180
        let ct = cos(t), st = sin(t)
        let x = c.x + a * (ct < 0 ? -1 : 1) * pow(abs(ct), 2 / n)
        let y = c.y + b * (st < 0 ? -1 : 1) * pow(abs(st), 2 / n)
        i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.line(to: CGPoint(x: x, y: y))
    }
    p.close()
    return p
}

func gradient(_ path: NSBezierPath, _ top: NSColor, _ bottom: NSColor, angle: CGFloat = -90) {
    NSGradient(starting: top, ending: bottom)!.draw(in: path, angle: angle)
}

func shadowed(_ color: NSColor = .black, alpha: CGFloat = 0.25, blur: CGFloat = 20, y: CGFloat = -8, _ body: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let s = NSShadow()
    s.shadowColor = color.withAlphaComponent(alpha)
    s.shadowBlurRadius = blur
    s.shadowOffset = NSSize(width: 0, height: y)
    s.set()
    body()
    NSGraphicsContext.restoreGraphicsState()
}

func circle(_ c: CGPoint, _ r: CGFloat) -> NSBezierPath {
    NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
}

/// Draws the tile background with a soft top highlight; `body` draws the artwork clipped to the tile.
func icon(_ name: String, top: NSColor, bottom: NSColor, _ body: (NSBezierPath) -> Void) -> NSImage {
    let image = NSImage(size: NSSize(width: S, height: S))
    image.lockFocus()
    let shape = squircle(tile)
    shadowed(alpha: 0.30, blur: 28, y: -12) { top.setFill(); shape.fill() }
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    gradient(shape, top, bottom)
    body(shape)
    // Gentle sheen at the top edge.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.18), NSColor.white.withAlphaComponent(0)])!
        .draw(in: CGRect(x: tile.minX, y: tile.midY + 120, width: tile.width, height: tile.height / 2 - 120), angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    // Fine inner edge.
    NSColor.white.withAlphaComponent(0.14).setStroke()
    let edge = squircle(tile.insetBy(dx: 1.5, dy: 1.5))
    edge.lineWidth = 3
    edge.stroke()
    image.unlockFocus()
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("\(name).png"))
    return image
}

// MARK: shapes

/// Four-point compass star centred at c.
func compassStar(_ c: CGPoint, long: CGFloat, short: CGFloat) -> [NSBezierPath] {
    var arms: [NSBezierPath] = []
    for i in 0..<4 {
        let angle = CGFloat(i) * .pi / 2 + .pi / 2   // north first
        let tip = CGPoint(x: c.x + cos(angle) * long, y: c.y + sin(angle) * long)
        let l = CGPoint(x: c.x + cos(angle + .pi / 2) * short, y: c.y + sin(angle + .pi / 2) * short)
        let r = CGPoint(x: c.x + cos(angle - .pi / 2) * short, y: c.y + sin(angle - .pi / 2) * short)
        // Each arm in two halves for the classic light/dark facet look.
        let left = NSBezierPath(); left.move(to: c); left.line(to: l); left.line(to: tip); left.close()
        let right = NSBezierPath(); right.move(to: c); right.line(to: tip); right.line(to: r); right.close()
        arms += [left, right]
    }
    return arms
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

func star(_ c: CGPoint, long: CGFloat, short: CGFloat, tilt: CGFloat) {
    NSGraphicsContext.saveGraphicsState()
    let t = NSAffineTransform()
    t.translateX(by: c.x, yBy: c.y); t.rotate(byDegrees: -tilt); t.translateX(by: -c.x, yBy: -c.y)
    t.concat()
    for (i, arm) in compassStar(c, long: long, short: short).enumerated() {
        let north = i < 2
        let color: NSColor = north ? (i % 2 == 0 ? hex(0xFF8A3D) : hex(0xE8590C)) : (i % 2 == 0 ? hex(0x1F6F6A) : hex(0x0E4744))
        color.setFill(); arm.fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    hex(0xF6F1E4).setFill(); circle(c, 18).fill()
}

for (name, tilt) in [("7-folder-compass", CGFloat(0)), ("8-folder-compass-tilted", CGFloat(20))] {
    _ = icon(name, top: hex(0x14A39A), bottom: hex(0x0B5E5A)) { _ in
        let shape = folder()
        shadowed(alpha: 0.30, blur: 22, y: -10) { hex(0xF6F1E4).setFill(); shape.fill() }
        star(CGPoint(x: 512, y: 482), long: 196, short: 50, tilt: tilt)
    }
}
print("ok")
