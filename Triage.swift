import Foundation

/// Haiku sortiert „Du bist dran“ in jetzt, kann warten und ausblenden, damit Menü und Zusammenfassung nicht
/// mit Altlasten volllaufen. Läuft nur, wenn Martin aktiv ist und sich die Liste geändert hat (höchstens alle
/// 2 min, sonst stündlich wegen der Alterung). Bis zur ersten Antwort und bei Fehlern gelten einfache Regeln.
final class Triage {
    enum Rank: String, Codable { case now, later, hidden }

    private struct Saved: Codable {
        var ranks: [String: Rank] = [:]
        var sentence = ""
        /// Liste, zu der ranks und sentence gehören.
        var input = ""
        var at = Date.distantPast
        /// Seit wann ein Punkt auf der Liste steht.
        var since: [String: Date] = [:]
    }

    var onUpdate: (() -> Void)?
    private var saved = Saved()
    private var running = false
    private var lastRun = Date.distantPast
    private let url = buddyDir.appendingPathComponent("triage.json")

    init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let raw = try? Data(contentsOf: url), let s = try? decoder.decode(Saved.self, from: raw) { saved = s }
    }

    static func key(_ a: Attention) -> String { a.id.isEmpty ? a.phrase : a.id }

    func rank(_ a: Attention) -> Rank {
        if let r = saved.ranks[Self.key(a)] { return r }
        return a.group.isEmpty ? .now : .later
    }

    /// Haikus Satz, solange die Liste noch dieselbe ist, zu der er geschrieben wurde.
    func sentence(for you: [Attention]) -> String? {
        saved.input == signature(you) && !saved.sentence.isEmpty ? saved.sentence : nil
    }

    private func signature(_ you: [Attention]) -> String { you.map(Self.key).sorted().joined(separator: "\n") }

    func update(_ you: [Attention], context: (Attention) -> String, active: Bool) {
        let keys = Set(you.map(Self.key))
        var since = saved.since.filter { keys.contains($0.key) }
        for k in keys where since[k] == nil { since[k] = Date() }
        if since != saved.since { saved.since = since; save() }

        let sig = signature(you)
        let wait: TimeInterval = sig == saved.input ? 3600 : 120
        guard active, !running, !you.isEmpty, Date().timeIntervalSince(lastRun) > wait else { return }
        running = true
        lastRun = Date()

        let lines = you.enumerated().map { i, a in
            var line = "\(i + 1). \(a.icon) \(a.phrase) (steht seit \(ago(since[Self.key(a)] ?? Date()).replacingOccurrences(of: "vor ", with: "")) auf der Liste"
            let extra = context(a)
            if !extra.isEmpty { line += "; \(extra)" }
            return line + ")"
        }
        let prompt = """
        Du sortierst Martins Liste „Du bist dran“ (Entwickler bei anny). Das Desktop-Haustier soll nur zeigen, \
        was jetzt wirklich zählt, der Rest darf nicht nerven.

        - "jetzt": höchstens drei Punkte, bei denen jemand blockiert ist oder etwas kaputt ist: ein Mensch oder \
        Agent wartet auf Martins Antwort, rote Pipeline oder Merge-Konflikt an seiner eigenen Änderung, verlorene \
        Änderung, Widerspruch zwischen Ticket und Code, frische Review-Bitte eines Kollegen.
        - "aus": Rauschen und Altlasten: Review-Bitten von Cursor, die seit mehr als einem Tag liegen; \
        Sichtprüfungen, die seit mehr als zwei Tagen liegen; fertige Sessions, die seit Stunden ungelesen sind; \
        alles, was einen anderen Punkt nur wiederholt.
        - "später": alles andere.
        - "satz": ein bis zwei kurze Sätze auf Deutsch in Du-Form, was als Nächstes dran ist, im Stil „Fred braucht \
        eine Antwort, und die Kalender-Pipeline ist rot. Der Rest kann warten.“ Keine MR-, PR- oder Ticketnummern, \
        nichts erfinden, ausgeblendete Punkte nicht erwähnen.

        Jetzt ist \(Self.now()).

        \(lines.joined(separator: "\n"))

        Antworte nur mit JSON: {"jetzt": [Nummern], "später": [Nummern], "aus": [Nummern], "satz": "…"}
        """
        let keyList = you.map(Self.key)
        DispatchQueue.global(qos: .utility).async {
            let r = runClaude(["-p", "--setting-sources", "", "--strict-mcp-config", "--model", "claude-haiku-5-5",
                               "--tools", "", "--no-session-persistence", "--output-format", "json"], input: prompt, cwd: buddyDir)
            let parsed = r.ok ? Self.parse(r.text ?? "", keys: keyList) : nil
            DispatchQueue.main.async {
                self.running = false
                guard let (ranks, sentence) = parsed else { return }
                self.saved.ranks = ranks
                self.saved.sentence = sentence
                self.saved.input = sig
                self.saved.at = Date()
                self.save()
                self.onUpdate?()
            }
        }
    }

    private static func parse(_ text: String, keys: [String]) -> ([String: Rank], String)? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              let obj = json(Data(text[start...end].utf8)) as? [String: Any] else { return nil }
        var ranks: [String: Rank] = [:]
        for (field, rank) in [("später", Rank.later), ("aus", .hidden), ("jetzt", .now)] {
            for n in obj[field] as? [Int] ?? [] where n >= 1 && n <= keys.count { ranks[keys[n - 1]] = rank }
        }
        guard !ranks.isEmpty else { return nil }
        for k in keys where ranks[k] == nil { ranks[k] = .later }
        return (ranks, (obj["satz"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func now() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "EEEE, HH:mm"
        return f.string(from: Date())
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(saved).write(to: url, options: .atomic)
    }
}
