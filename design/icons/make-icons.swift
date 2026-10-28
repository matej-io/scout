// Renders Scout app icon variants (1024×1024 PNGs) plus a contact sheet.
// Usage: swift make-icons.swift <output-dir>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let S: CGFloat = 1024
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)

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

/// Fleur-de-lis (the scout emblem, originally the north mark on compass roses), in a unit box centred at origin.
func fleurDeLis() -> NSBezierPath {
    let p = NSBezierPath()
    // centre petal
    p.move(to: CGPoint(x: 0, y: 1.0))
    p.curve(to: CGPoint(x: 0.17, y: 0.36), controlPoint1: CGPoint(x: 0.07, y: 0.86), controlPoint2: CGPoint(x: 0.22, y: 0.58))
    p.curve(to: CGPoint(x: 0.07, y: 0.06), controlPoint1: CGPoint(x: 0.14, y: 0.20), controlPoint2: CGPoint(x: 0.09, y: 0.12))
    p.line(to: CGPoint(x: -0.07, y: 0.06))
    p.curve(to: CGPoint(x: -0.17, y: 0.36), controlPoint1: CGPoint(x: -0.09, y: 0.12), controlPoint2: CGPoint(x: -0.14, y: 0.20))
    p.curve(to: CGPoint(x: 0, y: 1.0), controlPoint1: CGPoint(x: -0.22, y: 0.58), controlPoint2: CGPoint(x: -0.07, y: 0.86))
    p.close()
    for s: CGFloat in [1, -1] {
        // side petals curling outwards and down
        p.move(to: CGPoint(x: 0.09 * s, y: 0.10))
        p.curve(to: CGPoint(x: 0.44 * s, y: 0.66), controlPoint1: CGPoint(x: 0.20 * s, y: 0.52), controlPoint2: CGPoint(x: 0.28 * s, y: 0.70))
        p.curve(to: CGPoint(x: 0.36 * s, y: 0.30), controlPoint1: CGPoint(x: 0.58 * s, y: 0.62), controlPoint2: CGPoint(x: 0.56 * s, y: 0.36))
        p.curve(to: CGPoint(x: 0.25 * s, y: 0.40), controlPoint1: CGPoint(x: 0.30 * s, y: 0.30), controlPoint2: CGPoint(x: 0.25 * s, y: 0.34))
        p.curve(to: CGPoint(x: 0.12 * s, y: 0.04), controlPoint1: CGPoint(x: 0.25 * s, y: 0.22), controlPoint2: CGPoint(x: 0.18 * s, y: 0.10))
        p.close()
        // lower curls
        p.move(to: CGPoint(x: 0.05 * s, y: -0.07))
        p.curve(to: CGPoint(x: 0.30 * s, y: -0.24), controlPoint1: CGPoint(x: 0.18 * s, y: -0.07), controlPoint2: CGPoint(x: 0.32 * s, y: -0.10))
        p.curve(to: CGPoint(x: 0.04 * s, y: -0.17), controlPoint1: CGPoint(x: 0.24 * s, y: -0.34), controlPoint2: CGPoint(x: 0.10 * s, y: -0.24))
        p.close()
    }
    // band
    p.append(NSBezierPath(roundedRect: CGRect(x: -0.24, y: -0.07, width: 0.48, height: 0.12), xRadius: 0.04, yRadius: 0.04))
    // centre stem
    p.move(to: CGPoint(x: -0.06, y: -0.06)); p.line(to: CGPoint(x: 0, y: -0.32)); p.line(to: CGPoint(x: 0.06, y: -0.06)); p.close()
    return p
}

func transformed(_ path: NSBezierPath, scale: CGFloat, to c: CGPoint, rotate: CGFloat = 0) -> NSBezierPath {
    let p = path.copy() as! NSBezierPath
    var t = AffineTransform.identity
    t.translate(x: c.x, y: c.y)
    t.rotate(byRadians: rotate)
    t.scale(scale)
    p.transform(using: t)
    return p
}

let C = CGPoint(x: S / 2, y: S / 2)
var made: [(String, String, NSImage)] = []

