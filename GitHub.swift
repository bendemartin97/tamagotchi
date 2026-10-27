import Foundation

/// Beobachtet GitHub-PRs in anny-co, an denen Martin beteiligt ist (eine GraphQL-Suche alle 3 Minuten):
/// Reviews, Änderungswünsche, Checks, Merge-Konflikte, Review-Anfragen. Gemergte PRs der letzten 3 Tage werden
/// darauf kontrolliert, ob ihre Änderung noch im Zielbranch steckt (der GitLab-Mirror force-pusht gelegentlich darüber).
final class GitHubWatch {
    var onSignals: (([Signal]) -> Void)?
    private var me: String?
    private var running = false
    private let gh = "/opt/homebrew/bin/gh"

    private let query = """
    query($q: String!) { search(query: $q, type: ISSUE, first: 60) { nodes { ... on PullRequest {
      number title url state isDraft headRefName baseRefName mergeable mergedAt reviewDecision
      author { login __typename ... on User { name } }
      repository { nameWithOwner name }
      mergeCommit { oid }
      reviews(last: 20) { nodes { state submittedAt author { login __typename ... on User { name } } } }
      reviewThreads(last: 40) { nodes { isResolved comments(last: 1) { nodes { createdAt author { login __typename ... on User { name } } } } } }
      comments(last: 20) { nodes { createdAt author { login __typename ... on User { name } } } }
      reviewRequests(first: 10) { nodes { requestedReviewer { ... on User { login } } } }
      commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
    } } } }
    """

    init() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { self.poll() }
        Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func poll() {
        guard !running else { return }
        running = true
        let before = State.shared.data.changes.filter { $0.value.host == "github" }
        let baseline = State.shared.data.checked["github"] == nil
        DispatchQueue.global(qos: .utility).async {
            let result = self.check(before)
            DispatchQueue.main.async {
                self.running = false
                guard let (changes, signals) = result else { return }
                for key in before.keys where changes[key] == nil { State.shared.data.changes[key] = nil }
                for (k, c) in changes { State.shared.data.changes[k] = c }
                State.shared.checked("github")
                if !baseline { self.onSignals?(signals) }
            }
        }
    }

    private func search(_ q: String) -> [[String: Any]]? {
        let data = cli(gh, ["api", "graphql", "-F", "q=\(q)", "-f", "query=\(query)"])
        return (((json(data) as? [String: Any])?["data"] as? [String: Any])?["search"] as? [String: Any])?["nodes"] as? [[String: Any]]
    }

    private func check(_ known: [String: Change]) -> ([String: Change], [Signal])? {
        if me == nil { me = json(cli(gh, ["api", "user"])).flatMap { ($0 as? [String: Any])?["login"] as? String } }
        guard let me, let open = search("is:pr is:open involves:@me org:anny-co") else { return nil }
        let day = ISO8601DateFormatter.string(from: Date().addingTimeInterval(-3 * 86400), timeZone: .current, formatOptions: [.withFullDate])
        let merged = search("is:pr is:merged involves:@me org:anny-co merged:>=\(day)") ?? []

        var out: [String: Change] = [:]
        var signals: [Signal] = []
        for n in open {
            guard var c = change(n, me: me), c.mine || c.reviewer else { continue }
            let old = known[c.key]
            let foreign = activity(n, me: me)
            c.lastForeign = foreign.map(\.at).max() ?? old?.lastForeign
            out[c.key] = c
            guard let old else {
                if c.reviewer && !c.draft { signals.append(Signal(kind: .reviewRequested, change: c, who: [name(n["author"])])) }
                continue
            }
            if c.reviewer && !c.draft && (!old.reviewer || old.draft) {
                signals.append(Signal(kind: .reviewRequested, change: c, who: [name(n["author"])]))
            }
            guard c.mine else { continue }
            if c.pipeline == "failed" && old.pipeline != "failed" { signals.append(Signal(kind: .failed, change: c)) }
            if c.pipeline == "success" && old.pipeline == "failed" { signals.append(Signal(kind: .fixed, change: c)) }
            if c.conflict && !old.conflict { signals.append(Signal(kind: .conflict, change: c)) }
            if c.review == "changes" && old.review != "changes" {
                let who = foreign.filter { $0.kind == "CHANGES_REQUESTED" }.map(\.who)
                signals.append(Signal(kind: .changes, change: c, who: who))
            } else if c.review == "approved" && old.review != "approved" {
                signals.append(Signal(kind: .approved, change: c, who: foreign.filter { $0.kind == "APPROVED" }.map(\.who)))
            }
            let fresh = foreign.filter { $0.at > (old.lastForeign ?? old.seen) && $0.kind != "APPROVED" && $0.kind != "CHANGES_REQUESTED" }
            if !fresh.isEmpty { signals.append(Signal(kind: .comment, change: c, who: fresh.map(\.who), count: fresh.count)) }
        }
        for n in merged {
            guard var c = change(n, me: me) else { continue }
            let old = known[c.key]
            c.lost = old?.lost ?? ""
            c.lostChecked = old?.lostChecked
            if old?.isOpen == true && c.mine { signals.append(Signal(kind: .merged, change: c)) }
            if let s = verify(&c) { signals.append(s) }
            out[c.key] = c
        }
        // Verschwundene offene PRs: gemergt (dann oben schon erfasst) oder geschlossen.
        for (key, old) in known where out[key] == nil {
            if old.isOpen { continue }
            if old.state == "merged", (old.mergedAt ?? .distantPast) > Date().addingTimeInterval(-7 * 86400) { out[key] = old }
        }
        return (out, signals)
    }

