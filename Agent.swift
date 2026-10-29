import AppKit
import Charts
import SwiftUI

// MARK: Transkript

struct ToolCall {
    var id: String
    var at: Date
    var name: String
    var detail: String
    var error = false
}

/// Ein Turn: Martins Eingabe bis zur letzten Antwort davor.
struct Turn {
    var prompt: String
    var start: Date
    var end: Date
    var tools: [ToolCall] = []
    var answer = ""
    /// Endete mit einer Rückfrage (AskUserQuestion).
    var asked = false
    var output = 0

    var errors: Int { tools.filter(\.error).count }
}

struct UsagePoint {
    var at: Date
    var context: Int
}

/// Was im ganzen Transkript einer Session steckt: Turns mit Werkzeugen, bearbeitete Dateien, Verbrauch.
struct SessionLog {
    var turns: [Turn] = []
    /// Pfad → Anzahl der Bearbeitungen.
    var files: [String: Int] = [:]
    var usage: [UsagePoint] = []
    var model = ""
    var output = 0
    var calls = 0

    var tools: Int { turns.reduce(0) { $0 + $1.tools.count } }
    var errors: Int { turns.reduce(0) { $0 + $1.errors } }
    var worked: TimeInterval { turns.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) } }
}

/// Liest ein Transkript stückweise ab der letzten Position weiter. Läuft nur auf der Queue von SessionLogs.
private final class LogParser {
    var log = SessionLog()
    /// Stand für die Oberfläche, nur auf dem Main-Thread gesetzt.
    var snapshot: SessionLog?
    var offset: UInt64 = 0
    private var seen: Set<String> = []
    private var toolIndex: [String: (Int, Int)] = [:]
    private var last = Date.distantPast

    func read(_ path: String) {
        guard let h = FileHandle(forReadingAtPath: path) else { return }
        defer { try? h.close() }
        try? h.seek(toOffset: offset)
        let data = h.readDataToEndOfFile()
        guard let nl = data.lastIndex(of: 0x0A) else { return }
        let chunk = data[data.startIndex...nl]
        offset += UInt64(chunk.count)
        let user = Data("\"type\":\"user\"".utf8), assistant = Data("\"type\":\"assistant\"".utf8)
        for line in chunk.split(separator: 0x0A) where line.range(of: user) != nil || line.range(of: assistant) != nil {
            if let e = json(Data(line)) as? [String: Any] { apply(e) }
        }
    }

    private func apply(_ e: [String: Any]) {
        guard e["isSidechain"] as? Bool != true, let msg = e["message"] as? [String: Any] else { return }
        let at = parseDate(e["timestamp"]) ?? last
        last = at
        switch e["type"] as? String {
        case "user":
            guard e["isMeta"] as? Bool != true else { return }
            if let text = msg["content"] as? String { start(text, at: at); return }
            let blocks = msg["content"] as? [[String: Any]] ?? []
            var texts: [String] = []
            var results = false
            for b in blocks {
                if b["type"] as? String == "tool_result" {
                    results = true
                    if b["is_error"] as? Bool == true, let id = b["tool_use_id"] as? String, let (t, i) = toolIndex[id] {
                        log.turns[t].tools[i].error = true
                    }
                } else if b["type"] as? String == "text", let t = b["text"] as? String {
                    texts.append(t)
                }
            }
            if !results && !texts.isEmpty { start(texts.joined(separator: "\n"), at: at) }
        case "assistant":
            if log.turns.isEmpty { log.turns.append(Turn(prompt: "", start: at, end: at)) }
            let t = log.turns.count - 1
            if let id = msg["id"] as? String, !seen.contains(id), let usage = msg["usage"] as? [String: Any] {
                seen.insert(id)
                let context = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"].reduce(0) { $0 + (usage[$1] as? Int ?? 0) }
                log.usage.append(UsagePoint(at: at, context: context))
                let out = usage["output_tokens"] as? Int ?? 0
                log.output += out
                log.turns[t].output += out
                log.calls += 1
                if let m = msg["model"] as? String, !m.hasPrefix("<") { log.model = m.replacingOccurrences(of: "claude-", with: "") }
            }
            for b in msg["content"] as? [[String: Any]] ?? [] {
                switch b["type"] as? String {
                case "text":
                    if let text = b["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { log.turns[t].answer = text }
                case "tool_use":
                    let name = b["name"] as? String ?? "?"
                    let input = b["input"] as? [String: Any] ?? [:]
                    let id = b["id"] as? String ?? ""
                    toolIndex[id] = (t, log.turns[t].tools.count)
                    log.turns[t].tools.append(ToolCall(id: id, at: at, name: name, detail: Self.detail(input)))
                    if ["Edit", "Write", "MultiEdit", "NotebookEdit"].contains(name), let f = (input["file_path"] ?? input["notebook_path"]) as? String {
                        log.files[f, default: 0] += 1
                    }
                    if name == "AskUserQuestion" { log.turns[t].asked = true }
                default:
                    break
                }
            }
            log.turns[t].end = at
        default:
            break
        }
    }

    private func start(_ raw: String, at: Date) {
        let text = raw.replacingOccurrences(of: "</?pasted_content[^>]*>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.hasPrefix("<") else { return }
        log.turns.append(Turn(prompt: text, start: at, end: at))
    }

    private static func detail(_ input: [String: Any]) -> String {
        for key in ["command", "file_path", "notebook_path", "url", "pattern", "query", "description", "prompt", "skill"] {
            if let v = input[key] as? String, !v.isEmpty {
                return String(v.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).prefix(160))
            }
        }
        return ""
    }
}

/// Transkripte der Agenten, im Hintergrund gelesen und bei jeder Änderung der Datei fortgesetzt.
final class SessionLogs {
    var onUpdate: (() -> Void)?
    private var parsers: [String: LogParser] = [:]
    private var busy: Set<String> = []
    private let queue = DispatchQueue(label: "tamagotchi.logs", qos: .utility)