// 1. Trail Face — a nod to Finder's two-tone face, but the profile line is a trail
//    and the eyes are binocular lenses. Forest greens.
made.append(("1-trail-face", "Trail Face", icon("1-trail-face", top: hex(0x2FA36B), bottom: hex(0x15704A)) { _ in
    let left = NSBezierPath()
    left.move(to: CGPoint(x: 0, y: 0))
    left.line(to: CGPoint(x: 0, y: S))
    left.line(to: CGPoint(x: 492, y: S))
    left.curve(to: CGPoint(x: 470, y: 600), controlPoint1: CGPoint(x: 500, y: 800), controlPoint2: CGPoint(x: 430, y: 700))
    left.curve(to: CGPoint(x: 540, y: 430), controlPoint1: CGPoint(x: 505, y: 520), controlPoint2: CGPoint(x: 560, y: 500))
    left.curve(to: CGPoint(x: 500, y: 0), controlPoint1: CGPoint(x: 515, y: 300), controlPoint2: CGPoint(x: 470, y: 180))
    left.close()
    gradient(left, hex(0xC9F2D6), hex(0x8ED9AE))
    // binocular eyes
    for x: CGFloat in [370, 654] {
        let eye = circle(CGPoint(x: x, y: 600), 62)
        shadowed(alpha: 0.25, blur: 8, y: -3) { hex(0x153B2A).setFill(); eye.fill() }
        hex(0x2E5E47).setFill(); circle(CGPoint(x: x, y: 600), 38).fill()
        NSColor.white.withAlphaComponent(0.85).setFill(); circle(CGPoint(x: x - 18, y: 620), 13).fill()
    }
    hex(0x153B2A).setFill()
    NSBezierPath(roundedRect: CGRect(x: 425, y: 588, width: 174, height: 26), xRadius: 13, yRadius: 13).fill()
    // smile
    let smile = NSBezierPath()
    smile.move(to: CGPoint(x: 330, y: 380))
    smile.curve(to: CGPoint(x: 700, y: 380), controlPoint1: CGPoint(x: 420, y: 270), controlPoint2: CGPoint(x: 610, y: 270))
    smile.lineWidth = 30
    smile.lineCapStyle = .round
    hex(0x153B2A).setStroke()
    smile.stroke()
}))

// 2. Compass — a clean four-point compass rose on deep teal; north in signal orange.
made.append(("2-compass", "Compass", icon("2-compass", top: hex(0x14A39A), bottom: hex(0x0B5E5A)) { _ in
    // dial
    shadowed(alpha: 0.30, blur: 22, y: -10) { hex(0xF6F1E4).setFill(); circle(C, 300).fill() }
    hex(0x0B5E5A, 0.18).setStroke()
    let ring = circle(C, 262); ring.lineWidth = 6; ring.stroke()
    for i in 0..<16 where i % 4 != 0 {
        let a = CGFloat(i) * .pi / 8
        let tick = NSBezierPath()
        tick.move(to: CGPoint(x: C.x + cos(a) * 262, y: C.y + sin(a) * 262))
        tick.line(to: CGPoint(x: C.x + cos(a) * 282, y: C.y + sin(a) * 282))
        tick.lineWidth = 8; tick.lineCapStyle = .round
        hex(0x0B5E5A, 0.35).setStroke(); tick.stroke()
    }
    let arms = compassStar(C, long: 250, short: 62)
    for (i, arm) in arms.enumerated() {
        let north = i < 2
        let color: NSColor = north ? (i % 2 == 0 ? hex(0xFF8A3D) : hex(0xE8590C)) : (i % 2 == 0 ? hex(0x1F6F6A) : hex(0x0E4744))
        color.setFill(); arm.fill()
    }
    hex(0xF6F1E4).setFill(); circle(C, 22).fill()
}))

// 3. Fleur Compass — the scout fleur-de-lis is the old north mark of the compass rose.
made.append(("3-fleur-compass", "Fleur Compass", icon("3-fleur-compass", top: hex(0x3E8E4E), bottom: hex(0x1F5130)) { _ in
    shadowed(alpha: 0.32, blur: 22, y: -10) { hex(0xF3EBD3).setFill(); circle(C, 310).fill() }
    hex(0x1F5130, 0.22).setStroke()
    let ring = circle(C, 276); ring.lineWidth = 7; ring.stroke()
    for i in 0..<4 {
        let a = CGFloat(i) * .pi / 2
        let tick = NSBezierPath()
        tick.move(to: CGPoint(x: C.x + cos(a) * 250, y: C.y + sin(a) * 250))
        tick.line(to: CGPoint(x: C.x + cos(a) * 276, y: C.y + sin(a) * 276))
        tick.lineWidth = 10; tick.lineCapStyle = .round
        hex(0x1F5130, 0.45).setStroke(); tick.stroke()
    }
    let fleur = transformed(fleurDeLis(), scale: 330, to: CGPoint(x: C.x, y: C.y - 70))
    shadowed(alpha: 0.25, blur: 8, y: -4) { hex(0xD9480F).setFill(); fleur.fill() }
}))

