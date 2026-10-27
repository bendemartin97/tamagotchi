import AppKit

let homeURL = FileManager.default.homeDirectoryForCurrentUser
let buddyDir = homeURL.appendingPathComponent(".claude/tamagotchi")
let eventsURL = buddyDir.appendingPathComponent("events.jsonl")
let memoryDir = homeURL.appendingPathComponent(".claude/projects/-Users-martinbende-Development/memory")

enum Mood { case idle, sleeping, working, done, waiting }

struct Session {
    var id: String
    var mood: Mood
    var project = ""
    var agent = ""
    var text = ""
    /// Letzter Tool-Aufruf, z. B. "Bash · ws test --parallel".
    var detail = ""
    /// Session-Titel aus dem Transkript (custom-title oder ai-title).
    var title = ""
    /// Kurze Überschrift von Haiku (siehe Headliner), sonst title.
    var headline = ""
    var transcript = ""
    /// Ersetzt ✋/✅ in der Sprechblase (MRs, Aufträge).
    var icon = ""
    var click: [String] = []
    var updated = Date()
    /// Echte Agent-Session mit eigenem Mini-Haustier; MR-Meldungen sind keine.
    var isAgent = true
    /// Zeitpunkt eines Stop-Events, das noch nicht als „fertig“ gilt (siehe Store.settle).
    var stopAt: Date?

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
    /// Feste Namen für Sessions, die das Haustier selbst gestartet hat.
    var labels: [String: String] = [:]
    /// Abgeschlossene Aufträge: späte Hook-Events überschreiben das Ergebnis nicht.
    var sealed: Set<String> = []
    /// Überschriften überleben das Quittieren einer fertigen Session.
    var headlines: [String: String] = [:]
    var onWorking: ((Session) -> Void)?
    private var names: [String: String] = [:]
    private var offset: UInt64 = 0

    init() {
        let fm = FileManager.default
        try? fm.createDirectory(at: buddyDir, withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: eventsURL.path))?[.size] as? UInt64, size > 512_000 {
            try? Data().write(to: eventsURL)
        }
        if !fm.fileExists(atPath: eventsURL.path) { fm.createFile(atPath: eventsURL.path, contents: nil) }
        offset = ((try? fm.attributesOfItem(atPath: eventsURL.path))?[.size] as? UInt64) ?? 0
        Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in self?.poll() }
    }

    var pending: [Session] {
        sessions.values
            .filter { $0.mood == .waiting || $0.mood == .done }
            .sorted { a, b in
                if a.mood != b.mood { return a.mood == .waiting }
                return a.updated > b.updated
            }
    }

    /// Fester Spitzname pro Session, aus der ID abgeleitet und unter den laufenden Sessions eindeutig.
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
        let all = sessions.values
        if all.contains(where: { $0.mood == .waiting }) { return .waiting }
        if all.contains(where: { $0.mood == .done }) { return .done }
        if all.contains(where: { $0.mood == .working }) { return .working }
        let hour = Calendar.current.component(.hour, from: Date())
        if hour >= 22 || hour < 6 { return .sleeping }
        return Date().timeIntervalSince(lastActivity) > 20 * 60 ? .sleeping : .idle
    }

    func post(_ s: Session) {
        sessions[s.id] = s
        lastActivity = Date()
        onChange?()
    }

    func ack(_ id: String) {
        guard var s = sessions[id] else { return }
        if s.mood == .waiting && s.isAgent {
            s.mood = .working
            s.updated = Date()
            sessions[id] = s
        } else {
            sessions[id] = nil
        }
        onChange?()
    }

    func ackAll() {
        for (id, s) in sessions where s.mood == .done || s.mood == .waiting { sessions[id] = nil }
        onChange?()
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
        if changed { onChange?() }
        exportLabels()
    }

    private var exported = ""

    /// Spitznamen und Überschriften der Agent-Sessions für agent-feedback, damit die Session-Auswahl dort
    /// dieselben Namen zeigt wie die Minis. Schreibt nur bei Änderungen.
    private func exportLabels() {
        var out: [String: [String: String]] = [:]
        for s in agents { out[s.id] = ["name": name(for: s.id), "headline": s.heading] }
        guard let data = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8), text != exported else { return }
        exported = text
        try? data.write(to: buddyDir.appendingPathComponent("labels.json"), options: .atomic)
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
        if let v = headlines[id] { s.headline = v }
        if let v = e["click"] as? [String], !v.isEmpty { s.click = v }
        if let v = labels[id] { s.project = v }
        s.updated = Date()
        s.stopAt = nil
        switch e["event"] as? String {
        case "working", "pretool": s.mood = .working
        case "stop": s.stopAt = Date()
        case "notification": s.mood = .waiting
        case "end": sessions[id] = nil; return
        default: return
        }
        sessions[id] = s
        if s.mood == .working { onWorking?(s) }
    }

    /// Stop-Hooks wie das Quality-Gate können ein Stop blockieren, dann arbeitet Claude sofort weiter.
    /// Erst wenn nach dem Stop 4 s lang nichts mehr von der Session kommt, gilt sie als fertig.
    private func settle() -> Bool {
        var changed = false
        for (id, s) in sessions {
            guard let at = s.stopAt, Date().timeIntervalSince(at) > 4 else { continue }
            var done = s
            done.stopAt = nil
            done.mood = .done
            sessions[id] = done
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
            case .working: return age < 30 * 60
            case .done: return age < 3 * 3600
            default: return age < 8 * 3600
            }
        }
        return sessions.count != before
    }
}

/// Futter und Laune, 0…5. Erledigte Sessions füttern, Streicheln und Merges machen gute Laune,
/// rote Pipelines schlechte. Tagsüber (8–20 Uhr) wird er langsam hungrig.
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

/// Führt die Klickargumente aus wie terminal-notifier: -activate per Bundle-ID, -execute über /bin/sh -c.
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
