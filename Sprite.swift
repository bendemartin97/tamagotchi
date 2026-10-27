import AppKit

enum Palette {
    static let body = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)
    static let bodyDark = NSColor(srgbRed: 0.72, green: 0.36, blue: 0.25, alpha: 1)
    static let bodyLight = NSColor(srgbRed: 0.93, green: 0.6, blue: 0.48, alpha: 1)
    static let ink = NSColor(srgbRed: 0.16, green: 0.1, blue: 0.08, alpha: 1)
    static let blush = NSColor(srgbRed: 0.98, green: 0.55, blue: 0.6, alpha: 1)
    static let alert = NSColor(srgbRed: 1.0, green: 0.78, blue: 0.2, alpha: 1)
    static let heart = NSColor(srgbRed: 0.95, green: 0.3, blue: 0.4, alpha: 1)
}

let spriteCols = 14
let spriteRows = 10

struct PetPose {
    var mood: Mood
    /// Ticks seit dem letzten Stimmungswechsel.
    var t: Int
    var tick: Int
    var petted = 0
    var hop = 0
    var walking = false
    var facing = 1
    var yawning = false
    var hungry = false
    var grumpy = false

    var lift: Int {
        if hop > 0 { return [1, 3, 5, 6, 5, 3][hop % 6] }
        if petted > 0 { return [0, 1, 2, 1][petted % 4] }
        switch mood {
        case .done: return [0, 1, 2, 3, 3, 2, 1, 0, 0, 0][t % 10]
        case .waiting: return [0, 2, 3, 2, 0, 0][t % 6]
        case .working: return (t / 2) % 2
        case .idle: return walking ? (tick / 2) % 2 : (t / 8) % 2
        case .sleeping: return 0
        }
    }
}

/// Zeichnet das Haustier in einer geflippten View; `origin` ist die linke obere Ecke im Ruhezustand.
func drawPet(_ pose: PetPose, at origin: NSPoint, px: CGFloat) {
    let mood = pose.mood, t = pose.t, tick = pose.tick
    let o = NSPoint(x: origin.x, y: origin.y - CGFloat(pose.lift) * px)
    func p(_ x: Int, _ y: Int, _ c: NSColor) {
        c.setFill()
        NSRect(x: o.x + CGFloat(x) * px, y: o.y + CGFloat(y) * px, width: px, height: px).fill()
    }
    func rect(_ x: ClosedRange<Int>, _ y: ClosedRange<Int>, _ c: NSColor) {
        for xx in x { for yy in y { p(xx, yy, c) } }
    }

    let trotting = mood == .working || pose.walking
    let step = trotting ? (tick / 2) % 2 : 0
    for (i, x) in [3, 5, 8, 10].enumerated() {
        let short = trotting && (i % 2 == step)
        rect(x...x, 8...(short ? 8 : 9), Palette.bodyDark)
    }
    rect(2...11, 0...7, Palette.body)
    rect(3...10, 0...0, Palette.bodyLight)
    rect(2...11, 7...7, Palette.bodyDark)

    let armsUp: Bool
    switch mood {
    case .done: armsUp = true
    case .waiting: armsUp = (t / 3) % 2 == 0
    default: armsUp = pose.petted > 0 || pose.hop > 0
    }
    if armsUp {
        rect(0...1, 1...2, Palette.body); rect(12...13, 1...2, Palette.body)
    } else {
        rect(0...1, 4...5, Palette.body); rect(12...13, 4...5, Palette.body)
    }

    let ink = Palette.ink
    let blink = mood != .sleeping && (tick % 47 == 0 || tick % 47 == 1)
    let happy = mood == .done || pose.petted > 0
    if pose.yawning {
        rect(3...4, 3...3, ink); rect(9...10, 3...3, ink)
        rect(6...7, 4...6, ink)
    } else if mood == .sleeping || blink {
        rect(3...4, 3...3, ink); rect(9...10, 3...3, ink)
    } else if happy {
        p(3, 3, ink); p(4, 2, ink); p(5, 3, ink)
        p(8, 3, ink); p(9, 2, ink); p(10, 3, ink)
        p(3, 5, Palette.blush); p(10, 5, Palette.blush)
        rect(6...7, 5...5, ink)
    } else if mood == .waiting {
        rect(4...4, 1...3, ink); rect(9...9, 1...3, ink)
        rect(6...7, 5...5, ink)
    } else {
        let look = pose.walking ? pose.facing : mood == .working ? ((t / 15) % 2 == 0 ? -1 : 1) : ((tick / 60) % 3 == 1 ? 1 : 0)
        rect((4 + look)...(4 + look), 2...3, ink); rect((9 + look)...(9 + look), 2...3, ink)
        if pose.grumpy || pose.hungry { p(5, 6, ink); rect(6...7, 5...5, ink); p(8, 6, ink) }
    }

    switch mood {
    case .waiting:
        if (t / 4) % 2 == 0 { rect(13...13, -5 ... -3, Palette.alert); p(13, -1, Palette.alert) }
    case .done:
        drawHeart(at: NSPoint(x: o.x + 12 * px, y: o.y + CGFloat(-2 - (t % 10) / 3) * px), px: px)
    case .working:
        for i in 0..<3 where (t / 3) % 4 > i { p(5 + i * 2, -2, ink.withAlphaComponent(0.6)) }
    case .sleeping:
        let phase = (tick / 6) % 3
        for i in 0...phase {
            drawGlyph("z", at: NSPoint(x: o.x + CGFloat(11 + i * 2) * px, y: o.y - CGFloat(2 + i * 3) * px),
                      size: px * CGFloat(2.2 + Double(i) * 0.6), color: NSColor(srgbRed: 0.45, green: 0.55, blue: 0.85, alpha: 0.9))
        }
    case .idle:
        if pose.hungry && !pose.walking && (tick / 10) % 4 != 0 {
            drawGlyph("🍔", at: NSPoint(x: o.x + 12 * px, y: o.y - 5 * px), size: px * 2.6, color: .black)
        }
    }
    if pose.petted > 0 {
        drawHeart(at: NSPoint(x: o.x + 1 * px, y: o.y - CGFloat(3 + (20 - pose.petted) / 4) * px), px: px)
    }
}

