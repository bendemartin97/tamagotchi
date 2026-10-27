import AppKit

/// Das große Haustier: Sammelstatus, Sprechblase, Chat, Herumlaufen.
final class PetView: NSView, NSTextFieldDelegate {
    let store: Store
    let buddy: Buddy
    let vitals: Vitals
    let tasks: TaskRunner
    var brain: Brain?
    /// Bis wann gefeiert wird (Abnahme, Merge, Ticket erledigt).
    var partyUntil = Date.distantPast

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
    enum ChatMode { case chat, answer(FeedbackItem), rework(FeedbackItem) }
    var chatMode = ChatMode.chat

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
                facing: facing, yawning: yawn > 0, hungry: vitals.hungry, grumpy: vitals.grumpy, prop: prop)
    }

    var prop: Prop {
        if Date() < partyUntil { return .party }
        guard let items = brain?.items else { return .none }
        if mood == .waiting, let s = store.pending.first, s.mood == .waiting, s.isAgent { return .letter }
        if items.contains(where: { $0.feedback?.status == .question }) && mood != .working { return .letter }
        if (mood == .idle || mood == .working) && items.contains(where: { $0.group == "pipeline" }) { return .hourglass }
        return .none
    }

    /// Überschrift der Sprechblase: bei Agent-Sessions Spitzname und Aufgabe, sonst die Aufgabe.
    func bubbleTitle(_ s: Session) -> String {
        let topic = brain?.topic(s) ?? s.label
        return s.isAgent ? "\(store.name(for: s.id)) · \(topic)" : topic
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
        if let field = chatField {
            let title: String?
            switch chatMode {
            case .chat: title = nil
            case .answer(let f): title = "❓ \(f.headline)"
            case .rework(let f): title = "🔁 \(f.headline)"
            }
            let body: String
            if case .answer(let f) = chatMode { body = f.question.isEmpty ? "Was soll der Agent wissen?" : f.question }
            else if case .rework = chatMode { body = "Was soll noch anders werden?" }
            else { body = brain?.summary ?? "" }
            if !body.isEmpty { drawBubble(in: bounds, bottom: field.frame.minY - 6, title: title, body: body, accent: Palette.body) }
            return
        } else if let reply {
            drawBubble(in: bounds, bottom: bottom, title: reply.title, body: reply.text,
                       accent: pendingTask != nil ? Palette.alert : Palette.body)
        } else if mood == .waiting || mood == .done, let s = store.pending.first {
            let icon = s.icon.isEmpty ? (s.mood == .waiting ? "✋" : "✅") : s.icon
            let more = store.pending.count > 1 ? "  +\(store.pending.count - 1)" : ""
            let body = s.mood == .waiting && s.isAgent && !s.detail.isEmpty ? "will: \(s.detail)\n\(s.text)" : s.text
            drawBubble(in: bounds, bottom: bottom, title: "\(icon) \(bubbleTitle(s))\(more)", body: body,
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
            store.ack(s.id)
            if s.click.first == "-task", s.click.count == 2 { offerTask(s.click[1], text: s.text) } else { performClick(s.click) }
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
        info("Futter \(vitals.dots(vitals.food))   Laune \(vitals.dots(vitals.joy))")
        info(State.shared.checkedLine)
        menu.addItem(.separator())
        item("Was braucht mich gerade?", #selector(showSummary))
        if let brain {
            let sections: [(Attention.Who, String)] = [(.you, "Du bist dran"), (.others, "Andere sind dran"), (.auto, "Läuft automatisch")]
            func add(_ a: Attention, to m: NSMenu, indent: String = "   ") {
                m.addItem(ActionItem("\(indent)\(a.icon) \(shorten(a.phrase, 70))") { [weak self] in self?.act(a) })
            }
            func folder(_ title: String, _ list: [Attention]) {
                guard !list.isEmpty else { return }
                let sub = NSMenu()
                list.forEach { add($0, to: sub, indent: "") }
                let parent = NSMenuItem(title: "   \(title) (\(list.count))", action: nil, keyEquivalent: "")
                parent.submenu = sub
                menu.addItem(parent)
            }
            for (who, title) in sections {
                let list = brain.items.filter { $0.who == who }
                guard !list.isEmpty else { continue }
                info(title)
                if who == .you {
                    let now = list.filter { brain.rank($0) == .now }
                    now.forEach { add($0, to: menu) }
                    if now.isEmpty { info("   Nichts Dringendes") }
                    folder("Kann warten", list.filter { brain.rank($0) == .later })
                    folder("Ausgeblendet", list.filter { brain.rank($0) == .hidden })
                    continue
                }
                for a in list.prefix(12) { add(a, to: menu) }
                if list.count > 12 { info("   … und \(list.count - 12) weitere") }
            }
            let works = brain.list.filter { w in !w.changes.isEmpty || w.workspace != nil && brain.items.contains { $0.workKey == w.key } }
            if !works.isEmpty {
                let sub = NSMenu()
                for w in works {
                    let entry = NSMenuItem(title: w.topic + (w.ticket.map { $0.status.isEmpty ? "" : "  · \($0.status)" } ?? ""), action: nil, keyEquivalent: "")
                    entry.submenu = workMenu(w)
                    sub.addItem(entry)
                }
                let parent = NSMenuItem(title: "Aufgaben", action: nil, keyEquivalent: "")
                parent.submenu = sub
                menu.addItem(parent)
            }
        }
        menu.addItem(.separator())
        item("Frag mich was …  (⌃⌥Leertaste)", #selector(openChatAction))
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

    @objc func showSummary() {
        brain?.refresh()
        showReply(brain?.summary ?? "Gerade braucht dich nichts.", title: "Was braucht dich gerade?", seconds: 15)
    }

    /// Vorbereiteten Auftrag zeigen; ein Klick auf die Blase startet ihn.
    func offerTask(_ task: String, text: String) {
        pendingTask = task
        showReply(text.replacingOccurrences(of: " Klick = Ticket-Korrektur vorbereiten.", with: ""), title: "🛠 Korrigieren lassen? Klick = los", seconds: 45)
    }

    /// Hauptaktion eines Eintrags aus „Was braucht gerade mich?“.
    func act(_ a: Attention) {
        if let f = a.feedback {
            switch f.status {
            case .question: openChat(mode: .answer(f))
            default: brain?.feedback.view(f)
            }
        } else if let task = a.task {
            offerTask(task, text: a.phrase + ".")
        } else if let id = a.session, let s = store.sessions[id] {
            performClick(s.click)
            if s.mood != .working { store.ack(id) }
        } else if let url = a.url {
            openURL(url)
        }
    }

    /// Ticket, Workspace, Session und Änderungen einer Aufgabe.
    func workMenu(_ w: Work) -> NSMenu {
        let m = NSMenu()
        if let t = w.ticket, !t.name.isEmpty {
            let i = NSMenuItem(title: "\(shorten(t.name, 60)) · \(t.status)", action: nil, keyEquivalent: "")
            i.isEnabled = false
            m.addItem(i)
        }
        for (title, run) in brain?.works.actions(for: w) ?? [] { m.addItem(ActionItem(title, run)) }
        return m
    }

    /// Kontextmenü eines Minis: Aufgabe plus Feedback-Aktionen für seine Session.
    func sessionMenu(_ s: Session) -> NSMenu? {
        guard let brain else { return nil }
        let m = brain.work(forSession: s).map(workMenu) ?? NSMenu()
        if !s.click.isEmpty { m.insertItem(ActionItem("Zur Session springen") { performClick(s.click) }, at: 0) }
        for f in brain.feedback.items(forSession: s.id) where f.needsMartin {
            m.addItem(.separator())
            let head = NSMenuItem(title: "\(f.status == .question ? "❓" : "👀") \(f.headline)", action: nil, keyEquivalent: "")
            head.isEnabled = false
            m.addItem(head)
            if f.status == .question { m.addItem(ActionItem("   Antworten …") { [weak self] in self?.openChat(mode: .answer(f)) }) }
            m.addItem(ActionItem("   Ansehen") { brain.feedback.view(f) })
            if f.status != .question {
                m.addItem(ActionItem("   Passt") { [weak self] in
                    brain.feedback.accept(f)
                    self?.celebrate()
                })
                m.addItem(ActionItem("   Nachbessern …") { [weak self] in self?.openChat(mode: .rework(f)) })
            }
        }
        return m
    }

    func celebrate(seconds: Double = 60) {
        partyUntil = Date().addingTimeInterval(seconds)
        hop = 6
    }

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

    @objc func openChatAction() { openChat(mode: .chat) }

    func openChat(mode: ChatMode = .chat) {
        if chatField != nil { closeChat() }
        reply = nil
        pendingTask = nil
        chatMode = mode
        brain?.refresh()
        let f = NSTextField(frame: NSRect(x: 12, y: petRect.minY - 30, width: bounds.width - 24, height: 24))
        switch mode {
        case .chat: f.placeholderString = "Na, was ist?"
        case .answer: f.placeholderString = "Antwort an den Agenten …"
        case .rework: f.placeholderString = "Was soll nachgebessert werden?"
        }
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
        chatMode = .chat
        window?.resignKey()
    }

    @objc func sendChat() {
        let q = chatField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let mode = chatMode
        closeChat()
        guard !q.isEmpty else { return }
        switch mode {
        case .answer(let f):
            brain?.feedback.answer(f, text: q)
            showReply("Weitergegeben. Der Agent macht weiter.", seconds: 5)
            return
        case .rework(let f):
            brain?.feedback.rework(f, text: q)
            showReply("Geht zurück an den Agenten.", seconds: 5)
            return
        case .chat:
            break
        }
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
            "\(bubbleTitle(s)) \(label[s.mood] ?? "")\(s.icon.isEmpty ? "" : " " + s.icon) seit \(Int(Date().timeIntervalSince(s.updated) / 60)) min"
        }
        var parts = [f.string(from: Date()), sessions.isEmpty ? "keine aktiven Sessions" : sessions.joined(separator: "; ")]
        if let brain {
            parts.append("Was Martin braucht: \(brain.summary)")
            let you = brain.forYou.map(\.phrase)
            if !you.isEmpty { parts.append("Für Martin offen: " + you.prefix(8).joined(separator: "; ")) }
        }
        parts.append("Zuletzt geprüft: \(State.shared.checkedLine)")
        parts.append("Haustier: Futter \(Int(vitals.food.rounded()))/5, Laune \(Int(vitals.joy.rounded()))/5")
        return parts.joined(separator: "; ")
    }
}

/// Menüeintrag mit Closure statt Selector.
final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}

func defaultOrigin(for size: NSSize) -> NSPoint {
    let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    return NSPoint(x: vf.maxX - size.width - 20, y: vf.minY + 10)
}
