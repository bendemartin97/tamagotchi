import AppKit
import SwiftUI

/// Zeit pro Aufgabe aus den Hook-Ereignissen: Folgen zwei Ereignisse derselben Aufgabe mit weniger als 15 min
/// Abstand, zählt die Zwischenzeit. Mehrere Sessions an derselben Aufgabe zählen nicht doppelt.
final class Timekeeper {
    let works: Works
    private var last: [String: Date] = [:]

    init(works: Works) { self.works = works }

    static func day(_ d: Date) -> String {
        ISO8601DateFormatter.string(from: d, timeZone: .current, formatOptions: [.withFullDate])
    }

    func ping(_ s: Session) {
        guard s.isAgent, !s.project.hasPrefix("🛠") else { return }
        let key = works.key(forProject: s.project), now = Date()
        if let l = last[key], Calendar.current.isDate(l, inSameDayAs: now), now.timeIntervalSince(l) < 15 * 60 {
            var log = State.shared.data.timeLog ?? [:]
            log[Self.day(now), default: [:]][key, default: 0] += now.timeIntervalSince(l)
            State.shared.data.timeLog = log.filter { $0.key >= Self.day(now.addingTimeInterval(-30 * 86400)) }
            State.shared.touch()
        }
        last[key] = now
    }

    /// Aufgabe → Sekunden an einem Tag, größte zuerst.
    func times(_ date: Date) -> [(key: String, seconds: TimeInterval)] {
        (State.shared.data.timeLog?[Self.day(date)] ?? [:]).map { ($0.key, $0.value) }.sorted { $0.seconds > $1.seconds }
    }

    func booked(_ key: String, _ date: Date) -> Int? { State.shared.data.booked?["\(Self.day(date))|\(key)"] }

    /// Bucht einen Zeiteintrag per ClickUp-MCP (Haiku, ~1 Cent). Nur auf Martins Klick.
    func book(_ key: String, minutes: Int, topic: String, date: Date, done: @escaping (Bool) -> Void) {
        let start = Calendar.current.isDateInToday(date) ? Date().addingTimeInterval(-Double(minutes) * 60)
            : Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: date)!
        let iso = ISO8601DateFormatter().string(from: start)
        let prompt = """
        Lege mit clickup_add_time_entry auf der ClickUp-Task \(key) genau einen Zeiteintrag an: Start \(iso), Dauer \(minutes) \
        Minuten, Beschreibung „\(topic)“. Nichts anderes ändern. Antworte nur mit OK oder FEHLER: <Grund>.
        """
        let mcp = #"{"mcpServers":{"clickup":{"type":"http","url":"https://mcp.clickup.com/mcp"}}}"#
        let args = ["-p", "--setting-sources", "", "--model", "claude-haiku-5-5", "--no-session-persistence", "--output-format", "json",
                    "--strict-mcp-config", "--mcp-config", mcp, "--tools", "", "--allowedTools", "mcp__clickup__clickup_add_time_entry"]
        DispatchQueue.global(qos: .userInitiated).async {
            let r = runClaude(args, input: prompt, cwd: buddyDir)
            let ok = r.ok && (r.text ?? "").uppercased().hasPrefix("OK")
            DispatchQueue.main.async {
                if ok {
                    var b = State.shared.data.booked ?? [:]
                    b["\(Self.day(date))|\(key)"] = minutes
                    State.shared.data.booked = b
                    State.shared.touch()
                }
                done(ok)
            }
        }
    }
}

/// Standup-Notiz (letzter Werktag + heute) und Tagesrückblick aus Inbox-Verlauf, Merges, Tickets und Zeiten.
final class Reports {
    let store: Store
    let brain: Brain
    let time: Timekeeper

    init(store: Store, brain: Brain, time: Timekeeper) {
        self.store = store
        self.brain = brain
        self.time = time
    }

    static func previousWorkday(_ d: Date = Date()) -> Date {
        var day = Calendar.current.date(byAdding: .day, value: -1, to: d)!
        while Calendar.current.isDateInWeekend(day) { day = Calendar.current.date(byAdding: .day, value: -1, to: day)! }
        return day
    }

    /// Was an einem Tag passiert ist, als Stichpunkte pro Aufgabe.
    func done(on date: Date) -> [String] {
        let cal = Calendar.current
        var turns: [String: Int] = [:]
        for m in store.inbox.all.values where m.isAgent && !m.project.hasPrefix("🛠") {
            let n = m.events.filter { cal.isDate($0.at, inSameDayAs: date) && $0.icon != "▶️" && $0.icon != "✋" }.count
            if n > 0 { turns[brain.works.topic(forProject: m.project), default: 0] += n }
        }
        var merged: [String: [String]] = [:]
        for c in State.shared.data.changes.values where c.mergedAt.map({ cal.isDate($0, inSameDayAs: date) }) == true {
            merged[brain.works.topic(for: c), default: []].append(c.side)
        }
        var tickets: [String] = []
        for m in store.inbox.all.values where m.id.hasPrefix("ticket-") && m.events.contains(where: { cal.isDate($0.at, inSameDayAs: date) }) {
            tickets.append(m.project)
        }
        let times = Dictionary(time.times(date).map { (brain.work($0.key)?.topic ?? brain.works.ticketName($0.key) ?? $0.key, $0.seconds) }, uniquingKeysWith: +)
        let topics = Set(turns.keys).union(merged.keys).union(tickets).union(times.filter { $0.value >= 600 }.keys)
        return topics.sorted().map { t in
            var parts: [String] = []
            if let s = times[t], s >= 300 { parts.append(duration(s)) }
            if let n = turns[t] { parts.append(n == 1 ? "1 Agenten-Turn" : "\(n) Agenten-Turns") }
            if let sides = merged[t] { parts.append(sides.sorted().joined(separator: " und ") + " gemergt") }
            if tickets.contains(t) { parts.append("Ticket weitergesetzt") }
            return "- \(t): " + parts.joined(separator: ", ")
        }
    }

