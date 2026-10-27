import Foundation

/// Holt Name und Status der verknüpften ClickUp-Tickets über `claude -p` mit dem ClickUp-MCP (Haiku, ~1 Cent pro
/// Abfrage, kein eigenes API-Token nötig) und gibt jedem Ticket einen kurzen deutschen Namen. Im selben Lauf bekommen
/// MR-Titel ohne Ticket einen Namen. Nur bei Aktivität, jedes Ticket höchstens alle 20 Minuten.
final class ClickUpWatch {
    let store: Store
    let works: Works
    var onUpdate: ((_ before: [String: Ticket]) -> Void)?
    private var running = false
    private var lastRun = Date.distantPast

    init(store: Store, works: Works) {
        self.store = store
        self.works = works
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.poll() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { self.poll() }
    }

    func poll() {
        guard !running, Date().timeIntervalSince(lastRun) > 90,
              Date().timeIntervalSince(store.lastActivity) < 30 * 60 else { return }
        let state = State.shared.data
        let all = works.all()
        let due = all.compactMap(\.ticketID).filter { id in
            guard let t = state.tickets[id] else { return true }
            let age = Date().timeIntervalSince(t.checked)
            return age > 20 * 60 || (t.short.isEmpty && !t.name.isEmpty && age > 3 * 60)
        }
        let titles = all.filter { $0.ticketID == nil }.flatMap(\.changes).map(\.title).filter { state.names[$0] == nil }
        guard !due.isEmpty || !titles.isEmpty else { return }
        running = true
        lastRun = Date()
        let ids = Array(Set(due)).prefix(15)
        let names = Array(Set(titles)).prefix(15)
        DispatchQueue.global(qos: .utility).async {
            let result = self.ask(ids: Array(ids), titles: Array(names))
            DispatchQueue.main.async {
                self.running = false
                guard let result else { return }
                let before = State.shared.data.tickets
                for var t in result.tickets {
                    if t.short.isEmpty { t.short = before[t.id]?.short ?? "" }
                    State.shared.data.tickets[t.id] = t
                }
                for (title, name) in result.names { State.shared.data.names[title] = name }
                if !ids.isEmpty { State.shared.checked("clickup") } else { State.shared.touch() }
                self.onUpdate?(before)
                self.store.onChange?()
            }
        }
    }

    private func ask(ids: [String], titles: [String]) -> (tickets: [Ticket], names: [String: String])? {
        let known = State.shared.data.tickets
        let list = ids.map { id in known[id].map { "\(id) (bisheriger Kurzname: \($0.short))" } ?? id }
        let prompt = """
        \(ids.isEmpty ? "" : "Rufe für jede dieser ClickUp-Task-IDs clickup_get_task auf: \(list.joined(separator: ", ")).")
        Antworte danach nur mit JSON, ohne Codeblock:
        {"tickets": [{"id": "<id>", "name": "<Taskname>", "status": "<Status klein>", "kurz": "<Kurzname>"}], "namen": {"<Titel>": "<Kurzname>"}}
        Kurzname: 2 bis 4 Wörter auf Deutsch, worum es fachlich geht, für eine Sprechblase (z. B. „Kalender grau bei \
        Zeitplänen“, „Stornonotiz im Shop“, „Refund bei Dispute“). Keine IDs, Nummern, Repo-Namen oder Anführungszeichen. \
        Gibt es einen bisherigen Kurznamen und passt er noch, behalte ihn. Nicht gefundene Tasks weglassen.
        \(titles.isEmpty ? "" : "Kurznamen ebenso für diese MR-Titel (Schlüssel = Titel unverändert):\n" + titles.map { "- \($0)" }.joined(separator: "\n"))
        """
        let mcp = #"{"mcpServers":{"clickup":{"type":"http","url":"https://mcp.clickup.com/mcp"}}}"#
        var args = ["-p", "--setting-sources", "", "--model", "claude-haiku-5-5", "--no-session-persistence", "--output-format", "json"]
        args += ids.isEmpty ? ["--strict-mcp-config", "--tools", ""]
                            : ["--strict-mcp-config", "--mcp-config", mcp, "--tools", "", "--allowedTools", "mcp__clickup__clickup_get_task"]
        let r = runClaude(args, input: prompt, cwd: buddyDir)
        guard r.ok, var text = r.text else { return nil }
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") { text = String(text[start...end]) }
        guard let obj = json(Data(text.utf8)) as? [String: Any] else { return nil }
        let tickets = (obj["tickets"] as? [[String: Any]] ?? []).compactMap { t -> Ticket? in
            guard let id = (t["id"] as? String)?.lowercased().replacingOccurrences(of: "cu-", with: ""),
                  let name = t["name"] as? String, let status = t["status"] as? String else { return nil }
            return Ticket(id: id, name: name, status: status.lowercased(), short: clean(t["kurz"] as? String ?? ""))
        }
        var names: [String: String] = [:]
        for (k, v) in obj["namen"] as? [String: String] ?? [:] where titles.contains(k) { names[k] = clean(v) }
        // Was ClickUp nicht kennt, nicht bei jeder Runde erneut abfragen.
        let missing = ids.filter { id in !tickets.contains { $0.id == id } }
        let placeholders = missing.map { id in known[id] ?? Ticket(id: id, name: "", status: "") }.map { t -> Ticket in
            var t = t
            t.checked = Date()
            return t
        }
        return (tickets + placeholders, names)
    }

    private func clean(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"„“.")))
        return t.count <= 40 ? t : ""
    }
}
