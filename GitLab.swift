import Foundation

/// Fragt alle 3 Minuten per glab Martins offene MRs, Review-Anfragen an ihn und kürzlich gemergte MRs ab.
/// Der Stand liegt in state.json, Wechsel seit der letzten Abfrage (auch über einen Neustart hinweg) gehen als
/// Signale an den Notifier.
final class GitLabWatch {
    var onSignals: (([Signal]) -> Void)?
    private var me: String?
    private var running = false

    init() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.poll() }
        Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func glab(_ path: String) -> Any? { json(cli("/opt/homebrew/bin/glab", ["api", path])) }

    private func poll() {
        guard !running else { return }
        running = true
        let before = State.shared.data.changes.filter { $0.value.host == "gitlab" }
        let baseline = State.shared.data.checked["gitlab"] == nil
        DispatchQueue.global(qos: .utility).async {
            let result = self.check(before)
            DispatchQueue.main.async {
                self.running = false
                guard let (changes, signals) = result else { return }
                for (k, c) in changes { State.shared.data.changes[k] = c }
                State.shared.checked("gitlab")
                if !baseline { self.onSignals?(signals) }
            }
        }
    }

    private func check(_ known: [String: Change]) -> ([String: Change], [Signal])? {
        if me == nil { me = (glab("user") as? [String: Any])?["username"] as? String }
        guard let me else { return nil }
        let since = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-14 * 86400))
        let recent = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3 * 86400))
        guard let mine = glab("merge_requests?scope=created_by_me&state=opened&per_page=50&updated_after=\(since)") as? [[String: Any]],
              let review = glab("merge_requests?scope=all&reviewer_username=\(me)&state=opened&per_page=50") as? [[String: Any]]
        else { return nil }
        let merged = glab("merge_requests?scope=created_by_me&state=merged&per_page=30&updated_after=\(recent)") as? [[String: Any]] ?? []

        var out: [String: Change] = [:]
        var signals: [Signal] = []
        var listed: [(m: [String: Any], mine: Bool, reviewer: Bool)] = mine.map { ($0, true, false) }
        for m in review {
            if let i = listed.firstIndex(where: { $0.m["id"] as? Int == m["id"] as? Int }) { listed[i].reviewer = true }
            else { listed.append((m, false, true)) }
        }
        for (m, isMine, isReviewer) in listed {
            guard var c = change(m) else { continue }
            let old = known[c.key]
            c.mine = isMine
            c.reviewer = isReviewer
            c.lastForeign = old?.lastForeign
            let detail = glab("\(c.api)/merge_requests/\(c.number)") as? [String: Any]
            c.pipeline = (detail?["head_pipeline"] as? [String: Any])?["status"] as? String ?? ""
            if c.pipeline == "created" || c.pipeline == "waiting_for_resource" || c.pipeline == "preparing" { c.pipeline = "pending" }
            c.conflict = m["has_conflicts"] as? Bool ?? false
            c.open = m["detailed_merge_status"] as? String == "discussions_not_resolved" ? max(1, old?.open ?? 1) : 0
            if let reviewers = glab("\(c.api)/merge_requests/\(c.number)/reviewers") as? [[String: Any]] {
                let states = reviewers.filter { ($0["user"] as? [String: Any])?["username"] as? String != me }.compactMap { $0["state"] as? String }
                c.review = states.contains("requested_changes") ? "changes" : states.contains("approved") ? "approved" : ""
            }
            out[c.key] = c
            guard let old else {
                if isReviewer { signals.append(Signal(kind: .reviewRequested, change: c, who: [authorName(m)])) }
                continue
            }
            if isReviewer && !old.reviewer { signals.append(Signal(kind: .reviewRequested, change: c, who: [authorName(m)])) }
            guard isMine else { continue }
            if c.pipeline == "failed" && old.pipeline != "failed" { signals.append(Signal(kind: .failed, change: c)) }
            if c.pipeline == "success" && old.pipeline == "failed" { signals.append(Signal(kind: .fixed, change: c)) }
            if c.conflict && !old.conflict { signals.append(Signal(kind: .conflict, change: c)) }
            if c.review == "changes" && old.review != "changes" { signals.append(Signal(kind: .changes, change: c)) }
            if c.review == "approved" && old.review == "" { signals.append(Signal(kind: .approved, change: c)) }
            if c.notes > old.notes, let s = comments(c, since: old.seen, me: me) {
                c.lastForeign = Date()
                out[c.key] = c
                signals.append(s)
            }
        }

        for m in merged {
            guard var c = change(m) else { continue }
            let old = known[c.key]
            c.mine = true
            c.state = "merged"
            c.mergedAt = parseDate(m["merged_at"])
            c.mergeSha = (m["squash_commit_sha"] as? String) ?? (m["merge_commit_sha"] as? String) ?? (m["sha"] as? String) ?? ""
            c.lost = old?.lost ?? ""
            c.lostChecked = old?.lostChecked
            if old?.isOpen == true { signals.append(Signal(kind: .merged, change: c)) }
            if let s = verify(&c) { signals.append(s) }
            out[c.key] = c
        }
        // Verschwunden, aber nicht unter den gemergten: geschlossen.
        for (key, old) in known where old.isOpen && out[key] == nil {
            var c = old
            c.state = (glab("\(old.api)/merge_requests/\(old.number)") as? [String: Any])?["state"] as? String ?? "closed"
            if c.state == "merged" { signals.append(Signal(kind: .merged, change: c)) }
            out[key] = c
        }
        // Gemergte, die aus der Liste gefallen sind, bis 3 Tage nach dem Merge weiter kontrollieren.
        for (key, old) in known where out[key] == nil && old.state == "merged" {
            var c = old
            if let s = verify(&c) { signals.append(s) }
            if (c.mergedAt ?? .distantPast) > Date().addingTimeInterval(-7 * 86400) { out[key] = c }
        }
        let stale = Set(known.keys).subtracting(out.keys)
        for key in stale { DispatchQueue.main.async { State.shared.data.changes[key] = nil } }
        return (out, signals)
    }

    private func change(_ m: [String: Any]) -> Change? {
        guard let pid = m["project_id"] as? Int, let iid = m["iid"] as? Int else { return nil }
        let url = m["web_url"] as? String ?? ""
        let repo = url.components(separatedBy: "/-/").first?.split(separator: "/").last.map(String.init) ?? "MR"
        var c = Change(key: "gl:\(pid)!\(iid)", host: "gitlab", api: "projects/\(pid)", repo: repo, number: iid,
                       title: m["title"] as? String ?? "", url: url, branch: m["source_branch"] as? String ?? "",
                       target: m["target_branch"] as? String ?? "")
        c.author = (m["author"] as? [String: Any])?["username"] as? String ?? ""
        c.who = authorName(m)
        c.draft = m["draft"] as? Bool ?? false
        c.notes = m["user_notes_count"] as? Int ?? 0
        c.state = m["state"] as? String ?? "opened"
        return c
    }

    private func authorName(_ m: [String: Any]) -> String {
        firstName((m["author"] as? [String: Any])?["name"] as? String ?? "Jemand")
    }

    /// Neue Kommentare von anderen seit `since`, gebündelt.
    private func comments(_ c: Change, since: Date, me: String) -> Signal? {
        guard let notes = glab("\(c.api)/merge_requests/\(c.number)/notes?sort=desc&order_by=created_at&per_page=30") as? [[String: Any]]
        else { return nil }
        let fresh = notes.filter { n in
            n["system"] as? Bool != true && ((n["author"] as? [String: Any])?["username"] as? String) != me
                && (parseDate(n["created_at"]) ?? .distantPast) > since
        }
        guard !fresh.isEmpty else { return nil }
        let who = fresh.compactMap { ($0["author"] as? [String: Any])?["name"] as? String }.map(firstName)
        let body = (fresh.last?["body"] as? String ?? "").replacingOccurrences(of: "\n", with: " ")
        return Signal(kind: .comment, change: c, who: who, count: fresh.count, excerpt: body)
    }

    /// Ist die gemergte Änderung noch im Zielbranch? Erst über die Abstammung, sonst über den Inhalt
    /// (Squash, Rebase, Wiederherstellung).
    private func verify(_ c: inout Change) -> Signal? {
        guard !c.mergeSha.isEmpty, c.lost != "lost", (c.mergedAt ?? .distantPast) > Date().addingTimeInterval(-3 * 86400),
              Date().timeIntervalSince(c.lostChecked ?? .distantPast) > 30 * 60 else { return nil }
        let target = c.target.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? c.target
        guard let base = glab("\(c.api)/repository/merge_base?refs[]=\(c.mergeSha)&refs[]=\(target)") as? [String: Any] else { return nil }
        c.lostChecked = Date()
        if base["id"] as? String == c.mergeSha { c.lost = "ok"; return nil }
        guard let diffs = glab("\(c.api)/merge_requests/\(c.number)/diffs?per_page=50") as? [[String: Any]] else { return nil }
        let files = diffs.prefix(15).map { d in
            (path: d["new_path"] as? String ?? "", added: addedLines(d["diff"] as? String ?? ""), deleted: d["deleted_file"] as? Bool ?? false)
        }
        let present = contentPresent(files) { path in
            let p = path.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? path
            return cli("/opt/homebrew/bin/glab", ["api", "\(c.api)/repository/files/\(p)/raw?ref=\(target)"]).flatMap { String(data: $0, encoding: .utf8) }
        }
        c.lost = present ? "ok" : "lost"
        return present ? nil : Signal(kind: .lost, change: c)
    }
}

func firstName(_ name: String) -> String { name.split(separator: " ").first.map(String.init) ?? name }
