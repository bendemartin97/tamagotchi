import AppKit
// Usage: cp tools/squircle.swift /tmp/main.swift && swiftc /tmp/main.swift -o /tmp/squircle && /tmp/squircle source.png target.png X Y SIZE
// (X, Y, SIZE = squircle in the source image, in pixels), then tools/icon.sh target.png.
// Cuts the squircle out of the generated image and places it with transparent corners into the macOS grid (824 within 1024).
let a = CommandLine.arguments
let src = NSImage(contentsOfFile: a[1])!
let rep = src.representations.first!
let crop = NSRect(x: Double(a[3])!, y: Double(a[4])!, width: Double(a[5])!, height: Double(a[5])!)
let px = CGFloat(rep.pixelsWide)
let out = NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { _ in
    let target = NSRect(x: 100, y: 100, width: 824, height: 824)
    NSBezierPath(roundedRect: target, xRadius: 185, yRadius: 185).addClip()
    // Source in points, y from the bottom
    let from = NSRect(x: crop.minX * src.size.width / px, y: (px - crop.maxY) * src.size.height / px,
                      width: crop.width * src.size.width / px, height: crop.height * src.size.height / px)
    src.draw(in: target, from: from, operation: .copy, fraction: 1)
    return true
}
let bmp = NSBitmapImageRep(data: out.tiffRepresentation!)!
try! bmp.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
