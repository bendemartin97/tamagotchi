import AppKit

let claudeURL = homeURL.appendingPathComponent(".local/bin/claude")

let buddyPrompt = """
Du bist ein kleines orangefarbenes Pixel-Haustier, das auf Martins Bildschirm herumläuft. Martin ist \
Fullstack-Entwickler bei anny (Buchungsplattform, Vue/Nuxt-Frontend, Laravel-Backend) und lässt oft \
mehrere Claude-Code-Sessions parallel laufen. Du siehst deren Status, seine offenen GitLab-MRs und \
meldest, wenn etwas fertig ist oder auf ihn wartet.

Du bist sein frecher, guter Kumpel: direkt, trocken, ein bisschen respektlos, nie gemein und immer auf \
seiner Seite. Du duzt ihn. Deine Antworten erscheinen in einer kleinen Sprechblase, also meist ein bis \
zwei Sätze, höchstens drei, ohne Markdown und ohne Aufzählungen. Stellt er eine echte Frage, \
beantworte sie richtig und brauchbar, nur eben frech verpackt. Jede Nachricht beginnt mit einer \
[Lage]-Zeile mit Uhrzeit, Session- und MR-Status; nutz sie, wenn es passt (etwa um ihn an eine \
wartende Session zu erinnern), und erfinde nichts, was dort nicht steht.

Zu jeder Nachricht liegt ein frischer Screenshot seines Bildschirms unter screen.png im aktuellen \
Ordner. Schau ihn dir mit dem Read-Tool an, wenn die Frage sich auf etwas bezieht, das er gerade \
sieht oder macht ("was ist das", "schau mal", "hier"); sonst lass ihn liegen. Du kannst nur gucken, \
nicht klicken oder tippen.

Selbst ausführen kannst du nichts. Bittet er dich, etwas am Rechner zu erledigen (Code ändern, \
Workspace anlegen, Pipeline oder MR prüfen, Ticket nachschlagen …), dann schreib in die erste Zeile \
genau `AUFTRAG: ` gefolgt von der Aufgabe, so formuliert, dass eine Claude-Code-Session in \
~/Development sie ohne Rückfragen erledigen kann (mit allen Details aus dem Gespräch und vom \
Screenshot). Danach optional ein kurzer frecher Satz. Martin bestätigt den Auftrag per Klick.
"""

/// Starts `claude -p` and returns `result` from the JSON output. Blocking, so never call it on the main thread.
func runClaude(_ args: [String], input: String, cwd: URL, env: [String: String]? = nil) -> (ok: Bool, text: String?) {
    let p = Process()
    p.executableURL = claudeURL
    p.arguments = args
    p.currentDirectoryURL = cwd
    if let env { p.environment = env }
    let stdin = Pipe(), stdout = Pipe()
    p.standardInput = stdin
    p.standardOutput = stdout
    p.standardError = Pipe()
    guard (try? p.run()) != nil else { return (false, nil) }
    stdin.fileHandleForWriting.write(Data(input.utf8))
    try? stdin.fileHandleForWriting.close()
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    let failed = obj?["is_error"] as? Bool ?? true
    return (!failed && p.terminationStatus == 0, obj?["result"] as? String)
}

/// Chat and reminders via `claude -p` (runs through the subscription). --setting-sources "" omits hooks, plugins
/// and permissions from the settings, otherwise every reply would itself end up as a session in the pet.
final class Buddy {
    private var sessionID: String?
    private var lastUse = Date.distantPast
    private(set) var busy = false

    private let base = ["-p", "--setting-sources", "", "--strict-mcp-config",
                        "--model", "claude-sonnet-5-5", "--effort", "medium", "--output-format", "json"]

    func reset() { sessionID = nil }

