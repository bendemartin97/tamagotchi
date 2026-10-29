import Foundation

/// An MR (GitLab) or PR (GitHub) that Martin is involved in.
struct Change: Codable {
    var key: String
    var host: String
    /// API path of the project: "projects/<id>" (GitLab) or "repos/<owner>/<name>" (GitHub).
    var api: String
    var repo: String
    var number: Int
    var title: String
    var url: String
    var branch: String
    var target: String
    var author = ""
    /// Author's first name for the speech bubbles.
    var who = ""
    var mine = false
    var reviewer = false
    var state = "opened"
    var draft = false
    /// failed, success, running, pending, or empty.
    var pipeline = ""
    var conflict = false
    /// approved, changes, or empty.
    var review = ""
    /// Number of open review items from others.
    var open = 0
    /// Time of the most recent response from someone else (comment, review).
    var lastForeign: Date?
    var notes = 0
    var mergeSha = ""
    var mergedAt: Date?
    /// Result of the post-merge check: "", "ok", or "lost".
    var lost = ""
    var lostChecked: Date?
    var seen = Date()

    var isOpen: Bool { state == "opened" }
    /// "Frontend", "Backend", or the repo name.
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
    /// 2–4 words in German, e.g. „Kalender grau bei Zeitplänen“.
    var short = ""
    var checked = Date()

    var url: String { "https://app.clickup.com/t/\(id)" }
    var finished: Bool { ["staging", "complete", "completed", "closed", "done", "released", "archived"].contains(status.lowercased()) }
}

/// What last happened in a workspace, for the summary on return.
struct Trail: Codable {
    var heading = ""
    var prompt = ""
    var answer = ""
    var at = Date()
    var session = ""
    /// Session's starting folder (for `claude --resume`).
    var root = ""
    var transcript = ""
}

/// Everything that should survive a restart, in ~/.claude/tamagotchi/state.json.
struct Persisted: Codable {
    var changes: [String: Change] = [:]
    var tickets: [String: Ticket] = [:]
    /// Short human-readable names for MR titles without a ticket.
    var names: [String: String] = [:]
    var trails: [String: Trail] = [:]
    /// When a workspace was last seen or active.
    var lastSeen: [String: Date] = [:]
    /// When GitLab, GitHub, and ClickUp were last queried successfully.
    var checked: [String: Date] = [:]
    /// Conflicts and lost changes that have already been reported.
    var told: [String: Date] = [:]
    var sessions: [Session] = []
    var headlines: [String: String] = [:]
    /// Optional, so older state.json files without an inbox remain readable.
    var inbox: [Message]?
    /// Day (yyyy-MM-dd) → task → seconds; and what of that has already been booked to ClickUp (day|task → minutes).
    var timeLog: [String: [String: Double]]?
    var booked: [String: Int]?
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

/// Runs a command-line tool and returns stdout on exit 0. Blocks.
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

/// ClickUp ID from branch, title, workspace name, or link, lowercase without „CU-“.
func ticketID(in text: String) -> String? {
    for pattern in ["(?i)\\bCU-([0-9a-z]{8,14})", "app\\.clickup\\.com/t/(?:\\d+/)?([0-9a-z]{8,14})"] {
        if let r = text.range(of: pattern, options: .regularExpression) {
            let m = String(text[r])
            return m.replacingOccurrences(of: "(?i)^.*?(CU-|/t/(\\d+/)?)", with: "", options: .regularExpression).lowercased()
        }
    }
    return nil
}

/// German number words for the sentences in the speech bubbles.
func numberWord(_ n: Int, feminine: Bool = false) -> String {
    let words = ["null", feminine ? "eine" : "ein", "zwei", "drei", "vier", "fünf", "sechs", "sieben", "acht", "neun", "zehn", "elf", "zwölf"]
    return n < words.count ? words[n] : "\(n)"
}

func capitalized(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

func joinedList(_ items: [String]) -> String {
    guard items.count > 1 else { return items.first ?? "" }
    return items.dropLast().joined(separator: ", ") + " und " + items.last!
}
