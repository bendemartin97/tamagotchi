// Desktop-Tamagotchi für Claude Code / Codex.
// Liest ~/.claude/tamagotchi/events.jsonl (geschrieben von ~/.claude/hooks/pet.sh und notify.sh),
// beobachtet Martins MRs/PRs auf GitLab und GitHub, verknüpft sie mit ClickUp-Tickets und Workspaces, sagt,
// was gerade Martins Aufmerksamkeit braucht, chattet über `claude -p` und gibt Aufträge an Claude Code weiter.
// Klick: öffnet die dringendste Meldung, sonst den Chat (auch ⌃⌥Leertaste). Doppelklick oder ⌃⌥I: Übersicht
// (Live, Inbox, Aufgaben, MRs, Bericht, Agentenansicht). Ziehen: verschieben. Rechtsklick: Menü. Menüleiste: Zähler
// und Kurzmenü. Meldungen stehen 2 min in der Blase und bleiben in der Inbox, bis Martin sie erledigt. Jede
// Agent-Session bekommt ein Mini-Haustier, das hinterherläuft. Bei offener Übersicht und im Ruhe-Modus
// (Bildschirmfreigabe oder von Hand) sind die Haustiere ausgeblendet.

import AppKit
import Carbon

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Globale Tastenkürzel mit ⌃⌥ über Carbon (braucht keine Bedienungshilfen-Freigabe).
enum Hotkey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var refs: [EventHotKeyRef?] = []

    static func register(_ id: UInt32, key: Int, _ handler: @escaping () -> Void) {
        if handlers.isEmpty {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hk = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &hk)
                Hotkey.handlers[hk.id]?()
                return noErr
            }, 1, &spec, nil, nil)
        }
        handlers[id] = handler
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(key), UInt32(controlKey | optionKey),
                            EventHotKeyID(signature: OSType(0x5441_4D41), id: id), GetApplicationEventTarget(), 0, &ref)
        refs.append(ref)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: KeyPanel!
    var view: PetView!
    let store = Store()
    let buddy = Buddy()
    let vitals = Vitals()
    lazy var tasks = TaskRunner(store: store)
    lazy var followers = Followers(store: store)
    lazy var headliner = Headliner(store: store)
    lazy var works = Works(store: store)
    let feedback = FeedbackWatch()
    lazy var brain = Brain(store: store, works: works, feedback: feedback)
    lazy var notifier = Notifier(store: store, works: works)
    lazy var returns = Returns(store: store, brain: brain)
    lazy var hub = Hub(store: store, brain: brain, tasks: tasks)
    lazy var watchdog = Watchdog(store: store, logs: hub.logs, works: works)
    lazy var timekeeper = Timekeeper(works: works)
    let quiet = Quiet()
    var statusBar: StatusBar!
    var gitlab: GitLabWatch!
    var github: GitHubWatch!
    var clickup: ClickUpWatch!
    /// Sessions, deren Mini gerade feiert (Abnahme, Merge).
    var parties: [String: Date] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Nur eine Instanz: macOS startet die App z. B. nach der Bildschirmaufnahme-Freigabe selbst neu,
        // zusätzlich zum LaunchAgent. Die neueste gewinnt.
        let me = ProcessInfo.processInfo.processIdentifier
        for other in NSRunningApplication.runningApplications(withBundleIdentifier: "com.martinbende.tamagotchi")
        where other.processIdentifier != me {
            other.forceTerminate()
        }

        let size = NSSize(width: 300, height: 280)
        panel = KeyPanel(contentRect: NSRect(origin: defaultOrigin(for: size), size: size),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.setFrameUsingName("TamagotchiPanel")
        panel.setFrame(NSRect(origin: panel.frame.origin, size: size), display: false)
        panel.setFrameAutosaveName("TamagotchiPanel")
        view = PetView(store: store, buddy: buddy, vitals: vitals, tasks: tasks, frame: NSRect(origin: .zero, size: size))
        panel.contentView = view
        panel.orderFrontRegardless()

        view.brain = brain
        brain.refresh()
        hub.open = { [weak self] in self?.view.open($0) }
        hub.celebrate = { [weak self] in self?.view.celebrate() }
        hub.prop = { [weak self] in self?.prop(for: $0) ?? .none }
        view.onOpenHub = { [weak self] in self?.hub.show($0) }
        view.quiet = quiet
        hub.reports = Reports(store: store, brain: brain, time: timekeeper)
        hub.problems = { [weak self] in self?.watchdog.problems[$0] ?? [] }
        store.onEvent = { [weak self] in self?.timekeeper.ping($0) }
        statusBar = StatusBar(store: store, brain: brain, quiet: quiet)
        statusBar.openHub = { [weak self] in self?.hub.show($0) }
        statusBar.openAgent = { [weak self] id in
            self?.hub.show()
            self?.hub.agentFilter = id
        }
        statusBar.openMessage = { [weak self] in self?.view.open($0) }
        quiet.onEnd = { [weak self] since in self?.quietEnded(since) }
        _ = watchdog
        gitlab = GitLabWatch()
        github = GitHubWatch()
        clickup = ClickUpWatch(store: store, works: works)
        gitlab.onSignals = { [weak self] in self?.notifier.post($0) }
        github.onSignals = { [weak self] in self?.notifier.post($0) }
        notifier.onKind = { [weak self] kind in self?.react(kind) }
        clickup.onUpdate = { [weak self] before in self?.ticketsChanged(before) }
        feedback.onChange = { [weak self] item, before in self?.feedbackChanged(item, before) }
        returns.onSummary = { [weak self] topic, text in
            guard let self, self.view.chatField == nil else { return }
            self.view.showReply(text, title: "↩︎ \(topic)", seconds: 25)
        }

        followers.label = { [weak self] s in self?.brain.topic(s) ?? s.label }
        followers.prop = { [weak self] s in self?.prop(for: s) ?? .none }
        followers.contextMenu = { [weak self] s in self?.view.sessionMenu(s) }

        store.onWorking = { [weak self] s in
            self?.headliner.refresh(s, done: false)
            self?.returns.seen(s.project)
        }
        store.onDone = { [weak self] s in
            self?.headliner.refresh(s, done: true)
            self?.returns.record(s)
            self?.vitals.food += 1
            self?.vitals.joy += 0.3
        }

        Hotkey.register(1, key: kVK_Space) { [weak self] in self?.view.toggleChat() }
        Hotkey.register(2, key: kVK_ANSI_I) { [weak self] in self?.hub.toggle() }

        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.hub.isOpen || self.quiet.active {
                if self.panel.isVisible { self.panel.orderOut(nil) }
                self.followers.hide()
                return
            }
            if !self.panel.isVisible { self.panel.orderFrontRegardless() }
            self.followers.update(leader: self.panel, leaderView: self.view)
        }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.everyMinute() }
    }

    /// Nach dem Ruhe-Modus eine einzige Zusammenfassung statt vieler Blasen.
    private func quietEnded(_ since: Date) {
        let missed = store.inbox.active.filter { !$0.read && $0.updated >= since }
        guard !missed.isEmpty else { return }
        let questions = missed.filter(\.question).count
        var text = missed.count == 1 ? "Eine neue Meldung" : "\(capitalized(numberWord(missed.count, feminine: true))) neue Meldungen"
        if questions > 0 { text += ", davon \(questions == 1 ? "eine Rückfrage" : "\(numberWord(questions, feminine: true)) Rückfragen")" }
        view.showReply(text + ". Doppelklick öffnet die Inbox.", title: "🤫 Ruhe vorbei", seconds: 20)
    }

    private func react(_ kind: Signal.Kind) {
        switch kind {
        case .merged: vitals.joy += 2; view.celebrate()
        case .failed: vitals.joy -= 1
        case .fixed: vitals.joy += 0.5
        case .approved: vitals.joy += 0.5
        case .lost: vitals.joy -= 1
        default: break
        }
    }

    /// Requisite eines Minis aus dem echten Stand: Brief bei Rückfrage, Augen bei Sichtprüfung, Sanduhr bei
    /// laufender Pipeline, Party nach Abnahme oder Merge.
    private func prop(for s: Session) -> Prop {
        if let until = parties[s.id], Date() < until { return .party }
        let items = feedback.items(forSession: s.id)
        if s.mood == .waiting || items.contains(where: { $0.status == .question }) { return .letter }
        if items.contains(where: { $0.status == .implemented || $0.status == .nothingToDo }) { return .eyes }
        if let w = brain.work(forSession: s), w.changes.contains(where: { $0.isOpen && ($0.pipeline == "running" || $0.pipeline == "pending") }) {
            return .hourglass
        }
        return .none
    }

    private func feedbackChanged(_ item: FeedbackItem, _ before: FeedbackItem.Status?) {
        let who = store.sessions[item.sessionID].map { store.name(for: $0.id) }
        switch item.status {
        case .accepted:
            if !item.sessionID.isEmpty { parties[item.sessionID] = Date().addingTimeInterval(120) }
            view.celebrate()
        case .question:
            store.post(Session(id: "fb-\(item.md.lastPathComponent)", mood: .waiting, project: works.topic(forProject: item.project),
                               agent: "Feedback", text: "\(who ?? "Der Agent") fragt zu „\(item.headline)“: \(item.question)",
                               icon: "❓", click: ["-execute", "open -b com.microsoft.VSCode \(shellQuote(item.md.path))"], isAgent: false))
        case .implemented, .nothingToDo:
            let what = item.status == .implemented ? "ist umgesetzt" : "braucht laut Agent keine Änderung"
            store.post(Session(id: "fb-\(item.md.lastPathComponent)", mood: .done, project: works.topic(forProject: item.project),
                               agent: "Feedback", text: "„\(item.headline)“ \(what). Schau's dir an, dann Passt oder Nachbessern (Doppelklick → Inbox).",
                               icon: "👀", click: ["-execute", "open -b com.microsoft.VSCode \(shellQuote(item.md.path))"], isAgent: false))
        default:
            break
        }
    }

    /// Ticket ist in ClickUp erledigt worden: feiern.
    private func ticketsChanged(_ before: [String: Ticket]) {
        for (id, t) in State.shared.data.tickets where t.finished {
            guard let old = before[id], !old.status.isEmpty, !old.finished else { continue }
            view.celebrate()
            for s in store.agents where works.key(forProject: s.project) == id { parties[s.id] = Date().addingTimeInterval(120) }
            store.post(Session(id: "ticket-\(id)", mood: .done, project: t.short.isEmpty ? shorten(t.name) : t.short, agent: "ClickUp",
                               text: "Das Ticket steht jetzt auf \(t.status).", icon: "🎉",
                               click: ["-execute", "open \(shellQuote(t.url))"], isAgent: false))
        }
        brain.refresh()
    }

    /// Hunger, Feierabend-Spruch und Erinnerungen um 9:30, 13:30 und 16:30 an Werktagen (nur wenn
    /// Martin gerade aktiv ist, höchstens einmal pro Slot).
    private func everyMinute() {
        vitals.decay()
        let now = Date()
        let cal = Calendar.current
        let hour = cal.component(.hour, from: now), minute = cal.component(.minute, from: now)
        let weekday = cal.component(.weekday, from: now)
        let active = now.timeIntervalSince(store.lastActivity) < 15 * 60
        let day = ISO8601DateFormatter.string(from: now, timeZone: .current, formatOptions: [.withFullDate])
        let defaults = UserDefaults.standard
        reportNudges(day: day, hour: hour, weekday: weekday, active: active)
        guard active, !quiet.active, view.reply == nil, view.chatField == nil else { return }

        if hour >= 20, defaults.string(forKey: "evening") != day {
            defaults.set(day, forKey: "evening")
            view.yawn = 20
            view.showReply([
                "Feierabend, Martin. Die Bugs sind morgen auch noch da.",
                "Es ist nach acht. Ich streike jetzt, du solltest das auch.",
                "Laptop zu, Beine hoch. Das ist ein Befehl.",
            ].randomElement()!, seconds: 12)
            return
        }
        guard (2...6).contains(weekday) else { return }
        for slot in [(9, 30), (13, 30), (16, 30)] {
            let mins = (hour * 60 + minute) - (slot.0 * 60 + slot.1)
            let key = "nudge-\(day)-\(slot.0)"
            guard (0..<30).contains(mins), !defaults.bool(forKey: key) else { continue }
            defaults.set(true, forKey: key)
            buddy.nudge(situation: view.situation()) { [weak self] text in
                guard let self, let text, self.view.reply == nil, self.view.chatField == nil else { return }
                self.view.showReply(text, title: "📌 Erinnerung", seconds: 25)
            }
        }
    }
}

