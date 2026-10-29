import AppKit

/// Reads the feedback items from agent-feedback (same storage and status rules as there) and runs the
/// direct actions. Screenshot and markings stay in agent-feedback; this is only about the next step.
struct FeedbackItem {
    enum Status { case open, rework, answered, failed, question, implemented, nothingToDo, accepted }

    let md: URL
    let text: String
    let status: Status
    let changed: Date

    var dir: URL { md.deletingLastPathComponent().deletingLastPathComponent() }
    var inInbox: Bool { md.deletingLastPathComponent().lastPathComponent == "inbox" }
    var project: String { field("projekt").isEmpty ? dir.deletingLastPathComponent().lastPathComponent : field("projekt") }
    var sessionID: String { field("session_id") }
    var start: String { field("start") }

    var needsMartin: Bool { [.question, .implemented, .nothingToDo].contains(status) }
    var needsAgent: Bool { [.open, .rework, .answered, .failed].contains(status) }

    func field(_ key: String) -> String {
        let parts = text.components(separatedBy: "\n---\n")
        guard parts.count > 1 else { return "" }
        let prefix = key + ": "
        return parts[0].split(separator: "\n").first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) } ?? ""
    }

    /// First line of Martin's note.
    var headline: String {
        guard let end = text.range(of: "\n---\n") else { return "dein Feedback" }
        let body = text[end.upperBound...]
        let cut = body.range(of: "\n## ")?.lowerBound ?? body.endIndex
        let first = body[..<cut].trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").first.map(String.init) ?? ""
        return first.isEmpty ? "dein Feedback" : shorten(first, 50)
    }

    func last(_ label: String) -> String {
        let prefix = "**\(label):**"
        return text.split(separator: "\n").last { $0.hasPrefix(prefix) }
            .map { $0.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces) } ?? ""
    }

    var question: String { last("Frage").isEmpty ? last("Änderung") : last("Frage") }

    var images: [URL] {
        let list = field("bilder").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let names = list.isEmpty ? [md.deletingPathExtension().lastPathComponent + ".png"] : list
        return names.map { md.deletingLastPathComponent().appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    init?(md: URL) {
        guard let text = try? String(contentsOf: md, encoding: .utf8),
              let changed = (try? FileManager.default.attributesOfItem(atPath: md.path))?[.modificationDate] as? Date else { return nil }
        self.md = md
        self.text = text
        self.changed = changed
        let inbox = md.deletingLastPathComponent().lastPathComponent == "inbox"
        let line = text.split(separator: "\n").last(where: { $0.hasPrefix("**Status:**") })?.lowercased() ?? ""
        if line.isEmpty { status = inbox ? .open : .implemented }
        else if line.contains("abgenommen") { status = .accepted }
        else if line.contains("nachbessern") { status = .rework }
        else if line.contains("beantwortet") { status = .answered }
        else if line.contains("fehlgeschlagen") { status = .failed }
        else if line.contains("frage") { status = .question }
        else if line.contains("kein handlungsbedarf") { status = .nothingToDo }
        else if line.contains("umgesetzt") || line.contains("erledigt") { status = .implemented }
        else { status = .open }
    }
}

final class FeedbackWatch {
    private(set) var items: [FeedbackItem] = []
    /// Reports status changes (new follow-up question, change ready for visual review, approval).
    var onChange: ((FeedbackItem, FeedbackItem.Status?) -> Void)?
    private var known: [String: FeedbackItem.Status] = [:]
    private var first = true

    init() {
        refresh()
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    private var dirs: [URL] {
        let fm = FileManager.default
        var paths = Set((try? Data(contentsOf: homeURL.appendingPathComponent(".claude/agent-feedback/dirs.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String] } ?? [])
        for slug in (try? fm.contentsOfDirectory(atPath: workspacesDir.path)) ?? [] where !slug.hasPrefix(".") {
            paths.insert(workspacesDir.appendingPathComponent(slug).appendingPathComponent("feedback").path)
        }
        return paths.map(URL.init(fileURLWithPath:)).filter { fm.fileExists(atPath: $0.path) }
    }

    func refresh() {
        let cutoff = Date().addingTimeInterval(-3 * 86400)
        items = dirs.flatMap { dir in
            ["inbox", "done"].flatMap { sub -> [FeedbackItem] in
                let folder = dir.appendingPathComponent(sub)
                return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
                    .filter { $0.hasSuffix(".md") }
                    .compactMap { FeedbackItem(md: folder.appendingPathComponent($0)) }
                    .filter { $0.status != .accepted || $0.changed > cutoff }
            }
        }.sorted { $0.changed > $1.changed }
        for item in items {
            let before = known[item.md.lastPathComponent + item.dir.path]
            if !first, before != item.status { onChange?(item, before) }
            known[item.md.lastPathComponent + item.dir.path] = item.status
        }
        first = false
    }

    func items(forSession id: String) -> [FeedbackItem] { items.filter { $0.sessionID == id } }

    // MARK: Direct actions (same format as agent-feedback)

    func view(_ item: FeedbackItem) {
        let images = item.images
        if !images.isEmpty { NSWorkspace.shared.open(images, withApplicationAt: URL(fileURLWithPath: "/System/Applications/Preview.app"),
                                                     configuration: NSWorkspace.OpenConfiguration()) }
        performClick(["-execute", "open -b com.microsoft.VSCode \(shellQuote(item.md.path))"])
    }

    func accept(_ item: FeedbackItem) {
        append("## Abnahme \(stamp())\n**Status:** abgenommen", to: item.md)
        refresh()
    }

    func answer(_ item: FeedbackItem, text: String) {
        append("## Antwort \(stamp())\n\(text)\n\n**Status:** beantwortet", to: item.md)
        run(item.md, item)
    }

    /// Rework: append the request, move the item with its images back to inbox/, restart the agent.
    func rework(_ item: FeedbackItem, text: String) {
        append("## Nachbesserung \(stamp())\n\(text)\n\n**Status:** nachbessern", to: item.md)
        let inbox = item.dir.appendingPathComponent("inbox")
        let fm = FileManager.default
        try? fm.createDirectory(at: inbox, withIntermediateDirectories: true)
        for url in item.images + [item.md] {
            let dest = inbox.appendingPathComponent(url.lastPathComponent)
            if dest != url { try? fm.removeItem(at: dest); try? fm.moveItem(at: url, to: dest) }
        }
        run(inbox.appendingPathComponent(item.md.lastPathComponent), item)
    }

    /// Like the agent-feedback runner: fork of the original session, otherwise fresh in the project.
    private func run(_ md: URL, _ item: FeedbackItem) {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(homeURL.path)/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["SHELL"] = "/bin/zsh"
        env["AGENT_FEEDBACK_RUN"] = "1"
        let prompt = "feedback abarbeiten – nur diesen Punkt: \(md.path)"
        let resumable = !item.start.isEmpty && !item.sessionID.isEmpty
        let args = resumable ? ["-p", "--resume", item.sessionID, "--fork-session", "--output-format", "json", prompt]
                             : ["-p", "--output-format", "json", prompt]
        let cwd = URL(fileURLWithPath: resumable ? item.start : item.dir.deletingLastPathComponent().path)
        DispatchQueue.global(qos: .utility).async {
            _ = runClaude(args, input: "", cwd: cwd, env: env)
            DispatchQueue.main.async { self.refresh() }
        }
        refresh()
    }

    private func append(_ block: String, to md: URL) {
        let text = (try? String(contentsOf: md, encoding: .utf8)) ?? ""
        try? (text.trimmingCharacters(in: .newlines) + "\n\n" + block + "\n").write(to: md, atomically: true, encoding: .utf8)
    }

    private func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: Date())
    }
}
