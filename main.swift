// Desktop-Tamagotchi für Claude Code / Codex.
// Liest ~/.claude/tamagotchi/events.jsonl (geschrieben von ~/.claude/hooks/pet.sh und notify.sh),
// beobachtet Martins MRs/PRs auf GitLab und GitHub, verknüpft sie mit ClickUp-Tickets und Workspaces, sagt,
// was gerade Martins Aufmerksamkeit braucht, chattet über `claude -p` und gibt Aufträge an Claude Code weiter.
// Klick: öffnet die dringendste Meldung, sonst den Chat (auch ⌃⌥Leertaste). Ziehen: verschieben.
// Rechtsklick: Menü. Jede Agent-Session bekommt ein Mini-Haustier, das hinterherläuft.

import AppKit
import Carbon

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Globales Tastenkürzel ⌃⌥Leertaste über Carbon (braucht keine Bedienungshilfen-Freigabe).
enum Hotkey {
    static var handler: (() -> Void)?
    private static var ref: EventHotKeyRef?

    static func register() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            Hotkey.handler?()
            return noErr
        }, 1, &spec, nil, nil)
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey),
                            EventHotKeyID(signature: OSType(0x5441_4D41), id: 1), GetApplicationEventTarget(), 0, &ref)
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

        Hotkey.handler = { [weak self] in self?.view.toggleChat() }
        Hotkey.register()

        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.followers.update(leader: self.panel, leaderView: self.view)
        }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.everyMinute() }
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
                               agent: "Feedback", text: "„\(item.headline)“ \(what). Schau's dir an: Rechtsklick auf \(who ?? "das Mini") → Passt oder Nachbessern.",
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
        guard active, view.reply == nil, view.chatField == nil else { return }

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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
