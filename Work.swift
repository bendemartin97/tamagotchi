import AppKit

let workspacesDir = homeURL.appendingPathComponent("Development/workspaces")

/// Ein ws-Workspace mit seinen Worktrees (Repo-Name → Branch).
struct Workspace {
    var slug: String
    var dir: URL
    var branches: [String: String]
    var file: URL?
}

/// Eine Aufgabe von Ticket bis Merge: ClickUp-Ticket, Workspace, Branches, MRs/PRs.
struct Work {
    var key: String
    var ticketID: String?
    var ticket: Ticket?
    var workspace: Workspace?
    var changes: [Change] = []
    var topic = ""
}

/// Verknüpft Workspaces, MRs/PRs, Tickets und Sessions über die ClickUp-ID (aus Branch, Titel oder
/// Workspace-Name). Ohne ID gehört eine MR zum Workspace mit ihrem Branch, sonst steht sie allein.
final class Works {
    let store: Store
    /// Offene Feedback-Punkte (von FeedbackWatch), damit auch Workspaces nur mit Feedback als Aufgabe zählen.
    var feedback: () -> [FeedbackItem] = { [] }
    private(set) var workspaces: [String: Workspace] = [:]
    private var scanned = Date.distantPast

    init(store: Store) { self.store = store }

    private var state: Persisted { State.shared.data }

    func rescan() {
        guard Date().timeIntervalSince(scanned) > 30 else { return }
        scanned = Date()
        let fm = FileManager.default
        var found: [String: Workspace] = [:]
        for slug in (try? fm.contentsOfDirectory(atPath: workspacesDir.path)) ?? [] where !slug.hasPrefix(".") {
            let dir = workspacesDir.appendingPathComponent(slug)
            var branches: [String: String] = [:]
            for repo in ["anny-ui", "bookings-api"] {
                if let b = gitBranch(dir.appendingPathComponent(repo)) { branches[repo] = b }
            }
            let file = dir.appendingPathComponent("\(slug).code-workspace")
            found[slug] = Workspace(slug: slug, dir: dir, branches: branches, file: fm.fileExists(atPath: file.path) ? file : nil)
        }
        workspaces = found
    }

    // MARK: Schlüssel

    func key(for c: Change) -> String {
        if let id = ticketID(in: c.branch) ?? ticketID(in: c.title) { return id }
        if let ws = workspaces.values.first(where: { $0.branches.values.contains(c.branch) }) { return key(for: ws) }
        return "chg:" + c.key
    }

    func key(for ws: Workspace) -> String {
        ticketID(in: ws.slug) ?? ws.branches.values.lazy.compactMap(ticketID(in:)).first ?? "ws:" + ws.slug
    }

    func key(forProject project: String) -> String {
        if let ws = workspaces[project] { return key(for: ws) }
        return ticketID(in: project) ?? "proj:" + project
    }

    // MARK: Aufgaben

    /// Alle Aufgaben mit offenen oder kürzlich gemergten Änderungen, laufenden Sessions oder Feedback.
    func all() -> [Work] {
        rescan()
        var works: [String: Work] = [:]
        func add(_ key: String) -> String {
            if works[key] == nil {
                let id = key.contains(":") ? nil : key
                works[key] = Work(key: key, ticketID: id, ticket: id.flatMap { state.tickets[$0] })
            }
            return key
        }
        let recent = Date().addingTimeInterval(-7 * 86400)
        for c in state.changes.values where c.isOpen || (c.mergedAt ?? .distantPast) > recent {
            works[add(key(for: c))]?.changes.append(c)
        }
        var projects = Set(store.agents.map(\.project))
        projects.formUnion(feedback().filter { $0.status != .accepted }.map(\.project))
        for p in projects {
            let k = add(key(forProject: p))
            if let ws = workspaces[p] { works[k]?.workspace = ws }
        }
        for (k, w) in works where w.workspace == nil {
            works[k]?.workspace = workspaces.values.first { ws in
                key(for: ws) == k || w.changes.contains { ws.branches.values.contains($0.branch) }
            }
        }
        return works.values.map { w in
            var w = w
            w.topic = topic(w)
            return w
        }.sorted { $0.topic < $1.topic }
    }

    func work(_ key: String) -> Work? { all().first { $0.key == key } }

    // MARK: Namen

    /// Menschlicher Name einer Aufgabe: Kurzname des Tickets, sonst des MR-Titels, sonst aus dem Workspace.
    func topic(_ w: Work) -> String {
        if let name = ticketName(w.ticketID) { return name }
        if let c = w.changes.first {
            return state.names[c.title] ?? cleanTitle(c.title)
        }
        if let ws = w.workspace { return humanize(ws.slug) }
        return humanize(w.key.replacingOccurrences(of: "^[a-z]+:", with: "", options: .regularExpression))
    }

