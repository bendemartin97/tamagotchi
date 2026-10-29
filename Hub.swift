import AppKit
import SwiftUI

/// Overview opened by double-clicking the pet: live status of all agents and MRs, inbox (up next, can wait, read, snoozed, done),
/// tasks and MRs/PRs, each with their actions. Arrow keys select, Enter runs the primary action,
/// Space expands, E marks done, ⌘Z undoes the last action.
final class Hub: ObservableObject {
    enum Tab: String, CaseIterable { case live = "Live", inbox = "Inbox", works = "Aufgaben", changes = "MRs", report = "Bericht" }
    enum Filter: String, CaseIterable { case all = "Alle", questions = "Rückfragen", reviews = "Reviews", errors = "Fehler" }
    enum Compose { case answer(FeedbackItem), rework(FeedbackItem) }

    let store: Store
    let brain: Brain
    let tasks: TaskRunner
    /// Click target of a notification, as from the speech bubble (PetView.open): mark as read, run the target.
    var open: (Message) -> Void = { _ in }
    var celebrate: () -> Void = {}
    /// An agent's prop, as with the mini (letter, hourglass, eyes, party).
    var prop: (Session) -> Prop = { _ in .none }
    @Published var tab = Tab.inbox
    @Published var filter = Filter.all
    @Published var search = ""
    @Published var expanded: Set<String> = []
    @Published var selected: String?
    @Published var showArchive = false
    /// Agent selected in the sidebar: its agent view appears instead of the tabs.
    @Published var agentFilter: String?
    @Published var agentTab = AgentTab.overview
    let logs = SessionLogs()
    let git = GitStates()
    let ci = CIDetails()
    var reports: Reports?
    /// Anomalies per agent, reported by the watchdog.
    var problems: (String) -> [Problem] = { _ in [] }
    @Published var compose: [String: Compose] = [:]
    @Published var drafts: [String: String] = [:]
    @Published private(set) var tick = 0
    let peeker = Peeker()
    private var window: NSWindow?
    private var timer: Timer?

    init(store: Store, brain: Brain, tasks: TaskRunner) {
        self.store = store
        self.brain = brain
        self.tasks = tasks
        logs.onUpdate = { [weak self] in self?.refresh() }
        git.onUpdate = { [weak self] in self?.refresh() }
        ci.onUpdate = { [weak self] in self?.refresh() }
    }

    var inbox: Inbox { store.inbox }

    func toggle() {
        if isOpen { window?.close() } else { show() }
    }