extension AppDelegate {
    /// Werktags ab 8 Uhr beim ersten Lebenszeichen die Standup-Notiz, ab 18 Uhr der Tagesrückblick mit den Zeiten,
    /// je einmal pro Tag als Meldung, die den Bericht öffnet.
    func reportNudges(day: String, hour: Int, weekday: Int, active: Bool) {
        guard active, (2...6).contains(weekday), let reports = hub.reports else { return }
        let d = UserDefaults.standard
        if hour >= 8, d.string(forKey: "standup") != day {
            d.set(day, forKey: "standup")
            let n = reports.done(on: Reports.previousWorkday()).count
            store.post(Session(id: "report-standup-\(day)", mood: .done, project: "Standup-Notiz", agent: "Bericht",
                               text: n == 0 ? "Die Notiz für heute ist fertig." : "Fertig: \(n) Aufgaben vom letzten Werktag, dazu Plan und Blocker für heute.",
                               icon: "📋", click: ["-hub", "report"], isAgent: false))
        }
        if hour >= 18, d.string(forKey: "review") != day {
            d.set(day, forKey: "review")
            let times = timekeeper.times(Date())
            let total = times.reduce(0) { $0 + $1.seconds }
            guard total >= 1800 else { return }
            store.post(Session(id: "report-review-\(day)", mood: .done, project: "Tagesrückblick", agent: "Bericht",
                               text: "Heute \(duration(total)) an \(times.count) Aufgaben erfasst. Zeiten prüfen und nach ClickUp buchen?",
                               icon: "🕔", click: ["-hub", "report"], isAgent: false))
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