    /// Was heute ansteht: offene Aufgaben mit ihrem Stand.
    func plan() -> [String] {
        brain.list.filter { w in w.changes.contains(where: \.isOpen) || store.agents.contains { brain.works.key(forProject: $0.project) == w.key } }
            .map { w in
                let open = w.changes.filter(\.isOpen).sorted { $0.side < $1.side }.map { c in
                    "\(c.side) \(["failed": "rot", "running": "läuft", "pending": "wartet", "success": c.review == "approved" ? "freigegeben" : "im Review"][c.pipeline] ?? "offen")"
                }
                return "- \(w.topic)" + (open.isEmpty ? "" : " (\(open.joined(separator: ", ")))")
            }
    }

    func blockers() -> [String] {
        brain.forYou.filter { brain.rank($0) == .now }.map { "- \($0.phrase)" }
    }

    func standup() -> String {
        let prev = Self.previousWorkday()
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "EEEE"
        let yesterday = done(on: prev), plan = plan(), blockers = blockers()
        return """
        \(Calendar.current.isDateInYesterday(prev) ? "Gestern" : f.string(from: prev)):
        \(yesterday.isEmpty ? "- nichts aufgezeichnet" : yesterday.joined(separator: "\n"))

        Heute:
        \(plan.isEmpty ? "- noch offen" : plan.joined(separator: "\n"))

        Blocker:
        \(blockers.isEmpty ? "- keine" : blockers.joined(separator: "\n"))
        """
    }

    func review() -> String {
        let today = done(on: Date()), open = brain.forYou.map { "- \($0.phrase)" }
        let total = time.times(Date()).reduce(0) { $0 + $1.seconds }
        return """
        Heute (\(duration(total)) erfasst):
        \(today.isEmpty ? "- nichts aufgezeichnet" : today.joined(separator: "\n"))

        Offen für morgen:
        \(open.isEmpty ? "- nichts" : open.prefix(8).joined(separator: "\n"))
        """
    }
}

/// Reiter „Bericht“: Standup und Tagesrückblick zum Kopieren, darunter die Zeiten pro Ticket zum Buchen.
struct ReportView: View {
    @ObservedObject var hub: Hub
    @SwiftUI.State private var kind = 0
    @SwiftUI.State private var yesterday = false
    @SwiftUI.State private var minutes: [String: String] = [:]
    @SwiftUI.State private var booking: Set<String> = []
    @SwiftUI.State private var failed: Set<String> = []

    var body: some View {
        let _ = hub.tick
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let reports = hub.reports {
                    Picker("", selection: $kind) {
                        Text("Standup").tag(0)
                        Text("Tagesrückblick").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 320)
                    let text = kind == 0 ? reports.standup() : reports.review()
                    Text(text).font(.callout.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                    Button("Kopieren") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    times(reports)
                }
            }
            .padding(14)
        }
    }

    @ViewBuilder private func times(_ reports: Reports) -> some View {
        let date = yesterday ? Reports.previousWorkday() : Date()
        let rows = reports.time.times(date).filter { $0.seconds >= 60 }
        HStack {
            Text("Zeit pro Aufgabe").font(.headline)
            Picker("", selection: $yesterday) {
                Text("Heute").tag(false)
                Text("Letzter Werktag").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 240)
        }
        Text("Gezählt wird, solange Hook-Ereignisse einer Aufgabe weniger als 15 min auseinanderliegen. Gebucht wird nur auf Klick.")
            .font(.caption).foregroundStyle(.secondary)
        if rows.isEmpty { Text("Noch nichts erfasst.").foregroundStyle(.secondary) }
        ForEach(rows, id: \.key) { row in
            let topic = hub.brain.work(row.key)?.topic ?? hub.brain.works.ticketName(row.key) ?? row.key
            let isTicket = !row.key.contains(":")
            let id = "\(Timekeeper.day(date))|\(row.key)"
            HStack(spacing: 8) {
                Text(topic).lineLimit(1)
                Spacer()
                Text(duration(row.seconds)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                if let b = reports.time.booked(row.key, date) {
                    Text("✓ \(b) min gebucht").font(.caption).foregroundStyle(.green)
                } else if isTicket {
                    TextField("min", text: Binding(get: { minutes[id] ?? "\(Self.rounded(row.seconds))" }, set: { minutes[id] = $0 }))
                        .frame(width: 50)
                        .textFieldStyle(.roundedBorder)
                    if booking.contains(id) {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(failed.contains(id) ? "Nochmal buchen" : "Nach ClickUp buchen") {
                            let m = Int(minutes[id] ?? "") ?? Self.rounded(row.seconds)
                            booking.insert(id)
                            failed.remove(id)
                            reports.time.book(row.key, minutes: m, topic: topic, date: date) { ok in
                                booking.remove(id)
                                if !ok { failed.insert(id) }
                                hub.refresh()
                            }
                        }
                    }
                } else {
                    Text("kein Ticket").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .controlSize(.small)
        }
    }

    /// Auf 15 Minuten gerundet, mindestens 15.
    static func rounded(_ s: TimeInterval) -> Int { max(15, Int((s / 900).rounded()) * 15) }
}