    /// Aktueller Stand; nil, solange das Transkript zum ersten Mal gelesen wird.
    func log(_ path: String) -> SessionLog? {
        guard !path.isEmpty else { return nil }
        let p = parsers[path] ?? LogParser()
        parsers[path] = p
        let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? UInt64) ?? 0
        if !busy.contains(path), size > p.offset {
            busy.insert(path)
            queue.async {
                p.read(path)
                let snap = p.log
                DispatchQueue.main.async {
                    p.snapshot = snap
                    self.busy.remove(path)
                    self.onUpdate?()
                }
            }
        }
        return p.snapshot
    }
}

// MARK: Git

struct RepoState {
    var dir: String
    var branch = ""
    var base = ""
    /// `git status --porcelain`-Zeilen.
    var dirty: [String] = []
    /// Commits über dem Basisbranch.
    var ahead = 0
    /// Noch nicht gepushte Commits; nil ohne Upstream.
    var unpushed: Int?
    var lastCommit = ""

    var name: String { URL(fileURLWithPath: dir).lastPathComponent }
}

/// Git-Stand der Repos eines Agenten, höchstens alle 15 s neu.
final class GitStates {
    var onUpdate: (() -> Void)?
    private var cache: [String: (Date, RepoState)] = [:]
    private var busy: Set<String> = []

    func state(_ dir: String) -> RepoState? {
        if !busy.contains(dir), Date().timeIntervalSince(cache[dir]?.0 ?? .distantPast) > 15 {
            busy.insert(dir)
            DispatchQueue.global(qos: .utility).async {
                let s = Self.read(dir)
                DispatchQueue.main.async {
                    self.cache[dir] = (Date(), s)
                    self.busy.remove(dir)
                    self.onUpdate?()
                }
            }
        }
        return cache[dir]?.1
    }

