import AppKit

/// Ein Eintrag in „Was braucht gerade mich?“.
struct Attention {
    enum Who: Int { case you, others, auto }
    var who: Who
    var icon: String
    /// Satzbaustein ohne Punkt: „Fred braucht eine Antwort“.
    var phrase: String
    /// Sammelbegriff für die Zusammenfassung bei others/auto: "pipeline", "agent", "feedback", "review".
    var group = ""
    var workKey: String?
    var feedback: FeedbackItem?
    var session: String?
    var url: String?
    /// Vorbereiteter Auftrag (z. B. Ticketstatus korrigieren), startet erst nach Martins Klick.
    var task: String?
    /// Stabile ID für Widersprüche und verlorene Änderungen, damit sie nur einmal gemeldet werden.
    var id = ""
}

/// Sammelt, was gerade Martins Aufmerksamkeit braucht, wer sonst dran ist und was von allein läuft, und
/// erkennt Widersprüche zwischen Ticket und Code. Rechnet alle 3 s neu (Workspaces höchstens alle 30 s).
final class Brain {
    let store: Store
    let works: Works
    let feedback: FeedbackWatch
    let triage = Triage()
    private(set) var items: [Attention] = []
    private(set) var summary = "Gerade braucht dich nichts."
    private(set) var list: [Work] = []

    init(store: Store, works: Works, feedback: FeedbackWatch) {
        self.store = store
        self.works = works
        self.feedback = feedback
        works.feedback = { [weak feedback] in feedback?.items ?? [] }
        triage.onUpdate = { [weak self] in self?.refresh() }
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        list = works.all()
        items = build()
        triage.update(items.filter { $0.who == .you }, context: context,
                      active: Date().timeIntervalSince(store.lastActivity) < 30 * 60)
        summary = summarize(items)
        announce()
        export()
    }

    func rank(_ a: Attention) -> Triage.Rank { a.who == .you ? triage.rank(a) : .later }

    /// „Du bist dran“ ohne das, was Haiku als Rauschen eingestuft hat.
    var forYou: [Attention] { items.filter { $0.who == .you && rank($0) != .hidden } }

    /// Was Haiku zum Einordnen über die Phrase hinaus wissen sollte.
    private func context(_ a: Attention) -> String {
        var parts: [String] = []
        if let t = a.workKey.flatMap({ work($0)?.ticket }), !t.status.isEmpty { parts.append("Ticket \(t.status)") }
        if let f = a.feedback { parts.append("Feedback geändert \(ago(f.changed))") }
        if let id = a.session, let s = store.sessions[id] { parts.append("Session zuletzt \(ago(s.updated))") }
        return parts.joined(separator: ", ")
    }

    private var exported = ""

