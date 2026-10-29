import AppKit

/// Ruhe-Modus: keine Haustiere, keine Blasen, solange Martin den Bildschirm teilt oder ihn von Hand einschaltet.
/// Meldungen sammeln sich in der Inbox; danach gibt es eine einzige Zusammenfassung.
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

    /// Erkennt Bildschirmfreigabe an den Fenstern, die Zoom, Teams, Meet (Chrome) und Slack dabei zeigen.
    /// Braucht die Bildschirmaufnahme-Freigabe, die das Tamagotchi für den Chat ohnehin hat.
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

/// Menüleiste: Zähler für wartende Agenten, rote Pipelines und ungelesene Meldungen, im Menü das Wichtigste.
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

    private func update() {
        guard let button = item.button else { return }
        // Bei geteiltem Bildschirm sieht das Publikum die Menüleiste mit: dann nur das Symbol.
        if quiet.active {
            button.title = "🤫"
            return
        }
        let waiting = store.agents.filter { $0.mood == .waiting }.count
        let working = store.agents.filter { $0.mood == .working }.count
        let red = State.shared.data.changes.values.filter { $0.isOpen && $0.mine && $0.pipeline == "failed" }.count
        let unread = store.inbox.unreadCount
        var parts: [String] = []
        if waiting > 0 { parts.append("✋\(waiting)") }
        if working > 0 { parts.append("⚙️\(working)") }
        if red > 0 { parts.append("🔴\(red)") }
        if unread > 0 { parts.append("📥\(unread)") }
        button.title = parts.isEmpty ? "🐾" : parts.joined(separator: " ")
    }

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

/// Untermenü „Ruhe-Modus“, auch im Kontextmenü des Haustiers.
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
