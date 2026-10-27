import AppKit

/// Das große Haustier: Sammelstatus, Sprechblase, Chat, Herumlaufen.
final class PetView: NSView, NSTextFieldDelegate {
    let store: Store
    let buddy: Buddy
    let vitals: Vitals
    let tasks: TaskRunner
    var gitlab: GitLabWatch?

    var tick = 0
    var petted = 0
    var hop = 0
    var yawn = 0
    var lastMood: Mood = .idle
    var moodSince = 0
    var chatField: NSTextField?
    var reply: (title: String?, text: String)?
    var replyUntil = Date.distantPast
    var pendingTask: String?

    var walkEnabled = UserDefaults.standard.object(forKey: "walk") as? Bool ?? true
    var walkTarget: NSPoint?
    var walkScreen: NSRect?
    var walkPause = 30
    var walking = false
    var facing = 1
    /// Abstand der Fensterunterkante zur Unterkante des sichtbaren Bildschirmbereichs.
    var homeHeight: CGFloat?
    /// Fenster (Cocoa-Koordinaten), auf dessen Oberkante er gerade sitzt.
    var perch: NSRect?

    private var dragOrigin: NSPoint?
    private var windowOrigin: NSPoint = .zero
    private var dragged = false

    let px: CGFloat = 5

    init(store: Store, buddy: Buddy, vitals: Vitals, tasks: TaskRunner, frame: NSRect) {
        self.store = store
        self.buddy = buddy
        self.vitals = vitals
        self.tasks = tasks
        super.init(frame: frame)
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.step() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    var mood: Mood { buddy.busy ? .working : store.mood }

    var petOrigin: NSPoint {
        NSPoint(x: (bounds.width - CGFloat(spriteCols) * px) / 2, y: bounds.height - CGFloat(spriteRows) * px - 10)
    }

    var petRect: NSRect {
        NSRect(x: petOrigin.x - 10, y: petOrigin.y - 40, width: CGFloat(spriteCols) * px + 20, height: CGFloat(spriteRows) * px + 50)
    }

    var pose: PetPose {
        PetPose(mood: mood, t: tick - moodSince, tick: tick, petted: petted, hop: hop, walking: walking,
                facing: facing, yawning: yawn > 0, hungry: vitals.hungry, grumpy: vitals.grumpy)
    }

    private func step() {
        tick += 1
        if petted > 0 { petted -= 1 }
        if hop > 0 { hop -= 1 }
        if yawn > 0 { yawn -= 1 }
        if reply != nil && Date() > replyUntil { reply = nil; pendingTask = nil }
        if mood == .idle && !walking && yawn == 0 && Int.random(in: 0..<1500) == 0 { yawn = 20 }
        stepWalk()
        needsDisplay = true
    }

    // MARK: Zeichnen

    override func draw(_ dirtyRect: NSRect) {
        let mood = self.mood
        if mood != lastMood { lastMood = mood; moodSince = tick }
        let pose = self.pose
        drawShadow(centerX: bounds.midX, y: bounds.height - 12, width: CGFloat(spriteCols) * px, lift: pose.lift)
        drawPet(pose, at: petOrigin, px: px)

        let bottom = petOrigin.y - 6 * px - 8
        if chatField != nil {
            return
        } else if let reply {
            drawBubble(in: bounds, bottom: bottom, title: reply.title, body: reply.text,
                       accent: pendingTask != nil ? Palette.alert : Palette.body)
        } else if mood == .waiting || mood == .done, let s = store.pending.first {
            let icon = s.icon.isEmpty ? (s.mood == .waiting ? "✋" : "✅") : s.icon
            let more = store.pending.count > 1 ? "  +\(store.pending.count - 1)" : ""
            let body = s.mood == .waiting && s.isAgent && !s.detail.isEmpty ? "will: \(s.detail)\n\(s.text)" : s.text
            drawBubble(in: bounds, bottom: bottom, title: "\(icon) \(s.isAgent ? store.name(for: s.id) + " · " : "")\(s.label)\(more)", body: body,
                       accent: s.mood == .waiting ? Palette.alert : Palette.body)
        }
    }

    func showReply(_ text: String, title: String? = nil, seconds: Double? = nil) {
        reply = (title, text)
        replyUntil = Date().addingTimeInterval(seconds ?? max(10, Double(text.count) / 12))
    }

    // MARK: Herumlaufen

    /// Läuft im Leerlauf und beim Arbeiten kreuz und quer über alle Bildschirme, mal auf der Lieblingshöhe
    /// (`homeHeight`), mal irgendwo, und springt ab und zu auf das aktive Fenster. Bei Meldungen, Chat
    /// oder Antwort bleibt er stehen.
    func stepWalk() {
        walking = false
        guard let win = window, dragOrigin == nil else { return }
        let floors = NSScreen.screens.map(\.visibleFrame)
        guard !floors.isEmpty else { return }
        let size = win.frame.size
        let here = screen(containing: NSPoint(x: win.frame.midX, y: win.frame.minY + 20), in: floors)
        if homeHeight == nil { homeHeight = win.frame.minY - here.minY }
        let inset = (size.width - CGFloat(spriteCols) * px) / 2 - 10

        func place(_ p: NSPoint, on vf: NSRect, inside: Bool) {
            let ins = inside ? 0 : inset
            let n = NSPoint(x: min(max(p.x, vf.minX - ins), vf.maxX - size.width + ins),
                            y: min(max(p.y, vf.minY), vf.maxY - size.height))
            if n != win.frame.origin { win.setFrameOrigin(n) }
        }

        let free = walkEnabled && chatField == nil && reply == nil && !buddy.busy && (mood == .idle || mood == .working)
        guard free else {
            walkTarget = nil
            place(win.frame.origin, on: here, inside: true)
            return
        }
        if walkPause > 0 { walkPause -= 1; return }

        guard let target = walkTarget, let screen = walkScreen else {
            if perch != nil {
                perch = nil
                hop = 6
                walkPause = 10
                return
            }
            if Int.random(in: 0..<4) == 0, let w = frontWindow(), w.width > 300 {
                let vf = self.screen(containing: NSPoint(x: w.midX, y: w.maxY - 5), in: floors)
                let lo = max(w.minX - inset, vf.minX - inset), hi = min(w.maxX - size.width + inset, vf.maxX - size.width + inset)
                if w.maxY + size.height - 10 < vf.maxY, lo < hi {
                    perch = w
                    hop = 6
                    place(NSPoint(x: CGFloat.random(in: lo...hi), y: w.maxY - 10), on: vf, inside: false)
                    walkScreen = vf
                    walkTarget = NSPoint(x: CGFloat.random(in: lo...hi), y: w.maxY - 10)
                    return
                }
            }
            let vf = floors.count > 1 && Int.random(in: 0..<3) == 0 ? floors.filter { $0 != here }.randomElement()! : here
            let top = max(vf.minY, vf.maxY - size.height)
            walkScreen = vf
            walkTarget = NSPoint(x: CGFloat.random(in: (vf.minX - inset)...(vf.maxX - size.width + inset)),
                                 y: Int.random(in: 0..<3) == 0 ? vf.minY + (homeHeight ?? 0) : CGFloat.random(in: vf.minY...top))
            return
        }

        let pos = win.frame.origin
        let speed: CGFloat = 2.5
        // Mit "Monitore verwenden verschiedene Spaces" lässt macOS kein Fenster über die Displaygrenze
        // ragen: bis an den Rand des aktuellen Bildschirms laufen und dann hinüberspringen.
        var goal = target
        if here != screen {
            goal.y = min(max(target.y, here.minY), here.maxY - size.height)
            if screen.maxX <= here.minX + 1 { goal.x = here.minX }
            else if screen.minX >= here.maxX - 1 { goal.x = here.maxX - size.width }
            else { goal = pos }
        }
        let dx = goal.x - pos.x, dy = goal.y - pos.y, dist = hypot(dx, dy)
        if dist <= speed {
            if here != screen {
                let x = screen.maxX <= here.minX + 1 ? screen.maxX - size.width : screen.minX >= here.maxX - 1 ? screen.minX : target.x
                place(NSPoint(x: x, y: pos.y), on: screen, inside: true)
                return
            }
            place(target, on: screen, inside: false)
            arrive()
            return
        }
        walking = true
        if abs(dx) > 0.5 { facing = dx > 0 ? 1 : -1 }
        place(NSPoint(x: pos.x + dx / dist * speed, y: pos.y + dy / dist * speed), on: here, inside: here != screen)
        if hypot(win.frame.minX - pos.x, win.frame.minY - pos.y) < 0.5 { arrive() }
    }

    private func arrive() {
        walkTarget = nil
        walkScreen = nil
        walkPause = Int.random(in: 40...250)
    }

    private func screen(containing pt: NSPoint, in floors: [NSRect]) -> NSRect {
        floors.first { $0.contains(pt) }
            ?? floors.min { hypot($0.midX - pt.x, $0.midY - pt.y) < hypot($1.midX - pt.x, $1.midY - pt.y) }!
    }

    /// Oberstes normales Fenster der aktiven App, in Cocoa-Koordinaten.
    private func frontWindow() -> NSRect? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let primary = NSScreen.screens.first?.frame.height else { return nil }
        for w in list where w[kCGWindowOwnerPID as String] as? pid_t == pid && w[kCGWindowLayer as String] as? Int == 0 {
            guard let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let width = b["Width"], let height = b["Height"] else { continue }
            return NSRect(x: x, y: primary - y - height, width: width, height: height)
        }
        return nil
    }