    private func change(_ n: [String: Any], me: String) -> Change? {
        guard let number = n["number"] as? Int, let repo = n["repository"] as? [String: Any],
              let full = repo["nameWithOwner"] as? String else { return nil }
        var c = Change(key: "gh:\(full)#\(number)", host: "github", api: "repos/\(full)", repo: repo["name"] as? String ?? full,
                       number: number, title: n["title"] as? String ?? "", url: n["url"] as? String ?? "",
                       branch: n["headRefName"] as? String ?? "", target: n["baseRefName"] as? String ?? "")
        c.author = (n["author"] as? [String: Any])?["login"] as? String ?? ""
        c.who = name(n["author"])
        c.mine = c.author == me
        c.reviewer = ((n["reviewRequests"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? [])
            .contains { ($0["requestedReviewer"] as? [String: Any])?["login"] as? String == me }
        c.draft = n["isDraft"] as? Bool ?? false
        switch n["state"] as? String {
        case "MERGED": c.state = "merged"
        case "CLOSED": c.state = "closed"
        default: c.state = "opened"
        }
        c.mergedAt = parseDate(n["mergedAt"])
        c.mergeSha = (n["mergeCommit"] as? [String: Any])?["oid"] as? String ?? ""
        c.conflict = n["mergeable"] as? String == "CONFLICTING"
        switch n["reviewDecision"] as? String {
        case "CHANGES_REQUESTED": c.review = "changes"
        case "APPROVED": c.review = "approved"
        default: c.review = ""
        }
        let rollup = ((((n["commits"] as? [String: Any])?["nodes"] as? [[String: Any]])?.first?["commit"] as? [String: Any])?["statusCheckRollup"] as? [String: Any])?["state"] as? String
        switch rollup {
        case "SUCCESS": c.pipeline = "success"
        case "FAILURE", "ERROR": c.pipeline = "failed"
        case "PENDING", "EXPECTED": c.pipeline = "running"
        default: c.pipeline = ""
        }
        let threads = ((n["reviewThreads"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        c.open = threads.filter { t in
            guard t["isResolved"] as? Bool != true,
                  let last = (((t["comments"] as? [String: Any])?["nodes"] as? [[String: Any]])?.last)?["author"] as? [String: Any] else { return false }
            return last["login"] as? String != me
        }.count
        return c
    }

    /// Reviews und Kommentare von Menschen außer Martin.
    private func activity(_ n: [String: Any], me: String) -> [(who: String, at: Date, kind: String)] {
        var out: [(String, Date, String)] = []
        func human(_ a: Any?) -> Bool {
            guard let a = a as? [String: Any] else { return false }
            return a["__typename"] as? String == "User" && a["login"] as? String != me
        }
        for r in ((n["reviews"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? [] where human(r["author"]) {
            if let at = parseDate(r["submittedAt"]), let state = r["state"] as? String, state != "PENDING" { out.append((name(r["author"]), at, state)) }
        }
        for t in ((n["reviewThreads"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? [] {
            for c in ((t["comments"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? [] where human(c["author"]) {
                if let at = parseDate(c["createdAt"]) { out.append((name(c["author"]), at, "THREAD")) }
            }
        }
        for c in ((n["comments"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? [] where human(c["author"]) {
            if let at = parseDate(c["createdAt"]) { out.append((name(c["author"]), at, "COMMENT")) }
        }
        return out
    }

    /// Vorname statt Login: GitHub-Name, sonst ein von GitLab bekannter Vorname, mit dem der Login beginnt
    /// („lucianholt97“ → „Lucian“). Cursor-Agenten heißen Cursor.
    private func name(_ a: Any?) -> String {
        let a = a as? [String: Any]
        let n = a?["name"] as? String ?? ""
        if !n.isEmpty { return firstName(n) }
        let login = a?["login"] as? String ?? ""
        if login.isEmpty { return "Jemand" }
        if login == "cursor" || login == "anny-product" || login.hasSuffix("[bot]") { return "Cursor" }
        let known = Set(State.shared.data.changes.values.filter { $0.host == "gitlab" }.map(\.who))
        return known.first { $0.count >= 3 && login.lowercased().hasPrefix($0.lowercased()) } ?? capitalized(login)
    }

    /// Steckt die gemergte Änderung noch im Zielbranch? Abstammung über compare, sonst Inhalt der geänderten Dateien.
    private func verify(_ c: inout Change) -> Signal? {
        guard !c.mergeSha.isEmpty, c.lost != "lost", (c.mergedAt ?? .distantPast) > Date().addingTimeInterval(-3 * 86400),
              Date().timeIntervalSince(c.lostChecked ?? .distantPast) > 30 * 60 else { return nil }
        guard let cmp = json(cli(gh, ["api", "\(c.api)/compare/\(c.target)...\(c.mergeSha)"])) as? [String: Any],
              let status = cmp["status"] as? String else { return nil }
        c.lostChecked = Date()
        if status == "behind" || status == "identical" { c.lost = "ok"; return nil }
        guard let files = json(cli(gh, ["api", "\(c.api)/pulls/\(c.number)/files?per_page=100"])) as? [[String: Any]] else { return nil }
        let list = files.prefix(15).map { f in
            (path: f["filename"] as? String ?? "", added: addedLines(f["patch"] as? String ?? ""), deleted: f["status"] as? String == "removed")
        }
        let present = contentPresent(list) { path in
            let p = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            return cli(self.gh, ["api", "-H", "Accept: application/vnd.github.raw", "\(c.api)/contents/\(p)?ref=\(c.target)"])
                .flatMap { String(data: $0, encoding: .utf8) }
        }
        c.lost = present ? "ok" : "lost"
        return present ? nil : Signal(kind: .lost, change: c)
    }
}