// 4. Signpost — two trail signs pointing left and right: two panes, two directions. Sunset amber.
made.append(("4-signpost", "Signpost", icon("4-signpost", top: hex(0xFFB347), bottom: hex(0xE8590C)) { _ in
    let wood = hex(0x6B3F1D)
    shadowed(alpha: 0.3, blur: 16, y: -8) {
        wood.setFill()
        NSBezierPath(roundedRect: CGRect(x: 482, y: 150, width: 60, height: 620), xRadius: 18, yRadius: 18).fill()
    }
    func board(y: CGFloat, pointsRight: Bool, color: NSColor) {
        let w: CGFloat = 400, h: CGFloat = 132
        let x: CGFloat = pointsRight ? 470 : 554 - w
        let p = NSBezierPath()
        if pointsRight {
            p.move(to: CGPoint(x: x, y: y)); p.line(to: CGPoint(x: x + w - 70, y: y))
            p.line(to: CGPoint(x: x + w, y: y + h / 2)); p.line(to: CGPoint(x: x + w - 70, y: y + h))
            p.line(to: CGPoint(x: x, y: y + h))
        } else {
            p.move(to: CGPoint(x: x + w, y: y)); p.line(to: CGPoint(x: x + 70, y: y))
            p.line(to: CGPoint(x: x, y: y + h / 2)); p.line(to: CGPoint(x: x + 70, y: y + h))
            p.line(to: CGPoint(x: x + w, y: y + h))
        }
        p.close()
        p.lineJoinStyle = .round
        shadowed(alpha: 0.3, blur: 14, y: -7) { color.setFill(); p.fill() }
        // wood grain lines
        hex(0x8A5A2B, 0.35).setStroke()
        for g in [0.35, 0.65] as [CGFloat] {
            let line = NSBezierPath()
            line.move(to: CGPoint(x: x + (pointsRight ? 30 : 90), y: y + h * g))
            line.line(to: CGPoint(x: x + w - (pointsRight ? 110 : 30), y: y + h * g))
            line.lineWidth = 7; line.lineCapStyle = .round; line.stroke()
        }
    }
    board(y: 560, pointsRight: true, color: hex(0xFFF1D6))
    board(y: 380, pointsRight: false, color: hex(0xF7DDB0))
    hex(0x5A3416).setFill()
    for y: CGFloat in [626, 446] { circle(CGPoint(x: 512, y: y), 11).fill() }
}))

// 5. Binoculars — a scout's field glasses, front view, on olive.
made.append(("5-binoculars", "Binoculars", icon("5-binoculars", top: hex(0x9AAE3C), bottom: hex(0x55691A)) { _ in
    let body = hex(0x2B2F1E)
    shadowed(alpha: 0.35, blur: 24, y: -12) {
        body.setFill()
        for x: CGFloat in [340, 684] {
            NSBezierPath(roundedRect: CGRect(x: x - 135, y: 300, width: 270, height: 360), xRadius: 90, yRadius: 90).fill()
        }
        NSBezierPath(roundedRect: CGRect(x: 420, y: 520, width: 184, height: 110), xRadius: 30, yRadius: 30).fill()
        NSBezierPath(roundedRect: CGRect(x: 470, y: 640, width: 84, height: 80), xRadius: 22, yRadius: 22).fill()
    }
    for x: CGFloat in [340, 684] {
        hex(0x44492F).setFill(); circle(CGPoint(x: x, y: 410), 118).fill()
        NSGradient(starting: hex(0x9BD3E8), ending: hex(0x2E6F8E))!.draw(in: circle(CGPoint(x: x, y: 410), 92), angle: -60)
        NSColor.white.withAlphaComponent(0.75).setFill()
        circle(CGPoint(x: x - 34, y: 448), 22).fill()
        NSColor.white.withAlphaComponent(0.35).setFill()
        circle(CGPoint(x: x + 30, y: 384), 10).fill()
    }
}))

