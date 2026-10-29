import AppKit

/// Quiet mode: no pets, no bubbles while Martin is sharing their screen or has turned it on manually.
/// Notifications collect in the inbox; afterwards there is a single summary.
final class Quiet {
    var onEnd: ((Date) -> Void)?
    private(set) var active = false
    private(set) var sharing = false
    private var since = Date()

    var until: Date? {
        get { UserDefaults.standard.object(forKey: "quietUntil") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "quietUntil") }
    }

    init() {
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.check() }
    }

    func set(_ until: Date?) {
        self.until = until
        check()
    }

    var label: String {
        if sharing { return "Bildschirm wird geteilt" }
        guard let u = until, u > Date() else { return "" }
        return u == .distantFuture ? "bis du ihn ausschaltest" : "bis \(u.formatted(date: .omitted, time: .shortened))"
    }

    private func check() {
        sharing = Self.screenSharing()
        let on = sharing || (until ?? .distantPast) > Date()
        if on && !active { since = Date() }
        if !on && active { onEnd?(since) }
        active = on
    }

    /// Detects screen sharing from the windows that Zoom, Teams, Meet (Chrome) and Slack show while sharing.
    /// Needs the screen recording permission that the Tamagotchi already has for the chat.
    static func screenSharing() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        for w in list {
            let owner = (w[kCGWindowOwnerName as String] as? String ?? "").lowercased()
            let name = (w[kCGWindowName as String] as? String ?? "").lowercased()
            if owner.contains("zoom") && name.contains("share") { return true }
            if owner.contains("teams") && (name.contains("sharing") || name.contains("freigabe")) { return true }
            if owner.contains("slack") && name.contains("screen share") { return true }
            if name.contains("is sharing your screen") || name.contains("teilt ihren bildschirm") || name.contains("teilt deinen bildschirm")
                || name.contains("sharing this tab") || name.contains("dieser tab wird") { return true }
        }
        return false
    }
}

/// Menu bar: counters for waiting agents, red pipelines and unread notifications, with the most important items in the menu.
final class StatusBar: NSObject, NSMenuDelegate {
    let store: Store
    let brain: Brain
    let quiet: Quiet
    var openHub: (Hub.Tab?) -> Void = { _ in }
    var openAgent: (String) -> Void = { _ in }
    var openMessage: (Message) -> Void = { _ in }
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    init(store: Store, brain: Brain, quiet: Quiet) {
        self.store = store
        self.brain = brain
        self.quiet = quiet
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        update()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.update() }
    }

    /// App icon for the menu bar: only the squircle (without the transparent margin), 18 pt, optionally with a dot.
    private func icon(dot: NSColor?) -> NSImage {
        let app = NSApp.applicationIconImage ?? NSImage()
        let size = NSSize(width: 18, height: 18)
        return NSImage(size: size, flipped: false) { r in
            let inset = app.size.width * 100 / 1024
            app.draw(in: r, from: NSRect(origin: .zero, size: app.size).insetBy(dx: inset, dy: inset), operation: .sourceOver, fraction: 1)
            if let dot {
                let d = NSRect(x: r.maxX - 6, y: r.maxY - 6, width: 6, height: 6)
                NSColor.black.withAlphaComponent(0.5).setFill()
                NSBezierPath(ovalIn: d.insetBy(dx: -1, dy: -1)).fill()
                dot.setFill()
                NSBezierPath(ovalIn: d).fill()
            }
            return true
        }
    }

    /// Icon only; a dot shows whether something is waiting (orange) or broken (red). The numbers are in the tooltip.
    /// When the screen is shared, the audience also sees the menu bar: so no dot and no tooltip then.
    private func update() {
        guard let button = item.button else { return }
        if quiet.active {
            button.image = icon(dot: nil)
            button.toolTip = "Ruhe-Modus"
            shown = nil
            return
        }
        let waiting = store.agents.filter { $0.mood == .waiting }.count
        let working = store.agents.filter { $0.mood == .working }.count
        let red = State.shared.data.changes.values.filter { $0.isOpen && $0.mine && $0.pipeline == "failed" }.count
        let unread = store.inbox.unreadCount
        let dot: NSColor? = red > 0 ? .systemRed : waiting > 0 ? .systemOrange : nil
        let key = "\(dot?.description ?? "")"
        if key != shown || button.image == nil {
            shown = key
            button.image = icon(dot: dot)
        }
        button.title = ""
        button.toolTip = "\(waiting) warten · \(working) arbeiten · \(red) Pipelines rot · \(unread) ungelesen"
    }

    private var shown: String?

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func info(_ title: String) {
            let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            i.isEnabled = false
            menu.addItem(i)
        }
        info(shorten(brain.summary, 90))
        menu.addItem(.separator())

        let now = store.inbox.active.filter { !$0.read && brain.rank($0).rank == .now }.prefix(6)
        if !now.isEmpty {
            info("Jetzt dran")
            for m in now { menu.addItem(ActionItem("   \(m.symbol) \(shorten(brain.title(m) + ": " + m.text, 80))") { [weak self] in self?.openMessage(m) }) }
            menu.addItem(.separator())
        }
        let agents = store.agents
        if !agents.isEmpty {
            info("Agenten")
            for s in agents {
                let dot = ["working": "⚙️", "waiting": "✋", "done": "✅"][s.mood.rawValue] ?? "•"
                menu.addItem(ActionItem("   \(dot) \(store.name(for: s.id)) · \(shorten(brain.topic(s), 40)) — \(agentStatus(s).text)") { [weak self] in
                    self?.openAgent(s.id)
                })
            }
            menu.addItem(.separator())
        }
        menu.addItem(ActionItem("Übersicht öffnen   ⌃⌥I") { [weak self] in self?.openHub(nil) })
        menu.addItem(ActionItem("Inbox (\(store.inbox.unreadCount) ungelesen)") { [weak self] in self?.openHub(.inbox) })
        menu.addItem(ActionItem("Standup & Zeiten") { [weak self] in self?.openHub(.report) })
        menu.addItem(.separator())
        menu.addItem(quietMenu(quiet))
        info(State.shared.checkedLine)
    }
}

/// Submenu "Ruhe-Modus" (quiet mode), also in the pet's context menu.
func quietMenu(_ quiet: Quiet) -> NSMenuItem {
    let sub = NSMenu()
    if quiet.active {
        let i = NSMenuItem(title: "Aktiv: \(quiet.label)", action: nil, keyEquivalent: "")
        i.isEnabled = false
        sub.addItem(i)
        if quiet.until != nil { sub.addItem(ActionItem("Ausschalten") { quiet.set(nil) }) }
        sub.addItem(.separator())
    }
    sub.addItem(ActionItem("1 Stunde") { quiet.set(Date().addingTimeInterval(3600)) })
    sub.addItem(ActionItem("2 Stunden") { quiet.set(Date().addingTimeInterval(7200)) })
    sub.addItem(ActionItem("Bis morgen früh") { quiet.set(nextMorning()) })
    sub.addItem(ActionItem("Bis ich ihn ausschalte") { quiet.set(.distantFuture) })
    let parent = NSMenuItem(title: quiet.active ? "Ruhe-Modus (an)" : "Ruhe-Modus", action: nil, keyEquivalent: "")
    parent.submenu = sub
    return parent
}