    func show(_ tab: Tab? = nil) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 780),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Tamagotchi"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.level = .floating
            w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            w.contentView = NSHostingView(rootView: HubView(hub: self))
            w.center()
            w.setFrameAutosaveName("TamagotchiHub2")
            window = w
        }
        self.tab = tab ?? (sections.first?.title == "Jetzt dran" ? .inbox : .live)
        if tab != nil { agentFilter = nil }
        selected = flat.first?.id
        brain.refresh()
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            guard let self, self.window?.isVisible == true else { t.invalidate(); return }
            self.refresh()
        }
    }

    func refresh() { tick += 1 }

    /// While the overview is open, the pets stay off the desktop.
    var isOpen: Bool { window?.isVisible == true && window?.isMiniaturized == false }

    func act(_ run: () -> Void) {
        run()
        brain.refresh()
        refresh()
    }

    // MARK: Inbox

    func matches(_ m: Message) -> Bool {
        switch filter {
        case .all: break
        case .questions: guard m.question || ["✋", "❓"].contains(m.symbol) else { return false }
        case .reviews: guard ["👀", "🕊"].contains(m.symbol) || m.text.contains("Review") else { return false }
        case .errors: guard ["🔴", "💥", "🕳", "⚔️"].contains(m.symbol) else { return false }
        }
        return matches([brain.title(m), m.text, m.agent, m.project, store.sessions[m.id]?.heading ?? ""])
    }

    func matches(_ fields: [String]) -> Bool {
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || fields.contains { $0.localizedCaseInsensitiveContains(q) }
    }

    var sections: [(title: String, items: [Message])] {
        let list = inbox.active.filter(matches)
        func order(_ a: Message, _ b: Message) -> Bool {
            if a.pinned != b.pinned { return a.pinned }
            if a.question != b.question { return a.question }
            return a.updated > b.updated
        }
        let now = list.filter { $0.pinned || !$0.read && brain.rank($0).rank == .now }.sorted(by: order)
        let ids = Set(now.map(\.id))
        let later = list.filter { !$0.read && !ids.contains($0.id) }.sorted(by: order)
        let read = list.filter { $0.read && !ids.contains($0.id) }
        var out = [("Jetzt dran", now), ("Kann warten", later), ("Gelesen", read), ("Zurückgestellt", inbox.snoozed.filter(matches))]
        if showArchive { out.append(("Erledigt (14 Tage)", inbox.archived.filter(matches))) }
        return out.filter { !$0.1.isEmpty }
    }

    var flat: [Message] { sections.flatMap(\.items) }

    func move(_ step: Int) {
        let list = flat
        guard !list.isEmpty else { return }
        let i = list.firstIndex { $0.id == selected } ?? (step > 0 ? -1 : list.count)
        selected = list[max(0, min(list.count - 1, i + step))].id
    }

    func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        selected = id
    }

    /// Primary action with an unambiguous label for each kind of notification.
    func primary(_ m: Message) -> (String, () -> Void)? {
        if let f = brain.feedbackItem(m) {
            if f.status == .question { return ("Antworten", { [self] in startCompose(m.id, .answer(f)) }) }
            return ("Ansehen", { [self] in brain.feedback.view(f); inbox.markRead(m.id) })
        }
        if m.click.first == "-hub" { return ("Bericht öffnen", { [self] in inbox.markRead(m.id); agentFilter = nil; tab = .report }) }
        if m.click.first == "-task", m.click.count == 2 {
            return ("Korrektur starten", { [self] in tasks.start(m.click[1]); inbox.markRead(m.id) })
        }
        guard !m.click.isEmpty else { return nil }
        let label: String
        if m.isAgent || m.id.hasPrefix("warn-") { label = m.project.hasPrefix("🛠") ? "Ergebnis öffnen" : "Zur Session" }
        else if m.id.hasPrefix("ticket-") { label = "Ticket öffnen" }
        else if m.id.hasPrefix("work-") {
            label = ["🔴": "Pipeline öffnen", "💬": "Kommentare öffnen", "✏️": "Kommentare öffnen", "👀": "Review öffnen",
                     "⚔️": "Konflikt ansehen", "🕳": "Änderung prüfen"][m.symbol] ?? "MR öffnen"
        } else { label = "Öffnen" }
        return (label, { [self] in open(m) })
    }

    func startCompose(_ id: String, _ c: Compose) {
        compose[id] = c
        expanded.insert(id)
        selected = id
    }

    func send(_ m: Message) {
        let text = (drafts[m.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let c = compose[m.id] else { return }
        switch c {
        case .answer(let f): brain.feedback.answer(f, text: text)
        case .rework(let f): brain.feedback.rework(f, text: text)
        }
        compose[m.id] = nil
        drafts[m.id] = nil
        inbox.markRead(m.id)
        act {}
    }

    /// Feedback items that belong to a notification and need Martin.
    func feedback(for m: Message) -> [FeedbackItem] {
        if let f = brain.feedbackItem(m) { return f.needsMartin ? [f] : [] }
        return m.isAgent ? brain.feedback.items(forSession: m.id).filter(\.needsMartin) : []
    }

    // MARK: Tasks and MRs

    var works: [Work] {
        brain.list.filter { w in matches([w.topic, w.ticket?.name ?? "", w.workspace?.slug ?? ""] + w.changes.map(\.title)) }
    }

    var changes: [Change] {
        State.shared.data.changes.values
            .filter { $0.isOpen && ($0.mine || $0.reviewer) }
            .filter { matches([brain.works.topic(for: $0), $0.title, $0.repo, $0.who, $0.branch]) }
            .sorted { a, b in
                if a.mine != b.mine { return a.mine }
                return (brain.works.topic(for: a), a.side) < (brain.works.topic(for: b), b.side)
            }
    }
}

/// A notification: header row with primary action, Done and menu; when expanded, shows the reasoning, feedback actions,
/// reply field, task links and history. Used in the inbox and in the agent view.
struct MessageRow: View {
    @ObservedObject var hub: Hub
    let m: Message
    var onTap: () -> Void = {}
    @FocusState private var composeFocus: String?

    var body: some View {
        let open = hub.expanded.contains(m.id)
        let rank = hub.brain.rank(m)
        let session = hub.store.sessions[m.id]
        var meta = [ago(m.updated)]
        if let s = session { meta.append(["working": "arbeitet", "waiting": "wartet", "done": "fertig"][s.mood.rawValue] ?? "") }
        if m.events.count > 1 { meta.append("\(m.events.count) Ereignisse") }
        if m.pinned { meta.append("📌") }
        if let until = m.snoozed, until > Date() { meta.append("⏰ \(until.formatted(date: .abbreviated, time: .shortened))") }
        if let a = m.archived { meta.append("erledigt \(ago(a))") }

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: open ? "chevron.down" : "chevron.right")
                    .font(.caption2).foregroundStyle(.tertiary).frame(width: 10).padding(.top, 5)
                Text(m.symbol).font(.title3).frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(hub.brain.title(m)).font(.headline.weight(m.read ? .regular : .semibold)).lineLimit(open ? nil : 1)
                    if let h = session?.heading, !h.isEmpty, open { Text(h).font(.caption).foregroundStyle(.secondary) }
                    Text(m.text).font(.callout).foregroundStyle(.secondary).lineLimit(open ? nil : 2)
                        .textSelection(.enabled)
                    Text(meta.filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer(minLength: 6)
                HStack(spacing: 6) {
                    if let p = hub.primary(m) { Button(p.0) { hub.act(p.1) } }
                    if m.archived == nil {
                        Button { hub.act { hub.inbox.archive(m.id) } } label: { Image(systemName: "checkmark") }
                            .help("Erledigt (E)")
                    } else {
                        Button("Zurückholen") { hub.act { hub.inbox.restore(m.id) } }
                    }
                    more(m)
                }
                .controlSize(.small)
            }
            if open { detail(m, why: rank.why) }
        }
        .card(hub.selected == m.id ? .accentColor : !m.read && m.question ? .orange : nil, padding: 12)
        .opacity(m.read && hub.selected != m.id ? 0.85 : 1)
        .contentShape(Rectangle())
        .onTapGesture { hub.toggle(m.id); onTap() }
    }

    private func more(_ m: Message) -> some View {
        Menu {
            Button(m.read ? "Als ungelesen markieren" : "Als gelesen markieren") { hub.act { hub.inbox.markRead(m.id, !m.read) } }
            Button(m.pinned ? "Lösen" : "Anheften") { hub.act { hub.inbox.pin(m.id, !m.pinned) } }
            Menu("Wiedervorlage") {
                Button("In 30 Minuten") { hub.act { hub.inbox.snooze(m.id, until: Date().addingTimeInterval(1800)) } }
                Button("In 2 Stunden") { hub.act { hub.inbox.snooze(m.id, until: Date().addingTimeInterval(7200)) } }
                Button("Morgen früh") { hub.act { hub.inbox.snooze(m.id, until: nextMorning()) } }
            }
            Menu("Einstufung") {
                Button("Jetzt dran") { hub.act { hub.inbox.prioritize(m.id, .now) } }
                Button("Kann warten") { hub.act { hub.inbox.prioritize(m.id, .later) } }
                Button("Automatisch") { hub.act { hub.inbox.prioritize(m.id, nil) } }
            }
            Divider()
            Button("Warum ist das hier?") { hub.expanded.insert(m.id); hub.selected = m.id }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func detail(_ m: Message, why: String) -> some View {
        let work = hub.brain.work(hub.brain.workKey(m))
        let links = work.map { hub.brain.works.actions(for: $0) } ?? []
        return VStack(alignment: .leading, spacing: 10) {
            Label(why, systemImage: "questionmark.circle").font(.caption).foregroundStyle(.secondary)

            ForEach(hub.feedback(for: m), id: \.md) { f in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(f.status == .question ? "❓" : "👀") \(f.headline)").font(.subheadline.weight(.semibold))
                    if f.status == .question && !f.question.isEmpty {
                        Text(f.question).font(.callout).textSelection(.enabled)
                    }
                    Flow {
                        if f.status == .question { Button("Antworten") { hub.startCompose(m.id, .answer(f)); composeFocus = m.id } }
                        Button("Ansehen") { hub.act { hub.brain.feedback.view(f) } }
                        if f.status != .question {
                            Button("Passt") { hub.act { hub.brain.feedback.accept(f); hub.inbox.archive(m.id) }; hub.celebrate() }
                            Button("Nachbessern") { hub.startCompose(m.id, .rework(f)); composeFocus = m.id }
                        }
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            }

            if let c = hub.compose[m.id] {
                HStack {
                    TextField(composeHint(c), text: Binding(get: { hub.drafts[m.id] ?? "" }, set: { hub.drafts[m.id] = $0 }), axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...5)
                        .focused($composeFocus, equals: m.id)
                        .onSubmit { hub.send(m) }
                    Button("Senden") { hub.send(m) }
                    Button("Abbrechen") { hub.compose[m.id] = nil }
                }
            }

            ForEach((work?.changes ?? []).filter { $0.isOpen && $0.mine && $0.needsHelp }, id: \.key) { c in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(c.side): \(cleanTitle(c.title))").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ChangeExtras(hub: hub, change: c)
                }
            }

            if !links.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(work?.topic ?? "Aufgabe").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Flow {
                        ForEach(Array(links.enumerated()), id: \.offset) { _, a in
                            Button(a.0) { hub.act(a.1) }
                        }
                    }
                }
            }

            if !m.events.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Verlauf").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(Array(m.events.reversed().enumerated()), id: \.offset) { _, e in
                        HStack(alignment: .top, spacing: 6) {
                            Text(e.at.formatted(date: .omitted, time: .shortened)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                            Text(e.icon).font(.caption)
                            Text(e.text).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .controlSize(.small)
        .padding(.leading, 42)
    }

    private func composeHint(_ c: Hub.Compose) -> String {
        if case .answer = c { return "Antwort an den Agenten …" }
        return "Was soll nachgebessert werden?"
    }

}

struct HubView: View {
    @ObservedObject var hub: Hub
    @FocusState private var listFocus: Bool

    var body: some View {
        let _ = hub.tick
        HStack(spacing: 0) {
            AgentSidebar(hub: hub)
                .background(VisualEffect(material: .sidebar))
            Divider()
            main
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .ignoresSafeArea()
        .frame(minWidth: 780, minHeight: 480)
        .onAppear { listFocus = true }
    }

    @ViewBuilder private var main: some View {
        if let id = hub.agentFilter, let s = hub.store.sessions[id] {
            AgentDetailView(hub: hub, session: s)
        } else {
            overview
        }
    }

    private var overview: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch hub.tab {
            case .live: LiveView(hub: hub)
            case .inbox: inbox
            case .works: works
            case .changes: changes
            case .report: ReportView(hub: hub)
            }
            Divider()
            footer
        }
    }

    private var header: some View {
        let waiting = hub.store.agents.contains { $0.mood == .waiting }
        let now = hub.sections.first?.title == "Jetzt dran"
        let red = hub.changes.contains { $0.mine && $0.pipeline == "failed" }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 4) {
                TabChip(icon: "waveform.path.ecg", title: "Live", count: hub.store.agents.count, alert: waiting, selected: hub.tab == .live) { hub.tab = .live }
                TabChip(icon: "tray.full", title: "Inbox", count: hub.inbox.unreadCount, alert: now, selected: hub.tab == .inbox) { hub.tab = .inbox }
                TabChip(icon: "square.stack.3d.up", title: "Aufgaben", count: hub.brain.list.count, selected: hub.tab == .works) { hub.tab = .works }
                TabChip(icon: "arrow.triangle.pull", title: "MRs", count: hub.changes.count, alert: red, selected: hub.tab == .changes) { hub.tab = .changes }
                TabChip(icon: "doc.text", title: "Bericht", selected: hub.tab == .report) { hub.tab = .report }
                Spacer(minLength: 12)
                SearchField(prompt: "Suchen …", text: $hub.search) { listFocus = true }
                    .frame(maxWidth: 240)
            }
            if hub.tab == .inbox {
                HStack(spacing: 6) {
                    ForEach(Hub.Filter.allCases, id: \.self) { f in
                        FilterChip(title: f.rawValue, selected: hub.filter == f) { hub.filter = f }
                    }
                }
            }
            if hub.tab == .inbox || hub.tab == .live {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
                    Text(hub.brain.summary).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                .card(.accentColor, padding: 10, radius: 10)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(State.shared.checkedLine).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            Spacer()
            if hub.tab == .inbox {
                if let u = hub.inbox.undo {
                    Text(u.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Button("Rückgängig") { hub.act { hub.inbox.undoLast() } }
                        .keyboardShortcut("z", modifiers: .command)
                }
                Toggle("Erledigte", isOn: $hub.showArchive).toggleStyle(.checkbox)
                Button("Alle erledigt") { hub.act { hub.inbox.archiveAll(hub.inbox.active.filter(hub.matches).map(\.id)) } }
                    .disabled(hub.inbox.active.isEmpty)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.03))
    }

    // MARK: Inbox

    private var inbox: some View {
        let sections = hub.sections
        return Group {
            if sections.isEmpty {
                empty(hub.search.isEmpty && hub.filter == .all ? "Inbox ist leer." : "Nichts gefunden.")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8, pinnedViews: [.sectionHeaders]) {
                            ForEach(sections, id: \.title) { section in
                                Section {
                                    ForEach(section.items, id: \.id) { m in
                                        MessageRow(hub: hub, m: m) { listFocus = true }.id(m.id)
                                    }
                                } header: {
                                    SectionTitle(title: section.title, count: section.items.count)
                                        .padding(.top, 8).padding(.bottom, 4)
                                        .background(Color(nsColor: .windowBackgroundColor))
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                    }
                    .focusable()
                    .focusEffectDisabled()
                    .focused($listFocus)
                    .onKeyPress(.downArrow) { hub.move(1); return .handled }
                    .onKeyPress(.upArrow) { hub.move(-1); return .handled }
                    .onKeyPress(.space) {
                        if let id = hub.selected { hub.toggle(id) }
                        return .handled
                    }
                    .onKeyPress(.return) {
                        if let m = hub.flat.first(where: { $0.id == hub.selected }), let p = hub.primary(m) { hub.act(p.1) }
                        return .handled
                    }
                    .onKeyPress("e") {
                        if let id = hub.selected { hub.move(1); hub.act { hub.inbox.archive(id) } }
                        return .handled
                    }
                    .onChange(of: hub.selected) { _, id in
                        if let id { withAnimation { proxy.scrollTo(id) } }
                    }
                }
            }
        }
    }

    // MARK: Tasks

    private var works: some View {
        list(hub.works, id: \.key, empty: "Keine laufenden Aufgaben.") { w in
            let actions = hub.brain.works.actions(for: w)
            Row(icon: workIcon(w),
                title: w.topic,
                subtitle: w.changes.sorted { $0.side < $1.side }.map(changeLine).joined(separator: "   "),
                meta: [w.ticket.map { $0.status.isEmpty ? "" : "Ticket \($0.status)" } ?? "", w.workspace.map { "ws \($0.slug)" } ?? ""]
                    .filter { !$0.isEmpty }.joined(separator: " · ")) {
                if let first = actions.first { Button(first.0) { hub.act(first.1) } }
                if actions.count > 1 {
                    Menu("Mehr") {
                        ForEach(Array(actions.dropFirst().enumerated()), id: \.offset) { _, a in
                            Button(a.0) { hub.act(a.1) }
                        }
                    }
                    .fixedSize()
                }
            }
        }
    }

    private func workIcon(_ w: Work) -> String {
        if w.changes.contains(where: { $0.isOpen && $0.pipeline == "failed" }) { return "🔴" }
        if w.changes.contains(where: { $0.isOpen && $0.conflict }) { return "⚔️" }
        if hub.store.agents.contains(where: { hub.brain.works.key(forProject: $0.project) == w.key }) { return "⚙️" }
        if w.ticket?.finished == true { return "🎉" }
        return w.changes.isEmpty ? "🗂" : "📦"
    }

    private func changeLine(_ c: Change) -> String {
        guard c.isOpen else { return "\(c.side) gemergt" }
        let state = ["failed": "rot", "success": "grün", "running": "läuft", "pending": "wartet"][c.pipeline] ?? "offen"
        return "\(c.side) \(state)\(c.draft ? " (Draft)" : "")"
    }

    // MARK: MRs

    private var changes: some View {
        list(hub.changes, id: \.key, empty: "Keine offenen MRs oder PRs.") { c in
            let work = hub.brain.work(hub.brain.works.key(for: c))
            let actions = work.map { hub.brain.works.actions(for: $0) }?.filter { !$0.0.contains("-Änderung ansehen") } ?? []
            VStack(alignment: .leading, spacing: 0) {
            Row(icon: pipelineIcon(c),
                title: "\(hub.brain.works.topic(for: c)) · \(c.side)",
                subtitle: cleanTitle(c.title),
                meta: chips(c).joined(separator: " · ")) {
                Button(c.pipeline == "failed" ? "Pipeline öffnen" : "Öffnen") {
                    openURL(c.pipeline == "failed" ? c.url + (c.host == "github" ? "/checks" : "/pipelines") : c.url)
                }
                Menu("Mehr") {
                    if c.pipeline == "failed" { Button("MR öffnen") { openURL(c.url) } }
                    Button("Branch kopieren") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(c.branch, forType: .string)
                    }
                    if !actions.isEmpty { Divider() }
                    ForEach(Array(actions.enumerated()), id: \.offset) { _, a in
                        Button(a.0) { hub.act(a.1) }
                    }
                }
                .fixedSize()
            }
            if c.needsHelp { ChangeExtras(hub: hub, change: c).padding(.leading, 48).padding(.trailing, 12).padding(.bottom, 9) }
            }
        }
    }

    private func pipelineIcon(_ c: Change) -> String {
        if c.conflict { return "⚔️" }
        switch c.pipeline {
        case "failed": return "🔴"
        case "running", "pending": return "⏳"
        case "success": return c.review == "approved" ? "👍" : "🟢"
        default: return "⚪️"
        }
    }

    private func chips(_ c: Change) -> [String] {
        var out = ["\(c.repo) \(c.host == "github" ? "#" : "!")\(c.number)"]
        if !c.mine { out.append("Review für \(capitalized(c.who))") }
        if c.draft { out.append("Draft") }
        if c.conflict { out.append("Konflikt") }
        if c.review == "changes" { out.append("Änderungen gewünscht") }
        if c.review == "approved" { out.append("freigegeben") }
        if c.open > 0 { out.append("\(c.open) offene Punkte") }
        return out
    }

    // MARK: Building blocks

    private func empty(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func list<T, Content: View>(_ items: [T], id: KeyPath<T, String>, empty text: String,
                                        @ViewBuilder row: @escaping (T) -> Content) -> some View {
        Group {
            if items.isEmpty {
                empty(text)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(items, id: id) { item in
                            row(item).card(padding: 0)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
        }
    }
}

/// One row: icon, title, text, meta line and the actions on the right.
struct Row<Actions: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    let meta: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(icon).font(.title3).frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline).lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                }
                if !meta.isEmpty {
                    Text(meta).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) { actions() }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }
}

