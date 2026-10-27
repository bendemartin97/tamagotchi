import Foundation

/// Eine MR (GitLab) oder ein PR (GitHub), an dem Martin beteiligt ist.
struct Change: Codable {
    var key: String
    var host: String
    /// API-Pfad des Projekts: "projects/<id>" (GitLab) bzw. "repos/<owner>/<name>" (GitHub).
    var api: String
    var repo: String
    var number: Int
    var title: String
    var url: String
    var branch: String
    var target: String
    var author = ""
    /// Vorname des Autors für die Sprechblasen.
    var who = ""
    var mine = false
    var reviewer = false
    var state = "opened"
    var draft = false
    /// failed, success, running, pending oder leer.
    var pipeline = ""
    var conflict = false
    /// approved, changes oder leer.
    var review = ""
    /// Anzahl offener Review-Punkte von anderen.
    var open = 0
    /// Zeitpunkt der jüngsten Rückmeldung von jemand anderem (Kommentar, Review).
    var lastForeign: Date?
    var notes = 0
    var mergeSha = ""
    var mergedAt: Date?
    /// Ergebnis der Kontrolle nach dem Merge: "", "ok" oder "lost".
    var lost = ""
    var lostChecked: Date?
    var seen = Date()

    var isOpen: Bool { state == "opened" }
    /// "Frontend", "Backend" oder der Repo-Name.
    var side: String { sideName(repo) }
}

func sideName(_ repo: String) -> String {
    switch repo {
    case "anny-ui": return "Frontend"
    case "bookings-api": return "Backend"
    default: return repo.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: "-")
    }
}

struct Ticket: Codable {
    var id: String
    var name: String
    var status: String
    /// 2–4 Wörter auf Deutsch, z. B. „Kalender grau bei Zeitplänen“.
    var short = ""
    var checked = Date()

    var url: String { "https://app.clickup.com/t/\(id)" }
    var finished: Bool { ["staging", "complete", "completed", "closed", "done", "released", "archived"].contains(status.lowercased()) }
}

/// Was in einem Workspace zuletzt passiert ist, für die Zusammenfassung beim Zurückkehren.
struct Trail: Codable {
    var heading = ""
    var prompt = ""
    var answer = ""
    var at = Date()
    var session = ""
    /// Startordner der Session (für `claude --resume`).
    var root = ""
    var transcript = ""
}

/// Alles, was einen Neustart überleben soll, in ~/.claude/tamagotchi/state.json.
struct Persisted: Codable {
    var changes: [String: Change] = [:]
    var tickets: [String: Ticket] = [:]
    /// Kurze menschliche Namen für MR-Titel ohne Ticket.
    var names: [String: String] = [:]
    var trails: [String: Trail] = [:]
    /// Wann ein Workspace zuletzt zu sehen oder aktiv war.
    var lastSeen: [String: Date] = [:]
    /// Wann GitLab, GitHub und ClickUp zuletzt erfolgreich abgefragt wurden.
    var checked: [String: Date] = [:]
    /// Schon gemeldete Widersprüche und verlorene Änderungen.
    var told: [String: Date] = [:]
    var sessions: [Session] = []
    var headlines: [String: String] = [:]
}

final class State {
    static let shared = State()
    private let url = buddyDir.appendingPathComponent("state.json")
    var data = Persisted()
    private var dirty = false

    private init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let raw = try? Data(contentsOf: url), let d = try? decoder.decode(Persisted.self, from: raw) { data = d }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.flush() }
    }

    func touch() { dirty = true }

    func flush() {
        guard dirty else { return }
        dirty = false
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try? encoder.encode(data).write(to: url, options: .atomic)
    }

    func checked(_ source: String) {
        data.checked[source] = Date()
        touch()
    }

    /// „GitLab vor 2 min · GitHub vor 1 min · ClickUp vor 12 min“.
    var checkedLine: String {
        ["GitLab", "GitHub", "ClickUp"].map { name in
            guard let at = data.checked[name.lowercased()] else { return "\(name) noch nie" }
            return "\(name) \(ago(at))"
        }.joined(separator: " · ")
    }
}

func ago(_ date: Date) -> String {
    let m = Int(Date().timeIntervalSince(date) / 60)
    if m < 1 { return "gerade eben" }
    if m < 60 { return "vor \(m) min" }
    if m < 48 * 60 { return "vor \(m / 60) h" }
    return "vor \(m / 1440) Tagen"
}

/// Führt ein Kommandozeilenwerkzeug aus und liefert stdout bei Exit 0. Blockiert.
func cli(_ tool: String, _ args: [String], cwd: URL? = nil) -> Data? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    if let cwd { p.currentDirectoryURL = cwd }
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    guard (try? p.run()) != nil else { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return p.terminationStatus == 0 ? data : nil
}

func json(_ data: Data?) -> Any? { data.flatMap { try? JSONSerialization.jsonObject(with: $0) } }

func parseDate(_ s: Any?) -> Date? {
    guard let s = s as? String else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
}

/// ClickUp-ID aus Branch, Titel, Workspace-Name oder Link, kleingeschrieben ohne „CU-“.
func ticketID(in text: String) -> String? {
    for pattern in ["(?i)\\bCU-([0-9a-z]{8,14})", "app\\.clickup\\.com/t/(?:\\d+/)?([0-9a-z]{8,14})"] {
        if let r = text.range(of: pattern, options: .regularExpression) {
            let m = String(text[r])
            return m.replacingOccurrences(of: "(?i)^.*?(CU-|/t/(\\d+/)?)", with: "", options: .regularExpression).lowercased()
        }
    }
    return nil
}

/// Deutsche Zahlwörter für die Sätze in den Sprechblasen.
func numberWord(_ n: Int, feminine: Bool = false) -> String {
    let words = ["null", feminine ? "eine" : "ein", "zwei", "drei", "vier", "fünf", "sechs", "sieben", "acht", "neun", "zehn", "elf", "zwölf"]
    return n < words.count ? words[n] : "\(n)"
}

func capitalized(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

func joinedList(_ items: [String]) -> String {
    guard items.count > 1 else { return items.first ?? "" }
    return items.dropLast().joined(separator: ", ") + " und " + items.last!
}
