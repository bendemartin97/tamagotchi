import AppKit
import SwiftUI

/// Was aus dem Transkript-Ende einer Session für die Live-Ansicht interessant ist.
struct Peek {
    /// Martins letzte Eingabe.
    var prompt = ""
    var model = ""
    /// Kontextgröße beim letzten Modellaufruf (Eingabe inkl. Cache).
    var context = 0
}

/// Liest die letzten ~400 KB eines Transkripts, neu nur wenn sich die Datei geändert hat.
final class Peeker {
    private var cache: [String: (Date, Peek)] = [:]

    func peek(_ path: String) -> Peek? {
        guard !path.isEmpty, let mtime = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return nil }
        if let (at, p) = cache[path], at == mtime { return p }
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        let end = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: end > 400_000 ? end - 400_000 : 0)
        let data = h.readDataToEndOfFile()
        var p = Peek()
        for line in data.split(separator: 0x0A).reversed() {
            guard let e = json(Data(line)) as? [String: Any], let msg = e["message"] as? [String: Any] else { continue }
            let type = e["type"] as? String
            if type == "assistant", p.model.isEmpty, let usage = msg["usage"] as? [String: Any] {
                p.model = (msg["model"] as? String ?? "").replacingOccurrences(of: "claude-", with: "")
                p.context = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"].reduce(0) { $0 + (usage[$1] as? Int ?? 0) }
            }
            if type == "user", p.prompt.isEmpty, e["isMeta"] as? Bool != true, let text = msg["content"] as? String {
                let clean = text.replacingOccurrences(of: "</?pasted_content[^>]*>", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty && !clean.hasPrefix("<") { p.prompt = clean }
            }
            if !p.prompt.isEmpty && !p.model.isEmpty { break }
        }
        cache[path] = (mtime, p)
        return p
    }
}

/// „arbeitet seit 12 min“, „wartet seit 3 min“, „fertig vor 5 min · Turn 8 min“ samt Farbe.
func agentStatus(_ s: Session) -> (text: String, color: Color) {
    switch s.mood {
    case .working: return ("arbeitet seit \(duration(Date().timeIntervalSince(s.busySince ?? s.updated)))", .blue)
    case .waiting: return ("wartet seit \(duration(Date().timeIntervalSince(s.updated)))", .orange)
    default: return ("fertig \(ago(s.updated))" + (s.lastTurn.map { " · Turn \(duration($0))" } ?? ""), .green)
    }
}

/// Animiertes Pixel-Haustier eines Agenten in seinem eigenen Aussehen.
struct Avatar: View {
    let look: Look
    let mood: Mood
    var prop = Prop.none
    var px: CGFloat = 3

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.15)) { ctx in
            let tick = Int(ctx.date.timeIntervalSinceReferenceDate * 10)
            Image(nsImage: petImage(PetPose(mood: mood, t: tick, tick: tick, prop: prop, look: look), px: px))
        }
    }
}

/// Seitenleiste mit allen Agenten: Avatar, Aufgabe, Status, aktuelles Werkzeug. Klick öffnet die Agentenansicht,
/// Doppelklick springt in die Session.
struct AgentSidebar: View {
    @ObservedObject var hub: Hub

