import AppKit

let homeURL = FileManager.default.homeDirectoryForCurrentUser
let buddyDir = homeURL.appendingPathComponent(".claude/tamagotchi")
let eventsURL = buddyDir.appendingPathComponent("events.jsonl")
let memoryDir = homeURL.appendingPathComponent(".claude/projects/-Users-martinbende-Development/memory")

enum Mood: String, Codable { case idle, sleeping, working, done, waiting }

struct Session: Codable {
    var id: String
    var mood: Mood
    var project = ""
    var agent = ""
    var text = ""
    /// Last tool call, e.g. "Bash · ws test --parallel".
    var detail = ""
    /// Session title from the transcript (custom-title or ai-title).
    var title = ""
    /// Short headline from Haiku (see Headliner), otherwise title.
    var headline = ""
    var transcript = ""
    /// Session start directory (CLAUDE_PROJECT_DIR), for `claude --resume`.
    var root = ""
    /// Last hook event; after "pretool" a tool is running that may take a long time.
    var lastEvent = ""
    /// Replaces ✋/✅ in the speech bubble (MRs, tasks).
    var icon = ""
    var click: [String] = []
    var updated = Date()
    /// Real agent session with its own mini pet; MR notifications are not.
    var isAgent = true
    /// Time of a stop event that does not yet count as "done" (see Store.settle).
    var stopAt: Date?
    /// Start of the current or last turn. The live fields are optional so older state.json stays readable.
    var busySince: Date?
    /// Tool calls in the current turn and the most recent ones.
    var tools: Int?
    var recent: [String]?
    /// Duration of the last finished turn in seconds.
    var lastTurn: TimeInterval?

    var label: String { project.isEmpty ? agent : project }
    var heading: String { headline.isEmpty ? title : headline }
}

let petNames = ["Fred", "Noah", "Gustav", "Brunhilde", "Kevin", "Uschi", "Horst", "Bärbel", "Klaus-Dieter", "Mo",
                "Ottilie", "Rüdiger", "Fritzi", "Jürgen", "Hildegard", "Bodo", "Lotte", "Waltraud", "Egon", "Gisela",
                "Detlef", "Trudi", "Ronny", "Mandy", "Schorsch", "Elfriede", "Kalle", "Wolfgang", "Zoe", "Bruno",
                "Hasso", "Frieda", "Günther", "Pünktchen", "Rolf", "Mausi", "Dörte", "Knut", "Hertha", "Pepe"]

final class Store {
    var sessions: [String: Session] = [:]
    var lastActivity = Date()
    var onChange: (() -> Void)?
    var onDone: ((Session) -> Void)?
    /// Fixed names for sessions the pet started itself.
    var labels: [String: String] = [:]
    /// Completed tasks: late hook events don't overwrite the result.
    var sealed: Set<String> = []
    /// Headlines survive acknowledging a finished session.
    var headlines: [String: String] = [:]
    var onWorking: ((Session) -> Void)?
    /// Every hook event of a session (for time tracking).
    var onEvent: ((Session) -> Void)?
    let inbox = Inbox()
    private var names: [String: String] = [:]
    private var offset: UInt64 = 0