    // MARK: Maus

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let hit = super.hitTest(point), hit !== self { return hit }
        let local = convert(point, from: superview)
        let bubble = reply != nil || mood == .waiting || mood == .done
        return petRect.contains(local) || bubble && local.y < petRect.minY ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        dragOrigin = NSEvent.mouseLocation
        windowOrigin = window?.frame.origin ?? .zero
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragOrigin else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - start.x, dy = now.y - start.y
        if abs(dx) + abs(dy) > 3 { dragged = true }
        if dragged { window?.setFrameOrigin(NSPoint(x: windowOrigin.x + dx, y: windowOrigin.y + dy)) }
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragOrigin = nil }
        if dragged {
            perch = nil
            walkTarget = nil
            if let win = window {
                let floors = NSScreen.screens.map(\.visibleFrame)
                if !floors.isEmpty {
                    homeHeight = win.frame.minY - screen(containing: NSPoint(x: win.frame.midX, y: win.frame.minY + 20), in: floors).minY
                }
            }
            return
        }
        if let task = pendingTask, reply != nil {
            pendingTask = nil
            tasks.start(task)
            showReply("Läuft. Ich sag Bescheid, wenn's durch ist.", seconds: 5)
        } else if let s = store.pending.first, reply == nil, chatField == nil {
            performClick(s.click)
            store.ack(s.id)
        } else if chatField != nil {
            closeChat()
        } else {
            reply = nil
            pendingTask = nil
            openChat()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        func info(_ title: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        func item(_ title: String, _ action: Selector, on: Bool? = nil) {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = self
            if let on { i.state = on ? .on : .off }
            menu.addItem(i)
        }
        let working = store.sessions.values.filter { $0.mood == .working }.count
        info("\(working) arbeiten · \(store.pending.count) offen")
        info("Futter \(vitals.dots(vitals.food))   Laune \(vitals.dots(vitals.joy))")
        menu.addItem(.separator())
        item("Frag mich was …  (⌃⌥Leertaste)", #selector(openChat))
        item("Neues Gespräch", #selector(newChat))
        item("Füttern", #selector(feed))
        menu.addItem(.separator())
        item("Herumlaufen", #selector(toggleWalk), on: walkEnabled)
        item("Alles quittieren", #selector(ackAll))
        item("Zurück in die Ecke", #selector(resetPosition))
        menu.addItem(.separator())
        menu.addItem(withTitle: "Beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc func ackAll() { store.ackAll() }

    @objc func newChat() { buddy.reset(); reply = nil; pendingTask = nil }

    @objc func feed() {
        vitals.food += 2
        petted = 20
        showReply(["Mjam.", "Endlich. Ich dachte schon, du hast mich vergessen.", "Lecker Bytes."].randomElement()!, seconds: 4)
    }

    @objc func toggleWalk() {
        walkEnabled.toggle()
        UserDefaults.standard.set(walkEnabled, forKey: "walk")
    }

    @objc func resetPosition() {
        guard let win = window else { return }
        perch = nil
        homeHeight = nil
        win.setFrameOrigin(defaultOrigin(for: win.frame.size))
    }

    // MARK: Chat

    @objc func toggleChat() {
        if chatField != nil { closeChat() } else { reply = nil; pendingTask = nil; openChat() }
    }

    @objc func openChat() {
        guard chatField == nil else { return }
        let f = NSTextField(frame: NSRect(x: 12, y: petRect.minY - 30, width: bounds.width - 24, height: 24))
        f.placeholderString = "Na, was ist?"
        f.font = .systemFont(ofSize: 12.5)
        f.bezelStyle = .roundedBezel
        f.focusRingType = .none
        f.delegate = self
        f.target = self
        f.action = #selector(sendChat)
        addSubview(f)
        chatField = f
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(f)
    }

    func closeChat() {
        chatField?.removeFromSuperview()
        chatField = nil
        window?.resignKey()
    }

    @objc func sendChat() {
        let q = chatField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        closeChat()
        guard !q.isEmpty else { return }
        buddy.ask(q, situation: situation()) { [weak self] answer in
            guard let self else { return }
            self.vitals.joy += 0.2
            self.petted = 20
            var lines = answer.components(separatedBy: "\n")
            if let first = lines.first, first.hasPrefix("AUFTRAG:") {
                let task = first.dropFirst("AUFTRAG:".count).trimmingCharacters(in: .whitespaces)
                lines.removeFirst()
                let comment = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                self.pendingTask = task
                self.showReply(task + (comment.isEmpty ? "" : "\n\n" + comment),
                               title: "🛠 An Claude geben? Klick = los", seconds: 45)
            } else {
                self.showReply(answer)
            }
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        closeChat()
        return true
    }

    func situation() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "EEEE, HH:mm"
        let label: [Mood: String] = [.working: "arbeitet", .done: "fertig, ungelesen", .waiting: "wartet auf Martin"]
        let sessions = store.sessions.values.sorted { $0.updated > $1.updated }.map { s in
            "\(s.label) \(label[s.mood] ?? "")\(s.icon.isEmpty ? "" : " " + s.icon) seit \(Int(Date().timeIntervalSince(s.updated) / 60)) min"
        }
        var parts = [f.string(from: Date()), sessions.isEmpty ? "keine aktiven Sessions" : sessions.joined(separator: "; ")]
        if let mr = gitlab?.summary, !mr.isEmpty { parts.append(mr) }
        parts.append("Haustier: Futter \(Int(vitals.food.rounded()))/5, Laune \(Int(vitals.joy.rounded()))/5")
        return parts.joined(separator: "; ")
    }
}

func defaultOrigin(for size: NSSize) -> NSPoint {
    let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    return NSPoint(x: vf.maxX - size.width - 20, y: vf.minY + 10)
}