    var body: some View {
        let _ = hub.tick
        let order: [Mood: Int] = [.waiting: 0, .working: 1, .done: 2]
        let list = hub.store.agents.sorted { (order[$0.mood] ?? 3, $0.id) < (order[$1.mood] ?? 3, $1.id) }
        VStack(alignment: .leading, spacing: 0) {
            Text("Agenten (\(list.count))").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 6)
            if list.isEmpty {
                Text("Keine Session aktiv.").font(.callout).foregroundStyle(.secondary).padding(12)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 4) { ForEach(list, id: \.id) { row($0) } }
                        .padding(.horizontal, 8).padding(.bottom, 8)
                }
            }
        }
        .frame(width: 250)
        .background(Color.primary.opacity(0.03))
    }

    private func row(_ s: Session) -> some View {
        let status = agentStatus(s)
        let selected = hub.agentFilter == s.id
        let work = hub.brain.work(forSession: s)
        return HStack(alignment: .top, spacing: 8) {
            Avatar(look: Look.agent(hub.store.name(for: s.id)), mood: s.mood, prop: hub.prop(s), px: 3)
                .frame(width: 56, height: 50)
            VStack(alignment: .leading, spacing: 2) {
                Text(hub.store.name(for: s.id)).font(.subheadline.weight(.semibold))
                Text(hub.brain.topic(s)).font(.caption).lineLimit(2)
                Text(status.text).font(.caption2).foregroundStyle(status.color)
                if s.mood == .working, !s.detail.isEmpty {
                    Text(s.detail).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
                }
                ForEach(Array(hub.problems(s.id).enumerated()), id: \.offset) { _, p in
                    Text("⚠️ \(p.text)").font(.caption2).foregroundStyle(.orange).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.18) : s.mood == .waiting ? Color.orange.opacity(0.1) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { performClick(s.click) }
        .onTapGesture { hub.agentFilter = selected ? nil : s.id }
        .contextMenu {
            if !s.click.isEmpty { Button("Zur Session") { performClick(s.click) } }
            ForEach(Array((work.map { hub.brain.works.actions(for: $0) } ?? []).enumerated()), id: \.offset) { _, a in
                Button(a.0) { hub.act(a.1) }
            }
        }
        .help("Klick: Agentenansicht · Doppelklick: zur Session")
    }
}

func duration(_ t: TimeInterval) -> String {
    let s = Int(max(0, t))
    if s < 60 { return "\(s) s" }
    if s < 3600 { return "\(s / 60) min" }
    return "\(s / 3600) h \(s % 3600 / 60) min"
}

/// Live-Ansicht: alle Agenten mit Auftrag, aktuellem Werkzeug und Dauer, laufende Pipelines und Reviews,
/// was bei anderen liegt, und der Tagesverlauf.
struct LiveView: View {
    @ObservedObject var hub: Hub

    private var store: Store { hub.store }
    private var brain: Brain { hub.brain }

    var body: some View {
        let _ = hub.tick
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                stats
                agents
                changes
                elsewhere
                activity
            }
            .padding(12)
        }
    }

    // MARK: Kennzahlen

    private var stats: some View {
        let sessions = store.agents
        let mine = State.shared.data.changes.values.filter { $0.isOpen && $0.mine }
        let today = Calendar.current.startOfDay(for: Date())
        let turns = store.inbox.all.values.filter(\.isAgent).flatMap(\.events).filter { $0.at >= today && $0.icon != "▶️" && $0.icon != "✋" }.count
        let merged = State.shared.data.changes.values.filter { ($0.mergedAt ?? .distantPast) >= today }.count
        let reviews = State.shared.data.changes.values.filter { $0.isOpen && $0.reviewer && !$0.mine && !$0.draft }.count
        let feedback = brain.feedback.items
        return Flow(spacing: 8) {
            pill("⚙️", "\(sessions.filter { $0.mood == .working }.count) arbeiten")
            pill("✋", "\(sessions.filter { $0.mood == .waiting }.count) warten", alert: sessions.contains { $0.mood == .waiting })
            pill("✅", "\(sessions.filter { $0.mood == .done }.count) fertig")
            pill("⏳", "\(mine.filter { $0.pipeline == "running" || $0.pipeline == "pending" }.count) Pipelines laufen")
            pill("🔴", "\(mine.filter { $0.pipeline == "failed" }.count) rot", alert: mine.contains { $0.pipeline == "failed" })
            pill("👀", "\(reviews) Reviews für dich", alert: reviews > 0)
            pill("🕊", "\(mine.filter { !$0.draft && $0.review.isEmpty }.count) warten auf Review")
            pill("📸", "\(feedback.filter(\.needsAgent).count) Feedback in Arbeit · \(feedback.filter(\.needsMartin).count) für dich")
            pill("📅", "Heute \(turns) Turns fertig · \(merged) gemergt")
        }
    }

    private func pill(_ icon: String, _ text: String, alert: Bool = false) -> some View {
        Text("\(icon) \(text)")
            .font(.caption)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(alert ? Color.orange.opacity(0.25) : Color.primary.opacity(0.07)))
    }

    // MARK: Agenten

    private var agents: some View {
        let order: [Mood: Int] = [.waiting: 0, .working: 1, .done: 2]
        let list = store.agents
            .filter { hub.matches([brain.topic($0), $0.heading, $0.project, store.name(for: $0.id)]) }
            .sorted { (order[$0.mood] ?? 3, $1.updated) < (order[$1.mood] ?? 3, $0.updated) }
        return VStack(alignment: .leading, spacing: 8) {
            heading("Agenten", list.count)
            if list.isEmpty { Text("Keine Session aktiv.").font(.callout).foregroundStyle(.secondary) }
            ForEach(list, id: \.id) { agent($0) }
        }
    }

    private func agent(_ s: Session) -> some View {
        let peek = hub.peeker.peek(s.transcript)
        let work = brain.work(forSession: s)
        let links = work.map { brain.works.actions(for: $0) } ?? []
        let (status, color) = agentStatus(s)
        var meta: [String] = []
        if let p = peek, p.context > 0 { meta.append("Kontext \(p.context / 1000)k") }
        if let p = peek, !p.model.isEmpty { meta.append(p.model) }
        if let n = s.tools, n > 0 { meta.append("\(n) Werkzeugaufrufe") }
        if !s.project.isEmpty { meta.append(s.project) }
        if let t = work?.ticket, !t.status.isEmpty { meta.append("Ticket \(t.status)") }
        let feedback = brain.feedback.items(forSession: s.id)
        if !feedback.isEmpty { meta.append("\(feedback.count) Feedback") }

        return HStack(alignment: .top, spacing: 10) {
            Avatar(look: Look.agent(store.name(for: s.id)), mood: s.mood, prop: hub.prop(s), px: 4)
                .frame(width: 74, height: 66)
            card(s, peek: peek, links: links, status: status, color: color, meta: meta)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(s.mood == .waiting ? 0.6 : 0.15)))
    }

    private func card(_ s: Session, peek: Peek?, links: [(String, () -> Void)], status: String, color: Color, meta: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text("\(store.name(for: s.id)) · \(brain.topic(s))").font(.headline).lineLimit(1)
                Spacer()
                Text(status).font(.caption).foregroundStyle(color)
            }
            if !s.heading.isEmpty { Text(s.heading).font(.subheadline).foregroundStyle(.secondary) }
            if let p = peek, !p.prompt.isEmpty {
                Text("Auftrag: \(p.prompt)").font(.callout).lineLimit(3).textSelection(.enabled)
            }
            if s.mood == .working, !s.detail.isEmpty {
                Text("⚙️ \(s.detail)").font(.caption.monospaced()).lineLimit(1).foregroundStyle(.primary)
            } else if s.mood == .waiting {
                Text("✋ \(s.detail.isEmpty ? s.text : "will: \(s.detail)")").font(.caption.monospaced()).lineLimit(2).foregroundStyle(.orange)
            } else if !s.text.isEmpty {
                Text(s.text).font(.caption).lineLimit(2).foregroundStyle(.secondary)
            }
            if let recent = s.recent, recent.count > 1, s.mood == .working {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(recent.dropLast().suffix(4).reversed().enumerated()), id: \.offset) { _, r in
                        Text(r).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
            }
            if !meta.isEmpty { Text(meta.joined(separator: " · ")).font(.caption).foregroundStyle(.tertiary).lineLimit(1) }
            Flow {
                if !s.click.isEmpty { Button("Zur Session") { performClick(s.click) } }
                ForEach(Array(links.enumerated()), id: \.offset) { _, a in
                    if !a.0.hasPrefix("Zu ") { Button(a.0) { hub.act(a.1) } }
                }
            }
            .controlSize(.small)
        }
    }

    // MARK: MRs in Bewegung

    private var changes: some View {
        let list = State.shared.data.changes.values
            .filter { $0.isOpen && $0.mine && ($0.pipeline != "success" || $0.conflict || $0.review == "changes" || $0.open > 0) }
            .filter { hub.matches([brain.works.topic(for: $0), $0.title, $0.repo]) }
            .sorted { brain.works.topic(for: $0) < brain.works.topic(for: $1) }
        return VStack(alignment: .leading, spacing: 4) {
            heading("Deine MRs mit Bewegung", list.count)
            if list.isEmpty { Text("Alles grün, keine offenen Punkte.").font(.callout).foregroundStyle(.secondary) }
            ForEach(list, id: \.key) { c in
                VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(icon(c))
                    Text("\(brain.works.topic(for: c)) · \(c.side)").font(.callout).lineLimit(1)
                    Spacer()
                    Text(state(c)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Button("Öffnen") { openURL(c.pipeline == "failed" ? c.url + (c.host == "github" ? "/checks" : "/pipelines") : c.url) }
                        .controlSize(.small)
                }
                if c.needsHelp { ChangeExtras(hub: hub, change: c).padding(.leading, 24) }
                }
            }
        }
    }

    private func icon(_ c: Change) -> String {
        if c.conflict { return "⚔️" }
        return ["failed": "🔴", "running": "⏳", "pending": "⏳", "success": "🟢"][c.pipeline] ?? "⚪️"
    }

    private func state(_ c: Change) -> String {
        var out: [String] = []
        if let p = ["failed": "Pipeline rot", "running": "Pipeline läuft", "pending": "Pipeline wartet"][c.pipeline] { out.append(p) }
        if c.conflict { out.append("Konflikt") }
        if c.review == "changes" { out.append("Änderungen gewünscht") }
        if c.open > 0 { out.append("\(c.open) offene Punkte") }
        if let at = c.lastForeign { out.append("Rückmeldung \(ago(at))") }
        return out.joined(separator: " · ")
    }

    // MARK: Bei anderen und automatisch

    private var elsewhere: some View {
        let list = brain.items.filter { $0.who != .you && $0.group != "agent" }
        return VStack(alignment: .leading, spacing: 3) {
            heading("Liegt bei anderen oder läuft von allein", list.count)
            ForEach(Array(list.prefix(15).enumerated()), id: \.offset) { _, a in
                Text("\(a.icon) \(a.phrase)").font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    // MARK: Verlauf

    private var activity: some View {
        let today = Calendar.current.startOfDay(for: Date())
        let events = store.inbox.all.values
            .flatMap { m in m.events.filter { $0.at >= today }.map { (m, $0) } }
            .filter { hub.matches($0.0) || hub.matches([brain.title($0.0), $0.1.text]) }
            .sorted { $0.1.at > $1.1.at }
            .prefix(40)
        return VStack(alignment: .leading, spacing: 3) {
            heading("Heute", events.count)
            ForEach(Array(events.enumerated()), id: \.offset) { _, pair in
                let (m, e) = pair
                HStack(alignment: .top, spacing: 6) {
                    Text(e.at.formatted(date: .omitted, time: .shortened)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                    Text(e.icon).font(.caption)
                    Text(brain.title(m)).font(.caption.weight(.semibold)).lineLimit(1).fixedSize()
                    Text(e.text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }

    private func heading(_ title: String, _ count: Int) -> some View {
        Text("\(title) (\(count))").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }
}