// 6. Base Camp — a glowing tent under the stars, deep pine night (not blue).
made.append(("6-base-camp", "Base Camp", icon("6-base-camp", top: hex(0x1F4D3F), bottom: hex(0x0C2620)) { _ in
    NSColor.white.withAlphaComponent(0.85).setFill()
    for (x, y, r) in [(260.0, 760.0, 9.0), (380, 830, 6), (700, 800, 8), (790, 700, 5), (580, 860, 5), (230, 620, 5)] as [(CGFloat, CGFloat, CGFloat)] {
        circle(CGPoint(x: x, y: y), r).fill()
    }
    // ground
    hex(0x0A1F1A).setFill()
    NSBezierPath(rect: CGRect(x: 0, y: 0, width: S, height: 255)).fill()
    // tent
    let tent = NSBezierPath()
    tent.move(to: CGPoint(x: 180, y: 255)); tent.line(to: CGPoint(x: 512, y: 720)); tent.line(to: CGPoint(x: 844, y: 255)); tent.close()
    shadowed(hex(0xFFB020), alpha: 0.45, blur: 50, y: 0) { gradient(tent, hex(0xFFC14D), hex(0xF08C00)); }
    gradient(tent, hex(0xFFC14D), hex(0xF08C00))
    let shade = NSBezierPath()
    shade.move(to: CGPoint(x: 512, y: 720)); shade.line(to: CGPoint(x: 844, y: 255)); shade.line(to: CGPoint(x: 600, y: 255)); shade.close()
    hex(0xB35900, 0.35).setFill(); shade.fill()
    // door
    let door = NSBezierPath()
    door.move(to: CGPoint(x: 410, y: 255)); door.line(to: CGPoint(x: 512, y: 520)); door.line(to: CGPoint(x: 614, y: 255)); door.close()
    hex(0x4A2500).setFill(); door.fill()
    let glow = NSBezierPath()
    glow.move(to: CGPoint(x: 455, y: 255)); glow.line(to: CGPoint(x: 512, y: 410)); glow.line(to: CGPoint(x: 569, y: 255)); glow.close()
    hex(0xFFE08A).setFill(); glow.fill()
    // flag
    hex(0x4A2500).setStroke()
    let pole = NSBezierPath(); pole.move(to: CGPoint(x: 512, y: 718)); pole.line(to: CGPoint(x: 512, y: 800)); pole.lineWidth = 10; pole.stroke()
    let flag = NSBezierPath(); flag.move(to: CGPoint(x: 517, y: 800)); flag.line(to: CGPoint(x: 600, y: 778)); flag.line(to: CGPoint(x: 517, y: 756)); flag.close()
    hex(0xFF6B6B).setFill(); flag.fill()
}))

// MARK: contact sheet: large previews + a Dock strip on light and dark backgrounds

let cols = made.count
let cell: CGFloat = 300
let sheet = NSImage(size: NSSize(width: CGFloat(cols) * cell, height: 560))
sheet.lockFocus()
NSColor(white: 0.97, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: sheet.size.width, height: 560).fill()
let labelAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 18, weight: .semibold), .foregroundColor: NSColor(white: 0.15, alpha: 1)]
for (i, (_, title, img)) in made.enumerated() {
    let x = CGFloat(i) * cell
    img.draw(in: NSRect(x: x + 22, y: 290, width: 256, height: 256))
    let label = "\(i + 1). \(title)" as NSString
    let size = label.size(withAttributes: labelAttrs)
    label.draw(at: NSPoint(x: x + (cell - size.width) / 2, y: 262), withAttributes: labelAttrs)
}
// Dock strips
for (row, dark) in [(1, false), (0, true)] {
    let y = CGFloat(row) * 120
    (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.86, alpha: 1)).setFill()
    NSRect(x: 0, y: y, width: sheet.size.width, height: 120).fill()
    for (i, (_, _, img)) in made.enumerated() {
        let x = CGFloat(i) * cell
        img.draw(in: NSRect(x: x + 60, y: y + 28, width: 64, height: 64))   // Dock size
        img.draw(in: NSRect(x: x + 150, y: y + 44, width: 32, height: 32))  // small
        img.draw(in: NSRect(x: x + 205, y: y + 52, width: 16, height: 16))  // tiny
    }
}
sheet.unlockFocus()
let rep = NSBitmapImageRep(data: sheet.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("contact-sheet.png"))
print("ok")