    func topic(forProject project: String) -> String {
        let k = key(forProject: project)
        if let name = ticketName(k) { return name }
        if let ws = workspaces[project] {
            let w = Work(key: k, ticketID: nil, ticket: state.tickets[k], workspace: ws,
                         changes: state.changes.values.filter { key(for: $0) == k })
            return topic(w)
        }
        return project
    }

    func topic(for c: Change) -> String {
        if let name = ticketName(key(for: c)) { return name }
        return state.names[c.title] ?? cleanTitle(c.title)
    }

    func ticketName(_ id: String?) -> String? {
        guard let id, let t = state.tickets[id] else { return nil }
        if !t.short.isEmpty { return t.short }
        return t.name.isEmpty ? nil : shorten(t.name)
    }

    // MARK: Aktionen

    /// Menüeinträge für eine Aufgabe: Ticket, Workspace, Session, Änderungen.
    func actions(for w: Work) -> [(String, () -> Void)] {
        var out: [(String, () -> Void)] = []
        if let id = w.ticketID {
            let url = w.ticket?.url ?? "https://app.clickup.com/t/\(id)"
            out.append(("Ticket öffnen", { openURL(url) }))
        }
        if let ws = w.workspace {
            out.append(("Workspace öffnen", {
                performClick(["-execute", "open -b com.microsoft.VSCode \(shellQuote((ws.file ?? ws.dir).path))"])
            }))
            if let s = store.agents.first(where: { $0.project == ws.slug }), !s.click.isEmpty {
                out.append(("Zu \(store.name(for: s.id)) springen", { performClick(s.click) }))
            } else if let trail = state.trails[ws.slug], !trail.session.isEmpty {
                out.append(("Session fortsetzen", { resumeSession(trail) }))
            }
        }
        for c in w.changes.sorted(by: { $0.side < $1.side }) {
            let what = c.isOpen ? "ansehen" : "ansehen (gemergt)"
            out.append(("\(c.side)-Änderung \(what)", { openURL(c.url) }))
        }
        return out
    }
}

/// Branch eines Checkouts aus .git/HEAD (auch bei Worktrees mit gitdir-Verweis).
func gitBranch(_ repo: URL) -> String? {
    let git = repo.appendingPathComponent(".git")
    var head = (try? String(contentsOf: git.appendingPathComponent("HEAD"), encoding: .utf8)) ?? ""
    if head.isEmpty, let pointer = try? String(contentsOf: git, encoding: .utf8), pointer.hasPrefix("gitdir: ") {
        let dir = pointer.dropFirst(8).trimmingCharacters(in: .whitespacesAndNewlines)
        head = (try? String(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent("HEAD"), encoding: .utf8)) ?? ""
    }
    let ref = head.trimmingCharacters(in: .whitespacesAndNewlines)
    return ref.hasPrefix("ref: refs/heads/") ? String(ref.dropFirst(16)) : nil
}

/// „fix(calendar): keep a resource open“ → „Keep a resource open“, ohne Ticket-ID.
func cleanTitle(_ title: String) -> String {
    var t = title.replacingOccurrences(of: "(?i)^(draft:\\s*)+", with: "", options: .regularExpression)
    t = t.replacingOccurrences(of: "(?i)^\\[?CU-[0-9a-z]+\\]?[:\\s-]*", with: "", options: .regularExpression)
    t = t.replacingOccurrences(of: "^[a-z]+(\\([^)]*\\))?!?:\\s*", with: "", options: .regularExpression)
    return shorten(capitalized(t))
}

/// „CU-124032dub08_kalender-fixes“ → „Kalender fixes“.
func humanize(_ slug: String) -> String {
    var s = slug.replacingOccurrences(of: "(?i)CU-[0-9a-z]+[_-]?", with: "", options: .regularExpression)
    s = s.replacingOccurrences(of: "_review$|^review$", with: "", options: .regularExpression)
    s = s.replacingOccurrences(of: "[_-]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    return s.isEmpty ? "Ticket-Review" : capitalized(s)
}

func shorten(_ s: String, _ max: Int = 40) -> String {
    guard s.count > max else { return s }
    let cut = s.prefix(max)
    return (cut.range(of: " ", options: .backwards).map { String(cut[..<$0.lowerBound]) } ?? String(cut)) + "…"
}

func openURL(_ url: String) {
    if let u = URL(string: url) { NSWorkspace.shared.open(u) }
}

/// Neuer Warp-Tab im Startordner der Session; `claude --resume …` liegt in der Zwischenablage.
func resumeSession(_ trail: Trail) {
    let cmd = "claude --resume \(trail.session)"
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(cmd, forType: .string)
    let path = trail.root.isEmpty ? homeURL.appendingPathComponent("Development").path : trail.root
    var c = URLComponents(string: "warp://action/new_tab")!
    c.queryItems = [URLQueryItem(name: "path", value: path)]
    if let u = c.url { NSWorkspace.shared.open(u) }
}
