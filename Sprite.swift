import AppKit

enum Palette {
    static let body = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)
    static let bodyDark = NSColor(srgbRed: 0.72, green: 0.36, blue: 0.25, alpha: 1)
    static let bodyLight = NSColor(srgbRed: 0.93, green: 0.6, blue: 0.48, alpha: 1)
    static let ink = NSColor(srgbRed: 0.16, green: 0.1, blue: 0.08, alpha: 1)
    static let blush = NSColor(srgbRed: 0.98, green: 0.55, blue: 0.6, alpha: 1)
    static let alert = NSColor(srgbRed: 1.0, green: 0.78, blue: 0.2, alpha: 1)
    static let heart = NSColor(srgbRed: 0.95, green: 0.3, blue: 0.4, alpha: 1)
    static let check = NSColor(srgbRed: 0.3, green: 0.72, blue: 0.4, alpha: 1)
    static let paper = NSColor(srgbRed: 0.98, green: 0.96, blue: 0.9, alpha: 1)
    static let confetti = [heart, alert, check, NSColor(srgbRed: 0.35, green: 0.6, blue: 0.95, alpha: 1)]
}

/// Pet appearance: fur color and an accessory. The big one stays orange with no accessory; each agent
/// gets a fixed one of its own from its nickname, so the mini, speech bubble and overview match.
struct Look {
    enum Accessory: CaseIterable { case none, cap, beanie, glasses, bow, antenna, headphones, scarf }

    var body = Palette.body
    var dark = Palette.bodyDark
    var light = Palette.bodyLight
    var accessory = Accessory.none
    var trim = Palette.confetti[3]

    static let standard = Look()
    private static let hues: [CGFloat] = [0.0, 0.14, 0.3, 0.46, 0.58, 0.68, 0.78, 0.88, 0.96, 0.11]

    /// Via the index in petNames: no two nicknames share a color and accessory.
    static func agent(_ name: String) -> Look {
        let hash = Int(name.utf8.reduce(UInt32(5381)) { ($0 &<< 5) &+ $0 &+ UInt32($1) } % 1000)
        let i: Int = petNames.firstIndex(of: name) ?? hash
        let hue = hues[i % hues.count]
        let trimHue = (hue + 0.5).truncatingRemainder(dividingBy: 1)
        return Look(body: NSColor(hue: hue, saturation: 0.5, brightness: 0.86, alpha: 1),
                    dark: NSColor(hue: hue, saturation: 0.62, brightness: 0.66, alpha: 1),
                    light: NSColor(hue: hue, saturation: 0.32, brightness: 0.95, alpha: 1),
                    accessory: Accessory.allCases[(i + i / hues.count) % Accessory.allCases.count],
                    trim: NSColor(hue: trimHue, saturation: 0.7, brightness: 0.8, alpha: 1))
    }
}

/// What the pet is currently holding or doing, derived from the actual work state.
enum Prop {
    case none
    /// Letter: follow-up question for Martin.
    case letter
    /// Hourglass: pipeline is running.
    case hourglass
    /// Eyes: change is waiting for visual review.
    case eyes
    /// Confetti and party hat: task truly done (approved, merged).
    case party
}

let spriteCols = 14
let spriteRows = 10

struct PetPose {
    var mood: Mood
    /// Ticks since the last mood change.
    var t: Int
    var tick: Int
    var petted = 0
    var hop = 0
    var walking = false
    var facing = 1
    var yawning = false
    var hungry = false
    var grumpy = false
    var prop = Prop.none
    var look = Look.standard

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

/// Draws the pet in a flipped view; `origin` is the top-left corner at rest.
func drawPet(_ pose: PetPose, at origin: NSPoint, px: CGFloat) {
    let mood = pose.mood, t = pose.t, tick = pose.tick, look = pose.look
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
        rect(x...x, 8...(short ? 8 : 9), look.dark)
    }
    rect(2...11, 0...7, look.body)
    rect(3...10, 0...0, look.light)
    rect(2...11, 7...7, look.dark)

    let armsUp: Bool
    switch mood {
    case _ where pose.prop == .party: armsUp = (tick / 4) % 2 == 0
    case _ where pose.prop == .letter: armsUp = false
    case .done: armsUp = false
    case .waiting: armsUp = (t / 3) % 2 == 0
    default: armsUp = pose.petted > 0 || pose.hop > 0
    }
    if armsUp {
        rect(0...1, 1...2, look.body); rect(12...13, 1...2, look.body)
    } else {
        rect(0...1, 4...5, look.body); rect(12...13, 4...5, look.body)
    }

