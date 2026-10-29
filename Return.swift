import AppKit

/// Remembers per workspace what happened last and summarizes it when you return (the workspace's VS Code window
/// comes to the front again or a new session starts in it, after a break of at least 2 hours) in two or three sentences.
final class Returns {
    let store: Store
    let brain: Brain
    var onSummary: ((_ topic: String, _ text: String) -> Void)?
    private var busy: Set<String> = []

    init(store: Store, brain: Brain) {
        self.store = store
        self.brain = brain
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.watchFront() }
    }

    /// After each completed turn: record the heading, last prompt and last reply for the workspace.
    func record(_ s: Session) {
        guard s.isAgent, brain.works.workspaces[s.project] != nil else { return }
        let tail = s.transcript.isEmpty ? nil : transcriptTail(s.transcript)
        var t = State.shared.data.trails[s.project] ?? Trail()
        t.heading = s.heading
        t.prompt = tail?.prompts.last ?? t.prompt
        t.answer = tail?.answer ?? t.answer
        t.at = Date()
        t.session = s.id
        t.root = s.root
        t.transcript = s.transcript
        State.shared.data.trails[s.project] = t
        State.shared.touch()
    }

    /// Activity in a workspace; after a long break, the summary is shown.
    func seen(_ slug: String) {
        guard brain.works.workspaces[slug] != nil else { return }
        let last = State.shared.data.lastSeen[slug]
        if let last, Date().timeIntervalSince(last) < 60 { return }
        State.shared.data.lastSeen[slug] = Date()
        State.shared.touch()
        guard let last, Date().timeIntervalSince(last) > 2 * 3600, State.shared.data.trails[slug] != nil else { return }
        summarize(slug, since: last)
    }

    private func watchFront() {
        guard let title = frontWindowTitle(), !title.isEmpty else { return }
        if let slug = brain.works.workspaces.keys.first(where: { title.contains($0) }) { seen(slug) }
    }

    private func summarize(_ slug: String, since: Date) {
        guard !busy.contains(slug), let trail = State.shared.data.trails[slug] else { return }
        busy.insert(slug)
        let key = brain.works.key(forProject: slug)
        let work = brain.work(key)
        let topic = brain.works.topic(forProject: slug)
        var facts = ["Zuletzt aktiv: \(ago(trail.at))"]
        if !trail.heading.isEmpty { facts.append("Session-Überschrift: \(trail.heading)") }
        if !trail.prompt.isEmpty { facts.append("Martins letzte Nachricht: \(trail.prompt)") }
        if !trail.answer.isEmpty { facts.append("Letzte Antwort des Agenten: \(trail.answer)") }
        for a in brain.items where a.workKey == key { facts.append("Offen: \(a.phrase)") }
        for f in brain.feedback.items where f.project == slug && f.status == .question {
            facts.append("Rückfrage des Agenten zum Feedback „\(f.headline)“: \(f.question)")
        }
        if let t = work?.ticket, !t.name.isEmpty { facts.append("Ticket: \(t.name), Status \(t.status)") }
        if let auftrag = try? String(contentsOf: workspacesDir.appendingPathComponent(slug).appendingPathComponent("auftrag.md"), encoding: .utf8) {
            facts.append("Auftrag (Anfang):\n" + auftrag.prefix(1500))
        }
        let prompt = """
        Martin kehrt nach einer Pause zu einer Aufgabe zurück. Fasse in zwei bis drei kurzen Sätzen auf Deutsch zusammen, \
        wo er steht, im Stil: „Zuletzt hast du die Validierung angepasst. Der Agent wartet auf deine Entscheidung zum \
        leeren Zustand. Danach fehlt noch die mobile Ansicht.“ Du-Form, keine Ticket-IDs, MR-Nummern, Dateinamen oder \
        Branch-Namen, nichts erfinden. Antworte nur mit den Sätzen.

        \(facts.joined(separator: "\n"))
        """
        DispatchQueue.global(qos: .utility).async {
            let r = runClaude(["-p", "--setting-sources", "", "--strict-mcp-config", "--model", "claude-haiku-5-5",
                               "--tools", "", "--no-session-persistence", "--output-format", "json"], input: prompt, cwd: buddyDir)
            let text = r.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            DispatchQueue.main.async {
                self.busy.remove(slug)
                if r.ok && !text.isEmpty { self.onSummary?(topic, text) }
            }
        }
    }
}

/// Title of the active app's frontmost window (requires screen recording permission).
func frontWindowTitle() -> String? {
    guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
          let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    else { return nil }
    return list.first { $0[kCGWindowOwnerPID as String] as? pid_t == pid && $0[kCGWindowLayer as String] as? Int == 0 }?[kCGWindowName as String] as? String
}
