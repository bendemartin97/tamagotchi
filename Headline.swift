import Foundation

/// Short headline for a mini pet. Claude Code's ai-title is generated from the first prompt and
/// often stays stuck on ticket IDs or details; after each completed turn, Haiku re-summarizes the session.
final class Headliner {
    let store: Store
    private var running: Set<String> = []
    private var lastRun: [String: Date] = [:]

    init(store: Store) { self.store = store }

    /// After each completed turn; during the first turn at most every 90 s, as long as there is none yet.
    func refresh(_ s: Session, done: Bool) {
        guard s.isAgent, !s.transcript.isEmpty, !running.contains(s.id) else { return }
        if !done && (s.headline.isEmpty == false || Date().timeIntervalSince(lastRun[s.id] ?? .distantPast) < 90) { return }
        running.insert(s.id)
        lastRun[s.id] = Date()
        DispatchQueue.global(qos: .utility).async {
            let text = self.ask(s)
            DispatchQueue.main.async {
                self.running.remove(s.id)
                guard let text else { return }
                self.store.headlines[s.id] = text
                self.store.sessions[s.id]?.headline = text
                self.store.onChange?()
            }
        }
    }

    private func ask(_ s: Session) -> String? {
        guard let context = transcriptContext(s.transcript) else { return nil }
        let prompt = """
        Gib einer laufenden Claude-Code-Session eine Überschrift für ein kleines Namensschild: 2 bis 5 Wörter, \
        Deutsch, sagt, woran gearbeitet wird (Thema und Tätigkeit, z. B. „Kalender-Renderer neu bauen“, \
        „Release-MRs vorbereiten“, „Refund-Fehler debuggen“). Keine Ticket-IDs, Nummern, Dateinamen oder \
        Anführungszeichen. Passt die bisherige Überschrift noch, gib sie unverändert zurück. Antworte nur mit der Überschrift.

        Projekt: \(s.project)
        Bisherige Überschrift: \(s.headline.isEmpty ? s.title : s.headline)

        \(context)
        """
        let args = ["-p", "--setting-sources", "", "--strict-mcp-config", "--model", "claude-haiku-5-5",
                    "--tools", "", "--no-session-persistence", "--output-format", "json"]
        let r = runClaude(args, input: prompt, cwd: buddyDir)
        let text = (r.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"„“.")))
        return r.ok && !text.isEmpty && text.count <= 48 && !text.contains("\n") ? text : nil
    }

    private func transcriptContext(_ path: String) -> String? {
        guard let (prompts, answer) = transcriptTail(path) else { return nil }
        let asks = prompts.suffix(3).map { "- \($0)" }.joined(separator: "\n")
        return "Martins letzte Nachrichten:\n\(asks)\n\nLetzte Antwort von Claude:\n\(answer)"
    }
}

/// Martin's prompts and Claude's last reply from the end of the transcript.
func transcriptTail(_ path: String) -> (prompts: [String], answer: String)? {
    guard let h = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? h.close() }
    let end = (try? h.seekToEnd()) ?? 0
    try? h.seek(toOffset: end > 1_500_000 ? end - 1_500_000 : 0)
    let data = h.readDataToEndOfFile()
    var prompts: [String] = []
    var answer = ""
    for line in data.split(separator: 0x0A) {
        guard let e = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
              let type = e["type"] as? String, type == "user" || type == "assistant",
              e["isMeta"] as? Bool != true,
              let msg = e["message"] as? [String: Any] else { continue }
        var text = ""
        if let c = msg["content"] as? String {
            text = c
        } else if let blocks = msg["content"] as? [[String: Any]] {
            text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: " ")
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text.hasPrefix("<") { continue }
        if type == "user" { prompts.append(String(text.prefix(500))) } else { answer = String(text.prefix(1200)) }
    }
    return prompts.isEmpty && answer.isEmpty ? nil : (prompts, answer)
}