    private static func git(_ dir: String, _ args: [String]) -> String? {
        cli("/usr/bin/git", ["-C", dir] + args).flatMap { String(data: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func base(for branch: String) -> String { branch.hasPrefix("admin-next/") ? "origin/admin-next/head" : "origin/main" }

    private static func read(_ dir: String) -> RepoState {
        var s = RepoState(dir: dir)
        s.branch = git(dir, ["rev-parse", "--abbrev-ref", "HEAD"]) ?? ""
        s.base = base(for: s.branch)
        s.dirty = (git(dir, ["status", "--porcelain"]) ?? "").split(separator: "\n").map(String.init)
        s.ahead = Int(git(dir, ["rev-list", "--count", "\(s.base)..HEAD"]) ?? "") ?? 0
        s.unpushed = git(dir, ["rev-list", "--count", "@{u}..HEAD"]).flatMap { Int($0) }
        s.lastCommit = git(dir, ["log", "-1", "--format=%s · %cr"]) ?? ""
        return s
    }

    /// Uncommittete Änderungen und Commits über der Basis als .diff-Datei in VS Code.
    static func openDiff(_ s: RepoState) {
        DispatchQueue.global(qos: .userInitiated).async {
            let log = git(s.dir, ["log", "--stat", "\(s.base)..HEAD"]) ?? ""
            let diff = git(s.dir, ["diff", s.base]) ?? ""
            let dir = buddyDir.appendingPathComponent("diffs")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("\(s.name)-\(s.branch.replacingOccurrences(of: "/", with: "_")).diff")
            try? "# \(s.name) · \(s.branch) gegen \(s.base)\n\n\(log)\n\n\(diff)\n".write(to: file, atomically: true, encoding: .utf8)
            DispatchQueue.main.async { performClick(["-execute", "open -b com.microsoft.VSCode \(shellQuote(file.path))"]) }
        }
    }
}

/// Git-Wurzel eines Pfads (Ordner mit .git-Datei oder -Ordner).
func gitRoot(_ path: String) -> String? {
    var url = URL(fileURLWithPath: path)
    while url.path != "/" {
        if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) { return url.path }
        url.deleteLastPathComponent()
    }
    return nil
}

// MARK: Ansicht

enum AgentTab: String, CaseIterable {
    case overview = "Überblick", history = "Verlauf", changes = "Änderungen", questions = "Rückfragen", usage = "Verbrauch"
}

/// Ein Agent im Detail: Überblick, Verlauf der Turns, Änderungen, Rückfragen und Verbrauch.
struct AgentDetailView: View {
    @ObservedObject var hub: Hub
    let session: Session

    private var s: Session { session }
    private var name: String { hub.store.name(for: s.id) }

    var body: some View {
        let _ = hub.tick
        let log = hub.logs.log(s.transcript)
        VStack(spacing: 0) {
            header(log)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch hub.agentTab {
                    case .overview: overview(log)
                    case .history: history(log)
                    case .changes: changes(log)
                    case .questions: questions
                    case .usage: usage(log)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
        }
    }

    // MARK: Kopf

    private func header(_ log: SessionLog?) -> some View {
        let status = agentStatus(s)
        let ticket = hub.brain.work(forSession: s)?.ticket
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Avatar(look: Look.agent(name), mood: s.mood, prop: hub.prop(s), px: 5)
                    .frame(width: 92, height: 82)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(name) · \(hub.brain.topic(s))").font(.title2.weight(.semibold)).lineLimit(1)
                    if !s.heading.isEmpty { Text(s.heading).foregroundStyle(.secondary) }
                    Text(status.text).font(.callout).foregroundStyle(status.color)
                    if let t = ticket, !t.name.isEmpty {
                        Text("Ticket: \(shorten(t.name, 70)) · \(t.status)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if !s.click.isEmpty { Button("Zur Session") { performClick(s.click) } }
                Button { hub.agentFilter = nil } label: { Image(systemName: "xmark") }
                    .keyboardShortcut(.cancelAction)
                    .help("Zurück zur Übersicht (Esc)")
            }
            Picker("", selection: $hub.agentTab) {
                Text("Überblick").tag(AgentTab.overview)
                Text("Verlauf (\(log?.turns.count ?? 0))").tag(AgentTab.history)
                Text("Änderungen (\(log?.files.count ?? 0))").tag(AgentTab.changes)
                Text("Rückfragen (\(messages.filter { !$0.read }.count))").tag(AgentTab.questions)
                Text("Verbrauch").tag(AgentTab.usage)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(12)
    }

    // MARK: Überblick

    @ViewBuilder private func overview(_ log: SessionLog?) -> some View {
        let turns = log?.turns.filter { !$0.prompt.isEmpty } ?? []
        let work = hub.brain.work(forSession: s)
        let problems = hub.problems(s.id)
        if !problems.isEmpty {
            box("Auffällig") {
                ForEach(Array(problems.enumerated()), id: \.offset) { _, p in Text("⚠️ \(p.text)").font(.callout).foregroundStyle(.orange) }
            }
        }
        box("Auftrag") {
            Text(turns.last?.prompt ?? hub.peeker.peek(s.transcript)?.prompt ?? "–").textSelection(.enabled)
            if let t = turns.last { Text(t.start.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.tertiary) }
        }
        if s.mood == .working {
            box("Läuft gerade") {
                Text("⚙️ \(s.detail.isEmpty ? "denkt nach" : s.detail)").font(.callout.monospaced()).textSelection(.enabled)
                Text("\(s.tools ?? 0) Werkzeugaufrufe in diesem Turn").font(.caption).foregroundStyle(.secondary)
            }
        } else if s.mood == .waiting {
            box("Wartet auf dich") {
                Text(s.detail.isEmpty ? s.text : "will: \(s.detail)\n\(s.text)").font(.callout).textSelection(.enabled)
            }
        }
        box("Letzte Antwort") {
            Text(log?.turns.last?.answer.nilIfEmpty ?? s.text.nilIfEmpty ?? "–").font(.callout).textSelection(.enabled)
        }
        if turns.count > 1 {
            box("Frühere Aufträge") {
                ForEach(Array(turns.dropLast().suffix(10).reversed().enumerated()), id: \.offset) { _, t in
                    HStack(alignment: .top, spacing: 6) {
                        Text(t.start.formatted(date: .omitted, time: .shortened)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                        Text(t.prompt).font(.caption).lineLimit(2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        box("Kontext") {
            let peek = hub.peeker.peek(s.transcript)
            let facts: [(String, String)] = [
                ("Workspace", work?.workspace?.slug ?? s.project),
                ("Branches", work?.workspace.map { $0.branches.map { "\(sideName($0.key)): \($0.value)" }.sorted().joined(separator: " · ") } ?? ""),
                ("Ordner", s.root),
                ("Modell", log?.model.nilIfEmpty ?? peek?.model ?? ""),
                ("Kontext", peek.map { "\($0.context / 1000)k Tokens" } ?? ""),
            ]
            ForEach(facts.filter { !$0.1.isEmpty }, id: \.0) { f in
                HStack(alignment: .top) {
                    Text(f.0).font(.caption).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                    Text(f.1).font(.caption).textSelection(.enabled)
                }
            }
        }
        Flow {
            if !s.click.isEmpty { Button("Zur Session") { performClick(s.click) } }
            Button("Session fortsetzen") { resumeSession(Trail(session: s.id, root: s.root)) }
                .help("Neuer Warp-Tab, `claude --resume` liegt in der Zwischenablage")
            ForEach(Array((work.map { hub.brain.works.actions(for: $0) } ?? []).enumerated()), id: \.offset) { _, a in
                if !a.0.hasPrefix("Zu ") { Button(a.0) { hub.act(a.1) } }
            }
        }
        .controlSize(.small)
    }

    // MARK: Verlauf

    @ViewBuilder private func history(_ log: SessionLog?) -> some View {
        if let log {
            if log.turns.isEmpty { Text("Noch keine Turns.").foregroundStyle(.secondary) }
            ForEach(Array(log.turns.enumerated().reversed()), id: \.offset) { i, t in
                turn(t, index: i, last: i == log.turns.count - 1)
            }
        } else {
            ProgressView("Lese Transkript …")
        }
    }

    private func turn(_ t: Turn, index: Int, last: Bool) -> some View {
        let key = "turn-\(s.id)-\(index)"
        let open = hub.expanded.contains(key)
        let running = last && s.mood == .working
        let outcome = running ? "⚙️ läuft" : last && s.mood == .waiting ? "✋ wartet" : t.asked ? "❓ Rückfrage" : "✅ fertig"
        var meta = [t.start.formatted(date: .abbreviated, time: .shortened), duration((running ? Date() : t.end).timeIntervalSince(t.start)),
                    "\(t.tools.count) Werkzeuge", outcome]
        if t.errors > 0 { meta.append("\(t.errors) Fehler") }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption2).foregroundStyle(.tertiary).padding(.top, 4)
                VStack(alignment: .leading, spacing: 3) {
                    Text(meta.joined(separator: " · ")).font(.caption).foregroundStyle(t.errors > 0 ? .orange : .secondary)
                    Text(t.prompt.nilIfEmpty ?? "(Fortsetzung)").font(.callout.weight(.medium)).lineLimit(open ? nil : 2).textSelection(.enabled)
                    if !t.answer.isEmpty {
                        Text(t.answer).font(.callout).foregroundStyle(.secondary).lineLimit(open ? nil : 3).textSelection(.enabled)
                    }
                }
            }
            if open && !t.tools.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(t.tools.suffix(300).enumerated()), id: \.offset) { _, c in
                        HStack(alignment: .top, spacing: 6) {
                            Text(c.at.formatted(date: .omitted, time: .standard)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                            Text(c.name).font(.caption2.weight(.semibold)).foregroundStyle(c.error ? .red : .primary).frame(width: 90, alignment: .leading)
                            Text(c.detail).font(.caption2.monospaced()).foregroundStyle(c.error ? .red : .secondary).lineLimit(2).textSelection(.enabled)
                        }
                    }
                }
                .padding(.leading, 18)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(running ? 0.07 : 0.035)))
        .contentShape(Rectangle())
        .onTapGesture { if open { hub.expanded.remove(key) } else { hub.expanded.insert(key) } }
    }

    // MARK: Änderungen

    private func repos(_ log: SessionLog?) -> [String] {
        var dirs: [String] = []
        if let ws = hub.brain.work(forSession: s)?.workspace {
            dirs += ws.branches.keys.sorted().map { ws.dir.appendingPathComponent($0).path }
        }
        for f in (log?.files.keys).map(Array.init) ?? [] { if let r = gitRoot(f) { dirs.append(r) } }
        if dirs.isEmpty, let r = gitRoot(s.root) { dirs.append(r) }
        var seen = Set<String>()
        return dirs.filter { seen.insert($0).inserted }
    }

    @ViewBuilder private func changes(_ log: SessionLog?) -> some View {
        let work = hub.brain.work(forSession: s)
        ForEach(repos(log), id: \.self) { dir in
            if let r = hub.git.state(dir) { repo(r) } else { box(URL(fileURLWithPath: dir).lastPathComponent) { ProgressView().controlSize(.small) } }
        }
        if let w = work, !w.changes.isEmpty {
            box("MRs") {
                ForEach(w.changes.sorted { $0.side < $1.side }, id: \.key) { c in
                    HStack(spacing: 6) {
                        Text(c.isOpen ? (["failed": "🔴", "running": "⏳", "pending": "⏳", "success": "🟢"][c.pipeline] ?? "⚪️") : "🎉")
                        Text("\(c.side) · \(cleanTitle(c.title))").font(.callout).lineLimit(1)
                        Spacer()
                        Text(mrState(c)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Button("Öffnen") { openURL(c.url) }.controlSize(.small)
                    }
                    if c.needsHelp { ChangeExtras(hub: hub, change: c).padding(.leading, 24) }
                }
            }
        }
        if let log {
            box("Vom Agenten bearbeitete Dateien (\(log.files.count))") {
                if log.files.isEmpty { Text("Noch nichts bearbeitet.").font(.callout).foregroundStyle(.secondary) }
                ForEach(log.files.sorted { $0.key < $1.key }, id: \.key) { f in
                    HStack(spacing: 6) {
                        Text(relative(f.key)).font(.caption.monospaced()).lineLimit(1).truncationMode(.head)
                        Spacer()
                        Text("\(f.value)×").font(.caption).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { performClick(["-execute", "open -b com.microsoft.VSCode \(shellQuote(f.key))"]) }
                    .help("In VS Code öffnen")
                }
            }
        }
    }

    private func repo(_ r: RepoState) -> some View {
        box("\(sideName(r.name)) · \(r.branch)") {
            let push = r.unpushed.map { $0 == 0 ? "alles gepusht" : "\($0) nicht gepusht" } ?? "kein Upstream, nicht gepusht"
            Text("\(r.ahead) Commits über \(r.base) · \(r.dirty.count) uncommittete Dateien · \(push)").font(.callout)
            if !r.lastCommit.isEmpty { Text("Letzter Commit: \(r.lastCommit)").font(.caption).foregroundStyle(.secondary) }
            if !r.dirty.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(r.dirty.prefix(20).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                    if r.dirty.count > 20 { Text("… und \(r.dirty.count - 20) weitere").font(.caption2).foregroundStyle(.tertiary) }
                }
            }
            Flow {
                Button("Diff anzeigen") { GitStates.openDiff(r) }
                Button("Ordner in VS Code") { performClick(["-execute", "open -b com.microsoft.VSCode \(shellQuote(r.dir))"]) }
            }
            .controlSize(.small)
        }
    }

    private func mrState(_ c: Change) -> String {
        guard c.isOpen else { return "gemergt" }
        var out: [String] = []
        if c.draft { out.append("Draft") }
        if let p = ["failed": "Pipeline rot", "running": "Pipeline läuft", "pending": "Pipeline wartet", "success": "Pipeline grün"][c.pipeline] { out.append(p) }
        if c.conflict { out.append("Konflikt") }
        if c.review == "approved" { out.append("freigegeben") }
        if c.review == "changes" { out.append("Änderungen gewünscht") }
        if c.open > 0 { out.append("\(c.open) offene Punkte") }
        return out.joined(separator: " · ")
    }

    private func relative(_ path: String) -> String {
        for prefix in [s.root, workspacesDir.path, homeURL.path] where !prefix.isEmpty && path.hasPrefix(prefix + "/") {
            return String(path.dropFirst(prefix.count + 1))
        }
        return path
    }

    // MARK: Rückfragen

    private var messages: [Message] {
        let key = hub.brain.works.key(forProject: s.project)
        return hub.inbox.all.values
            .filter { $0.archived == nil && ($0.id == s.id || hub.brain.workKey($0) == key) }
            .sorted { $0.updated > $1.updated }
    }

    @ViewBuilder private var questions: some View {
        let list = messages
        if s.mood == .waiting {
            box("Wartet gerade") {
                Text(s.detail.isEmpty ? s.text : "will: \(s.detail)\n\(s.text)").font(.callout).textSelection(.enabled)
                if !s.click.isEmpty { Button("Zur Session") { performClick(s.click) }.controlSize(.small) }
            }
        }
        if list.isEmpty { Text("Keine offenen Meldungen zu \(name).").foregroundStyle(.secondary) }
        VStack(spacing: 0) {
            ForEach(list, id: \.id) { m in
                MessageRow(hub: hub, m: m)
                Divider()
            }
        }
    }

    // MARK: Verbrauch

    @ViewBuilder private func usage(_ log: SessionLog?) -> some View {
        if let log {
            let facts: [(String, String)] = [
                ("Modell", log.model), ("Turns", "\(log.turns.count)"), ("Werkzeugaufrufe", "\(log.tools)"),
                ("Fehlgeschlagen", "\(log.errors)"), ("Modellaufrufe", "\(log.calls)"),
                ("Output-Tokens", "\(log.output / 1000)k"), ("Arbeitszeit", duration(log.worked)),
                ("Kontext jetzt", "\((log.usage.last?.context ?? 0) / 1000)k"), ("Kontext max", "\((log.usage.map(\.context).max() ?? 0) / 1000)k"),
            ]
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], alignment: .leading, spacing: 10) {
                ForEach(facts, id: \.0) { f in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.1).font(.title3.weight(.semibold).monospacedDigit())
                        Text(f.0).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if log.usage.count > 1 {
                box("Kontext über die Zeit (k Tokens)") {
                    Chart(Array(log.usage.enumerated()), id: \.offset) { _, u in
                        LineMark(x: .value("Zeit", u.at), y: .value("Kontext", u.context / 1000))
                            .foregroundStyle(Color(nsColor: Look.agent(name).dark))
                    }
                    .frame(height: 180)
                }
            }
            let counts = Dictionary(grouping: log.turns.flatMap(\.tools), by: \.name).mapValues(\.count).sorted { $0.value > $1.value }
            if let top = counts.first?.value {
                box("Werkzeuge") {
                    ForEach(counts.prefix(12), id: \.key) { k, n in
                        HStack(spacing: 8) {
                            Text(k).font(.caption).frame(width: 110, alignment: .leading)
                            GeometryReader { g in
                                RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: Look.agent(name).body))
                                    .frame(width: max(4, g.size.width * CGFloat(n) / CGFloat(top)))
                            }
                            .frame(height: 10)
                            Text("\(n)").font(.caption.monospacedDigit()).frame(width: 40, alignment: .trailing)
                        }
                    }
                }
            }
        } else {
            ProgressView("Lese Transkript …")
        }
    }

    // MARK: Bausteine

    private func box<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.035)))
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