    /// Die Liste auch als Datei (attention.json), z. B. für andere Agenten. Schreibt nur bei Änderungen.
    private func export() {
        let who = ["du", "andere", "automatisch"]
        let out: [String: Any] = ["summary": summary,
                                  "items": items.map { ["wer": who[$0.who.rawValue], "text": $0.phrase, "icon": $0.icon, "prio": rank($0).rawValue] }]
        guard let data = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys, .prettyPrinted]),
              let text = String(data: data, encoding: .utf8), text != exported else { return }
        exported = text
        try? data.write(to: buddyDir.appendingPathComponent("attention.json"), options: .atomic)
    }

    func work(forSession s: Session) -> Work? {
        let k = works.key(forProject: s.project)
        return list.first { $0.key == k }
    }

    func work(_ key: String) -> Work? { list.first { $0.key == key } }

    /// Name einer Agent-Session für Sprechblasen und Namensschilder.
    func topic(_ s: Session) -> String {
        s.isAgent ? works.topic(forProject: s.project) : s.label
    }

    // MARK: Liste

    private func build() -> [Attention] {
        var out: [Attention] = []
        let state = State.shared.data

        for s in store.sessions.values where s.isAgent {
            let name = store.name(for: s.id)
            let topic = self.topic(s)
            let k = works.key(forProject: s.project)
            switch s.mood {
            case .waiting:
                out.append(Attention(who: .you, icon: "✋", phrase: "\(name) braucht eine Antwort", workKey: k, session: s.id))
            case .done:
                let what = s.heading.isEmpty ? topic : s.heading
                out.append(Attention(who: .you, icon: "✅", phrase: "\(name) ist fertig mit „\(what)“", group: "done", workKey: k, session: s.id))
            case .working:
                out.append(Attention(who: .auto, icon: "⚙️", phrase: "\(name) arbeitet an „\(topic)“", group: "agent", workKey: k, session: s.id))
            default:
                break
            }
        }

        for f in feedback.items {
            let who = store.sessions[f.sessionID].map { store.name(for: $0.id) } ?? "Der Agent"
            let k = works.key(forProject: f.project)
            switch f.status {
            case .question:
                out.append(Attention(who: .you, icon: "❓", phrase: "\(who) hat eine Rückfrage zu „\(f.headline)“", workKey: k, feedback: f))
            case .implemented, .nothingToDo:
                out.append(Attention(who: .you, icon: "👀", phrase: "„\(f.headline)“ wartet auf deine Sichtprüfung", group: "look", workKey: k, feedback: f))
            case .open, .rework, .answered:
                out.append(Attention(who: .auto, icon: "📸", phrase: "Feedback „\(f.headline)“ wird umgesetzt", group: "feedback", workKey: k, feedback: f))
            case .failed:
                out.append(Attention(who: .you, icon: "💥", phrase: "Das Feedback „\(f.headline)“ ist beim Umsetzen gescheitert", workKey: k, feedback: f))
            case .accepted:
                break
            }
        }

        for c in state.changes.values {
            let topic = works.topic(for: c)
            let k = works.key(for: c)
            func add(_ who: Attention.Who, _ icon: String, _ phrase: String, group: String = "", id: String = "") {
                out.append(Attention(who: who, icon: icon, phrase: phrase, group: group, workKey: k, url: c.url, id: id))
            }
            if c.lost == "lost", (c.mergedAt ?? .distantPast) > Date().addingTimeInterval(-7 * 86400) {
                add(.you, "🕳", "Die \(c.side)-Änderung von „\(topic)“ ist gemergt, fehlt aber im Zielbranch")
            }
            guard c.isOpen else { continue }
            if c.reviewer && !c.mine {
                if !c.draft { add(.you, "👀", "\(capitalized(c.who)) wartet auf dein Review zu „\(topic)“", group: "review") }
                continue
            }
            guard c.mine else { continue }
            if c.pipeline == "failed" {
                if let i = out.firstIndex(where: { $0.icon == "🔴" && $0.workKey == k }) {
                    let sides = [out[i].phrase.replacingOccurrences(of: "^Die (\\S+)-Pipeline.*$", with: "$1", options: .regularExpression), c.side].sorted()
                    out[i].phrase = "Die \(sides[0])- und \(sides[1])-Pipeline von „\(topic)“ sind rot"
                } else {
                    add(.you, "🔴", "Die \(c.side)-Pipeline von „\(topic)“ ist rot")
                }
            }
            else if c.conflict { add(.you, "⚔️", "„\(topic)“ hat im \(c.side) einen Merge-Konflikt") }
            else if c.review == "changes" { add(.you, "✏️", "Am \(c.side) von „\(topic)“ sind Änderungen gewünscht") }
            else if c.open > 0 { add(.you, "💬", "„\(topic)“ hat offene Review-Punkte im \(c.side)") }
            else if c.review == "approved" && c.pipeline == "success" && !c.draft {
                add(.you, "👍", "Das \(c.side) von „\(topic)“ ist freigegeben und kann gemergt werden")
            }
            if c.pipeline == "running" || c.pipeline == "pending" {
                add(.auto, "⏳", "Die \(c.side)-Pipeline von „\(topic)“ läuft", group: "pipeline")
            } else if !c.draft && c.review == "" && c.pipeline != "failed" && !c.conflict && c.open == 0 {
                add(.others, "🕊", "„\(topic)“ wartet im \(c.side) auf ein Review", group: "review")
            }
        }

        out += contradictions()
        var seen = Set<String>()
        out = out.filter { seen.insert("\($0.who)|\($0.phrase)").inserted }
        let rank = ["": 0, "done": 1, "look": 2, "review": 3]
        return out.sorted { ($0.who.rawValue, rank[$0.group] ?? 0) < ($1.who.rawValue, rank[$1.group] ?? 0) }
    }

    /// Ticket und Code passen nicht zusammen.
    private func contradictions() -> [Attention] {
        var out: [Attention] = []
        let recent = Date().addingTimeInterval(-7 * 86400)
        for w in list {
            let open = w.changes.filter { $0.isOpen && $0.mine && !$0.target.hasPrefix("release") }
            if let t = w.ticket, t.finished, !t.name.isEmpty {
                for c in open {
                    out.append(Attention(
                        who: .you, icon: "⚖️",
                        phrase: "„\(w.topic)“ steht in ClickUp auf \(t.status), aber die \(c.side)-Änderung ist noch offen",
                        workKey: w.key, url: c.url,
                        task: """
                        Im ClickUp-Ticket „\(t.name)“ (\(t.url)) steht der Status „\(t.status)“, die \(c.side)-MR \(c.url) ist aber \
                        noch offen. Prüfe kurz, ob die MR noch gebraucht wird. Wenn ja: setze das Ticket auf „code review“ zurück \
                        und kommentiere es mit dem MR-Link. Wenn sie überholt ist: nichts ändern, nur berichten. Fasse am Ende in \
                        zwei Sätzen zusammen, was du getan hast.
                        """,
                        id: "staged-open-\(c.key)"))
                }
                if let ws = w.workspace,
                   let f = feedback.items.first(where: { $0.project == ws.slug && ($0.needsMartin || $0.needsAgent) }) {
                    out.append(Attention(who: .you, icon: "⚖️",
                                         phrase: "„\(w.topic)“ ist in ClickUp \(t.status), aber das Feedback „\(f.headline)“ ist noch offen",
                                         workKey: w.key, feedback: f, id: "staged-feedback-\(w.key)-\(f.md.lastPathComponent)"))
                }
            }
            let merged = w.changes.filter { $0.state == "merged" && ($0.mergedAt ?? .distantPast) > recent && !$0.target.hasPrefix("release") }
            for m in merged {
                guard let o = open.first(where: { $0.side != m.side }) else { continue }
                out.append(Attention(who: .you, icon: "⚖️",
                                     phrase: "Bei „\(w.topic)“ ist das \(m.side) gemergt, das \(o.side) fehlt noch",
                                     workKey: w.key, url: o.url, id: "half-\(m.key)-\(o.key)"))
            }
        }
        return out
    }

    /// Neue Widersprüche und verlorene Änderungen einmal als Meldung zeigen.
    private func announce() {
        var told = State.shared.data.told
        for a in items where !a.id.isEmpty && told[a.id] == nil {
            told[a.id] = Date()
            let click = a.task.map { ["-task", $0] } ?? a.url.map { ["-execute", "open \(shellQuote($0))"] } ?? []
            let topic = a.workKey.flatMap { work($0)?.topic } ?? "Unstimmigkeit"
            store.post(Session(id: "attn-\(a.id)", mood: .waiting, project: topic, agent: "Abgleich",
                               text: a.phrase + "." + (a.task != nil ? " Klick = Ticket-Korrektur vorbereiten." : ""),
                               icon: a.icon, click: click, isAgent: false))
        }
        let cutoff = Date().addingTimeInterval(-14 * 86400)
        told = told.filter { $0.value > cutoff }
        if told != State.shared.data.told {
            State.shared.data.told = told
            State.shared.touch()
        }
    }

    // MARK: Zusammenfassung

    /// „Fred braucht eine Antwort. Zwei Pipelines laufen. Der Rest kann warten.“
    private func summarize(_ items: [Attention]) -> String {
        let you = items.filter { $0.who == .you && rank($0) != .hidden }
        let others = items.filter { $0.who == .others }
        let auto = items.filter { $0.who == .auto }
        var parts: [String] = []
        if let sentence = triage.sentence(for: items.filter { $0.who == .you }) {
            parts.append(sentence)
        } else {
            parts += rulesSummary(you)
        }

        func count(_ group: String, _ one: String, _ many: (String) -> String, feminine: Bool) {
            let n = auto.filter { $0.group == group }.count
            if n == 1 { parts.append(one) } else if n > 1 { parts.append(many(capitalized(numberWord(n, feminine: feminine)))) }
        }
        count("pipeline", "Eine Pipeline läuft.", { "\($0) Pipelines laufen." }, feminine: true)
        count("agent", "Ein Agent arbeitet.", { "\($0) Agenten arbeiten." }, feminine: false)
        count("feedback", "Ein Feedback wird umgesetzt.", { "\($0) Feedbacks werden umgesetzt." }, feminine: false)
        if !others.isEmpty && !you.isEmpty {
            if !parts.joined().contains("Rest kann warten") { parts.append("Der Rest kann warten.") }
        } else if !others.isEmpty { parts.append(others.count == 1 ? "Eine Sache liegt bei anderen." : "\(capitalized(numberWord(others.count, feminine: true))) Sachen liegen bei anderen.") }
        return parts.joined(separator: " ")
    }

    private func rulesSummary(_ you: [Attention]) -> [String] {
        var parts: [String] = []
        let urgent = you.filter { !["done", "review", "look"].contains($0.group) }
        let reviews = you.filter { $0.group == "review" }
        let done = you.filter { $0.group == "done" }
        let looks = you.filter { $0.group == "look" }
        parts += urgent.prefix(2).map { $0.phrase + "." }
        if urgent.count > 2 { parts.append("Dazu \(urgent.count - 2 == 1 ? "ein weiterer Punkt" : "\(numberWord(urgent.count - 2)) weitere Punkte") für dich.") }
        if looks.count == 1 { parts.append(looks[0].phrase + ".") }
        if looks.count > 1 { parts.append("\(capitalized(numberWord(looks.count, feminine: true))) Feedback-Änderungen warten auf deine Sichtprüfung.") }
        if reviews.count == 1 { parts.append(reviews[0].phrase + ".") }
        if reviews.count > 1 { parts.append("\(capitalized(numberWord(reviews.count, feminine: false))) Reviews warten auf dich.") }
        if done.count == 1 { parts.append(done[0].phrase + ".") }
        if done.count > 1 { parts.append("\(capitalized(numberWord(done.count))) Sessions sind fertig.") }
        if you.isEmpty { parts.append("Gerade braucht dich nichts.") }
        return parts
    }
}