    init() {
        let firstInbox = State.shared.data.inbox == nil
        for s in State.shared.data.sessions {
            if firstInbox && (s.mood == .waiting || s.mood == .done) {
                inbox.record(s)
                inbox.markRead(s.id)
            }
            if s.isAgent { sessions[s.id] = s }
        }
        headlines = State.shared.data.headlines
        let fm = FileManager.default
        try? fm.createDirectory(at: buddyDir, withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: eventsURL.path))?[.size] as? UInt64, size > 512_000 {
            try? Data().write(to: eventsURL)
        }
        if !fm.fileExists(atPath: eventsURL.path) { fm.createFile(atPath: eventsURL.path, contents: nil) }
        offset = ((try? fm.attributesOfItem(atPath: eventsURL.path))?[.size] as? UInt64) ?? 0
        Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in self?.poll() }
    }

    /// Fixed nickname per session, derived from the ID and unique among the running sessions.
    func name(for id: String) -> String {
        if let n = names[id] { return n }
        let used = Set(sessions.keys.compactMap { names[$0] })
        let start = Int(id.utf8.reduce(UInt32(5381)) { ($0 &<< 5) &+ $0 &+ UInt32($1) } % UInt32(petNames.count))
        let n = (0..<petNames.count).map { petNames[(start + $0) % petNames.count] }.first { !used.contains($0) } ?? petNames[start]
        names[id] = n
        return n
    }

    var agents: [Session] {
        sessions.values.filter(\.isAgent).sorted { $0.id < $1.id }
    }

    var mood: Mood {
        let fresh = inbox.fresh
        if fresh.contains(where: \.question) { return .waiting }
        if !fresh.isEmpty { return .done }
        if sessions.values.contains(where: { $0.mood == .working }) { return .working }
        let hour = Calendar.current.component(.hour, from: Date())
        if hour >= 22 || hour < 6 { return .sleeping }
        return Date().timeIntervalSince(lastActivity) > 20 * 60 ? .sleeping : .idle
    }

    /// Agent sessions go into sessions; everything else (MR signals, contradictions, feedback, tickets) goes only into the inbox.
    func post(_ s: Session) {
        if s.isAgent { sessions[s.id] = s }
        if s.mood == .waiting || s.mood == .done { inbox.record(s) }
        lastActivity = Date()
        onChange?()
        persist()
    }

    /// Remove a finished agent session from the queue when Martin opens or completes its notification.
    /// Waiting and working sessions stay as they are.
    func dismiss(_ id: String) {
        guard sessions[id]?.mood == .done else { return }
        sessions[id] = nil
        onChange?()
        persist()
    }

    private func poll() {
        var changed = expire() || settle()
        guard let h = try? FileHandle(forReadingFrom: eventsURL) else { return }
        defer { try? h.close() }
        let end = (try? h.seekToEnd()) ?? 0
        if end < offset { offset = 0 }
        if end > offset {
            try? h.seek(toOffset: offset)
            let data = h.readDataToEndOfFile()
            if let nl = data.lastIndex(of: 0x0A) {
                let chunk = data[data.startIndex...nl]
                offset += UInt64(chunk.count)
                for line in chunk.split(separator: 0x0A) {
                    if let e = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] {
                        apply(e)
                        changed = true
                    }
                }
            }
        }
        if changed {
            onChange?()
            persist()
        }
        exportLabels()
    }

    /// Sessions and headlines survive a restart (e.g. after build.sh).
    func persist() {
        State.shared.data.sessions = Array(sessions.values)
        State.shared.data.headlines = headlines
        State.shared.touch()
    }

    private var exported = ""

    /// Nicknames and headlines of the agent sessions for agent-feedback, so the session picker there
    /// shows the same names as the minis. Only writes on changes.
    private func exportLabels() {
        var out: [String: [String: String]] = [:]
        for s in agents { out[s.id] = ["name": name(for: s.id), "headline": s.heading] }
        guard let data = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8), text != exported else { return }
        exported = text
        try? data.write(to: homeURL.appendingPathComponent(".claude/agent-feedback/labels.json"), options: .atomic)
    }

    private func apply(_ e: [String: Any]) {
        let id = e["session"] as? String ?? "?"
        if sealed.contains(id) { return }
        lastActivity = Date()
        var s = sessions[id] ?? Session(id: id, mood: .working)
        if let v = e["project"] as? String, !v.isEmpty { s.project = v }
        if let v = e["agent"] as? String, !v.isEmpty { s.agent = v }
        if let v = e["text"] as? String, !v.isEmpty { s.text = v }
        if let v = e["detail"] as? String, !v.isEmpty { s.detail = v }
        if let v = e["title"] as? String, !v.isEmpty { s.title = v }
        if let v = e["transcript"] as? String, !v.isEmpty { s.transcript = v }
        if let v = e["root"] as? String, !v.isEmpty { s.root = v }
        if let v = headlines[id] { s.headline = v }
        if let v = e["click"] as? [String], !v.isEmpty { s.click = v }
        if let v = labels[id] { s.project = v }
        s.updated = Date()
        s.stopAt = nil
        s.lastEvent = e["event"] as? String ?? ""
        let before = s.mood
        switch e["event"] as? String {
        case "working", "pretool": s.mood = .working
        case "stop": s.stopAt = Date()
        case "notification": s.mood = .waiting
        case "end": sessions[id] = nil; return
        default: return
        }
        if s.mood == .working && (before == .done || s.busySince == nil) {
            s.busySince = Date()
            s.tools = 0
        }
        if s.lastEvent == "pretool", !s.detail.isEmpty {
            s.tools = (s.tools ?? 0) + 1
            s.recent = Array(((s.recent ?? []) + [s.detail]).suffix(6))
        }
        sessions[id] = s
        onEvent?(s)
        if s.mood == .working {
            // Martin continued in the session: answered the question or saw the result.
            if before == .waiting { inbox.resumed(id) } else if before == .done { inbox.markRead(id) }
            onWorking?(s)
        }
        if s.mood == .waiting { inbox.record(s) }
    }

    /// Stop hooks like the quality gate can block a stop, in which case Claude keeps working immediately.
    /// Only when nothing more arrives from the session for 4 s after the stop does it count as done.
    private func settle() -> Bool {
        var changed = false
        for (id, s) in sessions {
            guard let at = s.stopAt, Date().timeIntervalSince(at) > 4 else { continue }
            var done = s
            done.stopAt = nil
            done.mood = .done
            done.lastTurn = done.busySince.map { at.timeIntervalSince($0) }
            sessions[id] = done
            inbox.record(done)
            onDone?(done)
            changed = true
        }
        return changed
    }

    private func expire() -> Bool {
        let now = Date()
        let before = sessions.count
        sessions = sessions.filter { _, s in
            let age = now.timeIntervalSince(s.updated)
            switch s.mood {
            case .working:
                // Long tool runs (tests, builds) only report afterwards; the transcript shows signs of life.
                if s.lastEvent == "pretool" { return age < 3 * 3600 }
                if age < 30 * 60 { return true }
                let touched = (try? FileManager.default.attributesOfItem(atPath: s.transcript))?[.modificationDate] as? Date
                return Date().timeIntervalSince(touched ?? .distantPast) < 30 * 60 && age < 8 * 3600
            case .done: return age < 3 * 3600
            default: return age < 8 * 3600
            }
        }
        return sessions.count != before
    }
}