/// Wraps buttons onto multiple lines when they don't fit side by side.
struct Flow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 480
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += row + spacing; row = 0 }
            x += s.width + spacing
            row = max(row, s.height)
        }
        return CGSize(width: width, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            row = max(row, s.height)
        }
    }
}

extension Change {
    /// Red pipeline or open review items: then there is error output or „an Agent geben“ (hand to agent).
    var needsHelp: Bool { isOpen && (pipeline == "failed" || open > 0 || review == "changes") }
}

/// For a red pipeline: expand the error output and „Fix auftragen“ (assign fix); for open review items: „Kommentare an
/// Agent geben“ (hand comments to agent). Both start a Claude job in the branch's workspace, without commit and push.
struct ChangeExtras: View {
    @ObservedObject var hub: Hub
    let change: Change
    @SwiftUI.State private var sending = false

    init(hub: Hub, change: Change) {
        self.hub = hub
        self.change = change
    }

    var body: some View {
        let c = change
        let key = "ci-\(c.key)"
        let open = hub.expanded.contains(key)
        let dir = CIDetails.checkout(c, in: hub.brain.work(hub.brain.works.key(for: c)))
        let failure = open && c.pipeline == "failed" ? hub.ci.failure(c) : nil
        VStack(alignment: .leading, spacing: 6) {
            Flow {
                if c.pipeline == "failed" {
                    Button(open ? "Fehler ausblenden" : "Fehler ansehen") {
                        if open { hub.expanded.remove(key) } else { hub.expanded.insert(key) }
                    }
                    if let f = failure, !f.job.isEmpty {
                        Button("Fix auftragen") { hub.act { hub.tasks.start(CIDetails.fixPrompt(c, f, dir: dir)) } }
                            .help(dir.map { "Claude arbeitet in \($0), ohne Commit und Push" } ?? "Kein Workspace: Claude analysiert nur")
                    }
                }
                if c.open > 0 || c.review == "changes" {
                    Button(sending ? "Hole Kommentare …" : "Kommentare an Agent geben") { send(c, dir: dir) }
                        .disabled(sending)
                }
            }
            if open && c.pipeline == "failed" {
                if let f = failure {
                    if !f.job.isEmpty { Text("\(f.job)\(f.stage.isEmpty ? "" : " · \(f.stage)")").font(.caption.weight(.semibold)) }
                    ScrollView {
                        Text(f.tail).font(.caption2.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                    Button("Job öffnen") { openURL(f.url) }
                } else {
                    ProgressView("Hole Job-Log …").controlSize(.small)
                }
            }
        }
        .controlSize(.small)
    }

    private func send(_ c: Change, dir: String?) {
        sending = true
        DispatchQueue.global(qos: .userInitiated).async {
            let comments = hub.ci.openComments(c)
            DispatchQueue.main.async {
                sending = false
                if comments.isEmpty {
                    hub.store.post(Session(id: "info-\(c.key)", mood: .done, project: hub.brain.works.topic(for: c), agent: "Kommentare",
                                           text: "An der \(c.side)-Änderung sind keine offenen Kommentare anderer zu finden.", icon: "💬", isAgent: false))
                } else {
                    hub.tasks.start(CIDetails.commentsPrompt(c, comments, dir: dir))
                }
                hub.refresh()
            }
        }
    }
}
