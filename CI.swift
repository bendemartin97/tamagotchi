import Foundation

/// Failed CI job with the tail of its log.
struct JobFailure {
    var job: String
    var stage: String
    var url: String
    var tail: String
}

/// For red pipelines, fetches the failed job along with the end of its log (GitLab via glab, GitHub via gh) and collects
/// open review comments so both can be passed to an agent as a task.
final class CIDetails {
    var onUpdate: (() -> Void)?
    private var cache: [String: (at: Date, failure: JobFailure?)] = [:]
    private var busy: Set<String> = []
    private var me: [String: String] = [:]
    private let glabPath = "/opt/homebrew/bin/glab", ghPath = "/opt/homebrew/bin/gh"

    /// nil while loading; afterwards the job, or an empty placeholder if none was found.
    func failure(_ c: Change) -> JobFailure? {
        if !busy.contains(c.key), Date().timeIntervalSince(cache[c.key]?.at ?? .distantPast) > 300 {
            busy.insert(c.key)
            DispatchQueue.global(qos: .utility).async {
                let f = c.host == "github" ? self.githubFailure(c) : self.gitlabFailure(c)
                DispatchQueue.main.async {
                    self.cache[c.key] = (Date(), f ?? JobFailure(job: "", stage: "", url: c.url, tail: "Kein fehlgeschlagener Job gefunden."))
                    self.busy.remove(c.key)
                    self.onUpdate?()
                }
            }
        }
        return cache[c.key]?.failure
    }