    let ink = Palette.ink
    let blink = mood != .sleeping && (tick % 47 == 0 || tick % 47 == 1)
    let happy = mood == .done || pose.petted > 0 || pose.prop == .party
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

    drawAccessory(look, party: pose.prop == .party, p: p, rect: rect)

    switch mood {
    case .waiting:
        if (t / 4) % 2 == 0 { rect(13...13, -5 ... -3, Palette.alert); p(13, -1, Palette.alert) }
    case .done:
        // Just a checkmark: the answer is in, but that doesn't mean the task is done (that would be .party).
        for (x, y) in [(11, -2), (12, -1), (13, -2), (14, -3), (15, -4)] { p(x, y, Palette.check) }
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
    drawProp(pose, p: p, rect: rect, o: o, px: px)
    if pose.petted > 0 {
        drawHeart(at: NSPoint(x: o.x + 1 * px, y: o.y - CGFloat(3 + (20 - pose.petted) / 4) * px), px: px)
    }
}

private func drawAccessory(_ look: Look, party: Bool, p: (Int, Int, NSColor) -> Void,
                           rect: (ClosedRange<Int>, ClosedRange<Int>, NSColor) -> Void) {
    let c = look.trim, ink = Palette.ink
    switch look.accessory {
    case .none: break
    case .cap where !party: rect(3...10, -1 ... -1, c); rect(2...12, 0...0, c)
    case .beanie where !party: rect(3...10, -1...0, c); rect(2...11, 0...0, c.blended(withFraction: 0.3, of: .white) ?? c); p(6, -2, .white)
    case .glasses: rect(2...5, 1...1, ink); rect(8...11, 1...1, ink); rect(6...7, 2...2, ink); p(2, 2, ink); p(11, 2, ink)
    case .bow: p(9, -1, c); p(9, 0, c); p(10, 0, ink); p(11, -1, c); p(11, 0, c)
    case .antenna: p(3, -1, ink); p(3, -2, ink); p(3, -3, c)
    case .headphones: rect(3...10, -1 ... -1, ink); rect(1...1, 1...3, c); rect(12...12, 1...3, c)
    case .scarf: rect(2...11, 6...6, c); p(10, 7, c); p(10, 8, c)
    default: break
    }
}

/// Pet as an image for the overview.
func petImage(_ pose: PetPose, px: CGFloat) -> NSImage {
    let pad: CGFloat = 6 * px
    let size = NSSize(width: CGFloat(spriteCols + 4) * px, height: CGFloat(spriteRows) * px + pad + px)
    return NSImage(size: size, flipped: true) { _ in
        drawPet(pose, at: NSPoint(x: 1 * px, y: pad), px: px)
        return true
    }
}

private func drawProp(_ pose: PetPose, p: (Int, Int, NSColor) -> Void, rect: (ClosedRange<Int>, ClosedRange<Int>, NSColor) -> Void,
                      o: NSPoint, px: CGFloat) {
    let ink = Palette.ink, tick = pose.tick
    switch pose.prop {
    case .none:
        break
    case .letter:
        let bob = (tick / 6) % 2
        rect(12...16, (4 + bob)...(7 + bob), Palette.paper)
        p(12, 4 + bob, ink); p(13, 5 + bob, ink); p(14, 6 + bob, ink); p(15, 5 + bob, ink); p(16, 4 + bob, ink)
        p(14, 5 + bob, Palette.heart)
    case .hourglass:
        let flipped = (tick / 25) % 2 == 1
        rect(12...16, -5 ... -5, ink); rect(12...16, 1...1, ink)
        rect(13...15, -4 ... -3, flipped ? Palette.paper : Palette.alert)
        p(14, -2, Palette.alert)
        rect(13...15, -1...0, flipped ? Palette.alert : Palette.paper)
    case .eyes:
        drawGlyph("👀", at: NSPoint(x: o.x + 11 * px, y: o.y - 5 * px), size: px * 2.8, color: .black)
    case .party:
        rect(6...7, -3 ... -1, Palette.alert); p(6, -4, Palette.heart); p(7, -4, Palette.heart); rect(5...8, -1 ... -1, Palette.confetti[3])
        for i in 0..<8 {
            let x = (i * 5 + tick / 2) % 18 - 2
            let y = (i * 7 + tick) % 14 - 6
            p(x, y, Palette.confetti[i % Palette.confetti.count])
        }
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

/// Speech bubble with the tip pointing down, whose bottom edge sits at `bottom` (flipped view).
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