    func ask(_ question: String, situation: String, done: @escaping (String) -> Void) {
        if Date().timeIntervalSince(lastUse) > 30 * 60 { sessionID = nil }
        lastUse = Date()
        let resume = sessionID
        let id = resume ?? UUID().uuidString.lowercased()
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            captureScreen()
            var args = self.base + ["--tools", "Read", "--allowedTools", "Read"]
            args += resume == nil ? ["--session-id", id, "--system-prompt", buddyPrompt] : ["--resume", id]
            let r = runClaude(args, input: "[Lage: \(situation)]\n\(question)", cwd: buddyDir)
            DispatchQueue.main.async {
                self.busy = false
                if r.ok { self.sessionID = id }
                let text = r.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                done(text.isEmpty ? "Ich krieg Claude gerade nicht wach." : (r.ok ? "" : "Claude zickt: ") + text)
            }
        }
    }

    /// Proactive reminder from Martin's memory (releases, open items); nil if nothing is pending.
    func nudge(situation: String, done: @escaping (String?) -> Void) {
        let memory = memoryDir.resolvingSymlinksInPath().path
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "EEEE, d. MMMM yyyy"
        let prompt = """
        [Lage: \(situation)]
        Heute ist \(f.string(from: Date())). Lies \(memory)/MEMORY.md und, falls dort etwas mit heutigem \
        oder morgigem Datum steht (Release, Deploy, offene MRs, Termine, Dinge nach dem Deploy), die \
        passende Datei. Gib Martin dazu eine kurze freche Erinnerung mit dem konkreten Punkt. Steht nichts \
        Dringendes an, antworte exakt SKIP.
        """
        DispatchQueue.global(qos: .utility).async {
            let args = self.base + ["--tools", "Read,Glob,Grep", "--allowedTools", "Read,Glob,Grep",
                                    "--add-dir", memory, "--no-session-persistence", "--system-prompt", buddyPrompt]
            let r = runClaude(args, input: prompt, cwd: buddyDir)
            let text = r.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            DispatchQueue.main.async { done(r.ok && !text.isEmpty && !text.contains("SKIP") ? text : nil) }
        }
    }
}

/// Needs screen recording permission for Tamagotchi.app, otherwise only the wallpaper is captured.
func captureScreen() {
    let path = buddyDir.appendingPathComponent("screen.png").path
    for (tool, args) in [("/usr/sbin/screencapture", ["-x", "-m", path]), ("/usr/bin/sips", ["-Z", "1600", path])] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
    }
}

/// Tasks run as a real Claude Code session in ~/Development (with Martin's settings, hooks and
/// CLAUDE.md) and therefore show up as a mini pet. The result lands in tasks/ and is opened in VS Code
/// on click.
final class TaskRunner {
    let store: Store

    init(store: Store) { self.store = store }

    func start(_ task: String) {
        let id = UUID().uuidString.lowercased()
        let label = "🛠 " + (task.count > 26 ? task.prefix(25) + "…" : task)
        store.labels[id] = label
        store.post(Session(id: id, mood: .working, project: label, agent: "Claude Code"))
        DispatchQueue.global(qos: .userInitiated).async {
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "\(homeURL.path)/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            env["SHELL"] = "/bin/zsh"
            let r = runClaude(["-p", "--session-id", id, "--output-format", "json"], input: task,
                              cwd: homeURL.appendingPathComponent("Development"), env: env)
            let dir = buddyDir.appendingPathComponent("tasks")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd-HHmm"
            let file = dir.appendingPathComponent("\(f.string(from: Date()))-\(id.prefix(8)).md")
            let result = r.text ?? "(keine Ausgabe)"
            try? "# Auftrag\n\n\(task)\n\n# Ergebnis\n\n\(result)\n\nSession: `claude --resume \(id)` in ~/Development\n"
                .write(to: file, atomically: true, encoding: .utf8)
            DispatchQueue.main.async {
                self.store.sealed.insert(id)
                let summary = result.replacingOccurrences(of: "\n", with: " ")
                self.store.post(Session(
                    id: id, mood: .done, project: label, agent: "Claude Code",
                    text: (r.ok ? "" : "Ging schief: ") + (summary.count > 160 ? summary.prefix(159) + "…" : summary),
                    icon: r.ok ? "🛠" : "💥",
                    click: ["-execute", "open -b com.microsoft.VSCode \(shellQuote(file.path))"]))
            }
        }
    }
}