    private func text(_ tool: String, _ args: [String]) -> String? {
        cli(tool, args).flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func tail(_ log: String, lines: Int = 60) -> String {
        let clean = log.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "section_(start|end):[0-9]+:[a-z0-9_]+\r?", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r", with: "")
        // gh returns „Job<TAB>Schritt<TAB>Zeitstempel Text“ (job, step, timestamp text); keep only the text.
        let all = clean.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            String(line).replacingOccurrences(of: "^[^\t]*\t[^\t]*\t\\S+Z ", with: "", options: .regularExpression)
        }
        // Cut off cleanup steps after the failure: up to the last error marker.
        let markers = ["##[error]", "ERROR: Job failed", "FAILURES!", "ERRORS!", "Error:", "error TS", "✖"]
        let end = all.lastIndex { l in markers.contains { l.contains($0) } }.map { min(all.count, $0 + 3) } ?? all.count
        return all[..<end].suffix(lines).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func gitlabFailure(_ c: Change) -> JobFailure? {
        guard let pipes = json(cli(glabPath, ["api", "\(c.api)/merge_requests/\(c.number)/pipelines?per_page=1"])) as? [[String: Any]],
              let pid = pipes.first?["id"] as? Int,
              let jobs = json(cli(glabPath, ["api", "\(c.api)/pipelines/\(pid)/jobs?scope%5B%5D=failed&per_page=20"])) as? [[String: Any]],
              let job = jobs.first, let jid = job["id"] as? Int else { return nil }
        let log = text(glabPath, ["api", "\(c.api)/jobs/\(jid)/trace"]) ?? ""
        return JobFailure(job: job["name"] as? String ?? "", stage: job["stage"] as? String ?? "",
                          url: job["web_url"] as? String ?? c.url, tail: Self.tail(log))
    }

    private func githubFailure(_ c: Change) -> JobFailure? {
        let repo = c.api.replacingOccurrences(of: "repos/", with: "")
        guard let pr = json(cli(ghPath, ["pr", "view", "\(c.number)", "--repo", repo, "--json", "statusCheckRollup"])) as? [String: Any],
              let checks = pr["statusCheckRollup"] as? [[String: Any]],
              let failed = checks.first(where: { ["FAILURE", "ERROR", "TIMED_OUT"].contains($0["conclusion"] as? String ?? "") }) else { return nil }
        let url = failed["detailsUrl"] as? String ?? c.url
        var log = ""
        if let r = url.range(of: "/job/([0-9]+)", options: .regularExpression) {
            let jid = url[r].replacingOccurrences(of: "/job/", with: "")
            log = text(ghPath, ["run", "view", "--job", jid, "--log-failed", "--repo", repo]) ?? ""
        }
        return JobFailure(job: failed["name"] as? String ?? "", stage: failed["workflowName"] as? String ?? "", url: url,
                          tail: Self.tail(log.isEmpty ? "Log nicht abrufbar, siehe \(url)" : log))
    }

    // MARK: Review comments

    /// Open, unresolved comments from others on an MR/PR, as a list for a task.
    func openComments(_ c: Change) -> [String] {
        c.host == "github" ? githubComments(c) : gitlabComments(c)
    }

    private func gitlabComments(_ c: Change) -> [String] {
        if me["gitlab"] == nil { me["gitlab"] = (json(cli(glabPath, ["api", "user"])) as? [String: Any])?["username"] as? String }
        guard let discussions = json(cli(glabPath, ["api", "\(c.api)/merge_requests/\(c.number)/discussions?per_page=100"])) as? [[String: Any]] else { return [] }
        var out: [String] = []
        for d in discussions {
            let notes = (d["notes"] as? [[String: Any]] ?? []).filter { $0["system"] as? Bool != true }
            guard let first = notes.first, first["resolvable"] as? Bool == true, first["resolved"] as? Bool != true else { continue }
            let author = (first["author"] as? [String: Any])?["username"] as? String ?? ""
            guard author != me["gitlab"] else { continue }
            let pos = first["position"] as? [String: Any]
            let place = (pos?["new_path"] as? String).map { "\($0)\((pos?["new_line"] as? Int).map { ":\($0)" } ?? "")" } ?? "allgemein"
            let thread = notes.map { n in "\(((n["author"] as? [String: Any])?["name"] as? String) ?? "?"): \(n["body"] as? String ?? "")" }
            out.append("[\(place)] " + thread.joined(separator: "\n  ↳ "))
        }
        return out
    }

    private func githubComments(_ c: Change) -> [String] {
        let parts = c.api.replacingOccurrences(of: "repos/", with: "").split(separator: "/")
        guard parts.count == 2 else { return [] }
        if me["github"] == nil { me["github"] = (json(cli(ghPath, ["api", "user"])) as? [String: Any])?["login"] as? String }
        let query = "query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){reviewThreads(first:100){nodes{isResolved path line comments(first:20){nodes{author{login} body}}}}}}}"
        guard let obj = json(cli(ghPath, ["api", "graphql", "-f", "query=\(query)", "-F", "o=\(parts[0])", "-F", "r=\(parts[1])", "-F", "n=\(c.number)"])) as? [String: Any],
              let threads = (((((obj["data"] as? [String: Any])?["repository"] as? [String: Any])?["pullRequest"] as? [String: Any])?["reviewThreads"] as? [String: Any])?["nodes"] as? [[String: Any]])
        else { return [] }
        var out: [String] = []
        for t in threads where t["isResolved"] as? Bool != true {
            let comments = (t["comments"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
            guard let first = comments.first, ((first["author"] as? [String: Any])?["login"] as? String) != me["github"] else { continue }
            let place = (t["path"] as? String).map { "\($0)\((t["line"] as? Int).map { ":\($0)" } ?? "")" } ?? "allgemein"
            let thread = comments.map { n in "\(((n["author"] as? [String: Any])?["login"] as? String) ?? "?"): \(n["body"] as? String ?? "")" }
            out.append("[\(place)] " + thread.joined(separator: "\n  ↳ "))
        }
        return out
    }

    // MARK: Tasks

    /// Working folder of a change in the workspace, if there is one.
    static func checkout(_ c: Change, in work: Work?) -> String? {
        guard let ws = work?.workspace else { return nil }
        if let repo = ws.branches.first(where: { $0.value == c.branch })?.key { return ws.dir.appendingPathComponent(repo).path }
        return ws.branches[c.repo] != nil ? ws.dir.appendingPathComponent(c.repo).path : nil
    }

    static func fixPrompt(_ c: Change, _ f: JobFailure, dir: String?) -> String {
        """
        Die \(c.side)-Pipeline von \(c.url) (Branch \(c.branch)) ist rot. Fehlgeschlagener Job: \(f.job)\(f.stage.isEmpty ? "" : " (\(f.stage))"), \(f.url).
        Ende des Logs:
        ```
        \(f.tail)
        ```
        \(where_(dir, c)) Finde die Ursache, behebe sie und prüfe den Fix mit dem passenden Test oder Lint. Nicht committen und \
        nicht pushen. Fasse am Ende in wenigen Sätzen zusammen, was die Ursache war und was du geändert hast.
        """
    }

    static func commentsPrompt(_ c: Change, _ comments: [String], dir: String?) -> String {
        """
        An \(c.url) (Branch \(c.branch)) sind diese Review-Kommentare offen:

        \(comments.map { "- " + $0 }.joined(separator: "\n"))

        \(where_(dir, c)) Arbeite die Kommentare ab, wo sie berechtigt sind; wo nicht, begründe kurz. Prüfe mit den passenden \
        Tests oder Lint. Nicht committen, nicht pushen, keine Threads auflösen. Fasse am Ende pro Kommentar in einem Satz zusammen, \
        was du getan hast.
        """
    }

    private static func where_(_ dir: String?, _ c: Change) -> String {
        dir.map { "Arbeite im Workspace-Checkout \($0) auf genau diesem Branch." }
            ?? "Es gibt keinen Workspace mit diesem Branch: ändere keinen Code, sondern analysiere nur und berichte, was zu tun wäre."
    }
}