/// Food and mood, 0…5. Finished sessions feed it, petting and merges improve its mood,
/// red pipelines worsen it. During the day (8am–8pm) it slowly gets hungry.
final class Vitals {
    private let d = UserDefaults.standard

    init() {
        if d.object(forKey: "decay") == nil { d.set(Date(), forKey: "decay") }
    }

    var food: Double {
        get { d.object(forKey: "food") as? Double ?? 3 }
        set { d.set(min(5, max(0, newValue)), forKey: "food") }
    }

    var joy: Double {
        get { d.object(forKey: "joy") as? Double ?? 3 }
        set { d.set(min(5, max(0, newValue)), forKey: "joy") }
    }

    var hungry: Bool { food < 1 }
    var grumpy: Bool { joy < 1 }

    func decay() {
        let last = d.object(forKey: "decay") as? Date ?? Date()
        let hours = Date().timeIntervalSince(last) / 3600
        guard hours >= 0.25 else { return }
        if (8..<20).contains(Calendar.current.component(.hour, from: Date())) {
            food -= hours / 1.5
            joy -= hours / 4
        }
        d.set(Date(), forKey: "decay")
    }

    func dots(_ v: Double) -> String {
        let n = Int(v.rounded())
        return String(repeating: "●", count: n) + String(repeating: "○", count: 5 - n)
    }
}

/// Executes the click arguments like terminal-notifier: -activate via bundle ID, -execute via /bin/sh -c.
/// PetView handles "-task" (prepared task) itself.
func performClick(_ args: [String]) {
    guard args.count == 2 else { return }
    switch args[0] {
    case "-activate":
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: args[1]) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    case "-execute":
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", args[1]]
        try? p.run()
    default:
        break
    }
}

func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
