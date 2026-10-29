// Rendert das Haustier als 1024er-App-Icon (Platzhalter, bis es ein gezeichnetes gibt).
// Aufruf über tools/icon.sh, das diese Datei zusammen mit Sprite.swift kompiliert.
import AppKit

enum Mood: String, Codable { case idle, sleeping, working, done, waiting }
let petNames: [String] = []

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { r in
    let bg = NSBezierPath(roundedRect: r.insetBy(dx: 100, dy: 100), xRadius: 185, yRadius: 185)
    NSGradient(starting: NSColor(srgbRed: 0.16, green: 0.13, blue: 0.22, alpha: 1),
               ending: NSColor(srgbRed: 0.33, green: 0.22, blue: 0.38, alpha: 1))!.draw(in: bg, angle: 90)
    let px: CGFloat = 46
    let w = CGFloat(spriteCols) * px, h = CGFloat(spriteRows) * px
    drawShadow(centerX: size / 2 - 50, y: (size + h) / 2 + 40, width: w, lift: 0)
    drawPet(PetPose(mood: .done, t: 0, tick: 5), at: NSPoint(x: (size - w) / 2 - 50, y: (size - h) / 2 + 60), px: px)
    return true
}
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