func drawHeart(at pt: NSPoint, px: CGFloat) {
    let s = px * 0.6
    Palette.heart.setFill()
    for (x, y) in [(0, 0), (1, 0), (3, 0), (4, 0), (0, 1), (1, 1), (2, 1), (3, 1), (4, 1), (1, 2), (2, 2), (3, 2), (2, 3)] {
        NSRect(x: pt.x + CGFloat(x) * s, y: pt.y + CGFloat(y) * s, width: s, height: s).fill()
    }
}

func drawGlyph(_ s: String, at pt: NSPoint, size: CGFloat, color: NSColor) {
    (s as NSString).draw(at: pt, withAttributes: [
        .font: NSFont.monospacedSystemFont(ofSize: size, weight: .bold),
        .foregroundColor: color,
    ])
}

func drawShadow(centerX: CGFloat, y: CGFloat, width: CGFloat, lift: Int) {
    let w = width * max(0.4, 1 - CGFloat(lift) * 0.08)
    NSColor.black.withAlphaComponent(0.18).setFill()
    NSBezierPath(ovalIn: NSRect(x: centerX - w / 2, y: y, width: w, height: width / 12)).fill()
}

/// Sprechblase mit Spitze nach unten, deren Unterkante bei `bottom` liegt (geflippte View).
func drawBubble(in bounds: NSRect, bottom: CGFloat, title: String?, body: String, accent: NSColor) {
    let text = NSMutableAttributedString(string: title.map { $0 + "\n" } ?? "", attributes: [
        .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
        .foregroundColor: NSColor(srgbRed: 0.15, green: 0.12, blue: 0.1, alpha: 1),
    ])
    text.append(NSAttributedString(string: body, attributes: [
        .font: NSFont.systemFont(ofSize: 11.5),
        .foregroundColor: NSColor(srgbRed: 0.3, green: 0.26, blue: 0.23, alpha: 1),
    ]))
    let maxW = bounds.width - 24
    let size = text.boundingRect(with: NSSize(width: maxW, height: 600),
                                 options: [.usesLineFragmentOrigin, .usesFontLeading]).size
    let w = min(maxW, ceil(size.width)) + 20
    let h = min(ceil(size.height) + 14, bottom - 4)
    let r = NSRect(x: (bounds.width - w) / 2, y: bottom - h, width: w, height: h)

    let path = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
    let tail = NSBezierPath()
    tail.move(to: NSPoint(x: bounds.midX - 7, y: r.maxY - 1))
    tail.line(to: NSPoint(x: bounds.midX, y: r.maxY + 8))
    tail.line(to: NSPoint(x: bounds.midX + 7, y: r.maxY - 1))
    tail.close()

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowBlurRadius = 6
    shadow.shadowOffset = NSSize(width: 0, height: -2)
    shadow.set()
    NSColor(srgbRed: 1, green: 0.98, blue: 0.95, alpha: 0.97).setFill()
    path.fill()
    tail.fill()
    NSGraphicsContext.restoreGraphicsState()
    accent.withAlphaComponent(0.8).setStroke()
    path.lineWidth = 1.5
    path.stroke()

    text.draw(with: r.insetBy(dx: 10, dy: 7), options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine])
}
