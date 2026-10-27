import AppKit

/// Kleines Haustier für eine einzelne Agent-Session; läuft dem großen hinterher.
final class MiniPetView: NSView {
    let store: Store
    let sessionID: String
    var tick = 0
    var moodSince = 0
    var lastMood: Mood = .working
    var walking = false
    var facing = 1
    /// Gezeichnete Beschriftungen; nur sie und das Haustier selbst fangen Klicks.
    var tags: [NSRect] = []

    let px: CGFloat = 3

    init(store: Store, sessionID: String, frame: NSRect) {
        self.store = store
        self.sessionID = sessionID
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    var petOrigin: NSPoint {
        NSPoint(x: (bounds.width - CGFloat(spriteCols) * px) / 2, y: bounds.height - CGFloat(spriteRows) * px - 6)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let s = store.sessions[sessionID] else { return }
        if s.mood != lastMood { lastMood = s.mood; moodSince = tick }
        let pose = PetPose(mood: s.mood, t: tick - moodSince, tick: tick, walking: walking, facing: facing)
        drawShadow(centerX: bounds.midX, y: bounds.height - 7, width: CGFloat(spriteCols) * px, lift: pose.lift)
        drawPet(pose, at: petOrigin, px: px)

        let label = s.label.count > 16 ? s.label.prefix(15) + "…" : s.label
        let name = NSMutableAttributedString(string: store.name(for: s.id), attributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .bold),
            .foregroundColor: NSColor.white,
        ])
        name.append(NSAttributedString(string: " · " + label, attributes: [
            .font: NSFont.systemFont(ofSize: 8, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.75),
        ]))
        let nameSize = name.size()
        let nameTag = NSRect(x: (bounds.width - nameSize.width) / 2 - 4, y: petOrigin.y - nameSize.height - 5,
                             width: nameSize.width + 8, height: nameSize.height + 2)
        NSColor.black.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: nameTag, xRadius: 4, yRadius: 4).fill()
        name.draw(at: NSPoint(x: nameTag.minX + 4, y: nameTag.minY + 1))
        tags = [nameTag]

        guard !s.heading.isEmpty else { return }
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byWordWrapping
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: para,
        ]
        let maxWidth = bounds.width - 10
        let lineHeight = NSFont.systemFont(ofSize: 9, weight: .semibold).boundingRectForFont.height
        var fit = (s.heading as NSString).boundingRect(with: NSSize(width: maxWidth, height: 1000),
                                                      options: .usesLineFragmentOrigin, attributes: titleAttrs).size
        fit.height = min(ceil(fit.height), ceil(lineHeight * 2))
        let titleTag = NSRect(x: (bounds.width - fit.width) / 2 - 4, y: nameTag.minY - fit.height - 4,
                              width: ceil(fit.width) + 8, height: fit.height + 2)
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: titleTag, xRadius: 5, yRadius: 5).fill()
        (s.heading as NSString).draw(with: titleTag.insetBy(dx: 4, dy: 1), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                   attributes: titleAttrs)
        tags.append(titleTag)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return local.y > petOrigin.y - 2 || tags.contains { $0.contains(local) } ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseUp(with event: NSEvent) {
        guard let s = store.sessions[sessionID] else { return }
        performClick(s.click)
        if s.mood != .working { store.ack(s.id) }
    }
}

/// Hält für jede Agent-Session ein Mini-Fenster und lässt sie im Gänsemarsch hinter dem großen laufen.
final class Followers {
    let store: Store
    private var panels: [String: (NSPanel, MiniPetView)] = [:]
    let size = NSSize(width: 120, height: 84)

    init(store: Store) { self.store = store }

    func update(leader: NSWindow, leaderView: PetView) {
        let agents = store.agents
        let ids = Set(agents.map(\.id))
        for (id, (panel, _)) in panels where !ids.contains(id) {
            panel.orderOut(nil)
            panels[id] = nil
        }
        let feet = leader.frame.minY + 10 - 6
        let leaderPoint = NSPoint(x: leader.frame.midX, y: leader.frame.minY + 20)
        let leaderScreen = NSScreen.screens.first { $0.frame.contains(leaderPoint) }?.visibleFrame
        for (i, s) in agents.enumerated() {
            let (panel, view) = panels[s.id] ?? make(s.id, at: NSPoint(x: leader.frame.midX - size.width / 2, y: feet))
            let gap = CGFloat(i) * 124 + 90
            var target = NSPoint(x: leader.frame.midX - CGFloat(leaderView.facing) * gap - size.width / 2, y: feet)
            if let vf = leaderScreen {
                target.x = min(max(target.x, vf.minX), vf.maxX - size.width)
                target.y = min(max(target.y, vf.minY), vf.maxY - size.height)
            }
            let dx = target.x - panel.frame.minX, dy = target.y - panel.frame.minY
            var next = panel.frame.origin
            // Bei getrennten Spaces kommen Fenster nicht über die Displaygrenze: dann direkt hinüberspringen.
            if hypot(dx, dy) > 600 || screenIndex(of: panel.frame) != screenIndex(of: NSRect(origin: target, size: size)) {
                next = target
            } else {
                next.x += max(-3.5, min(3.5, dx))
                next.y += max(-8, min(8, dy))
            }
            view.walking = hypot(dx, dy) > 1.5
            if abs(dx) > 1.5 { view.facing = dx > 0 ? 1 : -1 }
            if next != panel.frame.origin { panel.setFrameOrigin(next) }
            view.tick += 1
            view.needsDisplay = true
        }
    }

    private func screenIndex(of r: NSRect) -> Int? {
        let pt = NSPoint(x: r.midX, y: r.minY + 10)
        return NSScreen.screens.firstIndex { $0.frame.contains(pt) }
    }

    private func make(_ id: String, at origin: NSPoint) -> (NSPanel, MiniPetView) {
        let panel = NSPanel(contentRect: NSRect(origin: origin, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        let view = MiniPetView(store: store, sessionID: id, frame: NSRect(origin: .zero, size: size))
        panel.contentView = view
        panel.orderFrontRegardless()
        panels[id] = (panel, view)
        return (panel, view)
    }
}
