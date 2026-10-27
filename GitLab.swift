import Foundation

/// Fragt alle 3 Minuten per glab Martins offene MRs der letzten 14 Tage ab und meldet Wechsel:
/// Pipeline rot / wieder grün, neuer Kommentar von jemand anderem, gemergt. Der erste Lauf merkt sich
/// nur den Stand.
final class GitLabWatch {
    struct MR { var pid: Int; var iid: Int; var title: String; var url: String; var project: String; var pipeline: String; var notes: Int }

    let store: Store
    var onEvent: ((String) -> Void)?
    private var known: [String: MR]?
    private var me: String?
    private var running = false
    /// Kurzfassung für die [Lage]-Zeile im Chat (nur auf dem Main-Thread lesen).
    private(set) var summary = ""

    init(store: Store) {
        self.store = store
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.poll() }
        Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func glab(_ path: String) -> Any? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/glab")
        p.arguments = ["api", path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? try? JSONSerialization.jsonObject(with: data) : nil
    }

    private func poll() {
        guard !running else { return }
        running = true
        DispatchQueue.global(qos: .utility).async {
            let alerts = self.check()
            let red = (self.known ?? [:]).values.filter { $0.pipeline == "failed" }.map(\.project)
            let summary = self.known.map { "\($0.count) offene MRs" + (red.isEmpty ? "" : ", Pipeline rot: " + red.joined(separator: ", ")) } ?? ""
            DispatchQueue.main.async {
                self.running = false
                self.summary = summary
                for (kind, s) in alerts {
                    self.store.post(s)
                    self.onEvent?(kind)
                }
            }
        }
    }

    private func check() -> [(String, Session)] {
        if me == nil { me = (glab("user") as? [String: Any])?["username"] as? String }
        let since = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-14 * 86400))
        guard let list = glab("merge_requests?scope=created_by_me&state=opened&per_page=50&updated_after=\(since)") as? [[String: Any]]
        else { return [] }

        var now: [String: MR] = [:]
        for m in list {
            guard let pid = m["project_id"] as? Int, let iid = m["iid"] as? Int else { continue }
            let url = m["web_url"] as? String ?? ""
            let repo = url.components(separatedBy: "/-/").first?.split(separator: "/").last.map(String.init) ?? "MR"
            let detail = glab("projects/\(pid)/merge_requests/\(iid)") as? [String: Any]
            let pipeline = (detail?["head_pipeline"] as? [String: Any])?["status"] as? String ?? ""
            now["\(pid)!\(iid)"] = MR(pid: pid, iid: iid, title: m["title"] as? String ?? "", url: url,
                                      project: "\(repo) !\(iid)", pipeline: pipeline, notes: m["user_notes_count"] as? Int ?? 0)
        }
        defer { known = now }
        guard let known else { return [] }

        func alert(_ mr: MR, _ mood: Mood, _ icon: String, _ text: String) -> Session {
            Session(id: "mr-\(mr.pid)-\(mr.iid)", mood: mood, project: mr.project, agent: "GitLab", text: text,
                    icon: icon, click: ["-execute", "open \(shellQuote(mr.url))"], isAgent: false)
        }

        var alerts: [(String, Session)] = []
        for (key, mr) in now {
            guard let old = known[key] else { continue }
            if mr.pipeline == "failed" && old.pipeline != "failed" {
                alerts.append(("failed", alert(mr, .waiting, "🔴", "Pipeline rot: \(mr.title)")))
            } else if mr.pipeline == "success" && old.pipeline == "failed" {
                alerts.append(("fixed", alert(mr, .done, "🟢", "Wieder grün: \(mr.title)")))
            }
            if mr.notes > old.notes,
               let notes = glab("projects/\(mr.pid)/merge_requests/\(mr.iid)/notes?sort=desc&order_by=created_at&per_page=10") as? [[String: Any]],
               let note = notes.first(where: { $0["system"] as? Bool != true }),
               let author = note["author"] as? [String: Any], author["username"] as? String != me {
                let body = (note["body"] as? String ?? "").replacingOccurrences(of: "\n", with: " ")
                let name = author["name"] as? String ?? "Jemand"
                alerts.append(("comment", alert(mr, .waiting, "💬", "\(name): \(body.count > 120 ? body.prefix(119) + "…" : body)")))
            }
        }
        for (key, mr) in known where now[key] == nil {
            if (glab("projects/\(mr.pid)/merge_requests/\(mr.iid)") as? [String: Any])?["state"] as? String == "merged" {
                alerts.append(("merged", alert(mr, .done, "🎉", "Gemergt: \(mr.title)")))
            }
        }
        return alerts
    }
}
