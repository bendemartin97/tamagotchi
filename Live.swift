import AppKit
import SwiftUI

/// What is of interest from the end of a session's transcript for the live view.
struct Peek {
    /// Martin's latest input.
    var prompt = ""
    var model = ""
    /// Context size at the last model call (input incl. cache).
    var context = 0
}

/// Reads the last ~400 KB of a transcript, only re-reading when the file has changed.
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

/// "arbeitet seit 12 min" (working for 12 min), "wartet seit 3 min" (waiting for 3 min), "fertig vor 5 min · Turn 8 min" (done 5 min ago · turn 8 min), including color.
func agentStatus(_ s: Session) -> (text: String, color: Color) {
    switch s.mood {
    case .working: return ("arbeitet seit \(duration(Date().timeIntervalSince(s.busySince ?? s.updated)))", .blue)
    case .waiting: return ("wartet seit \(duration(Date().timeIntervalSince(s.updated)))", .orange)
    default: return ("fertig \(ago(s.updated))" + (s.lastTurn.map { " · Turn \(duration($0))" } ?? ""), .green)
    }
}

/// Animated pixel pet of an agent, in its own look.
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

/// Sidebar with all agents: avatar, task, status, current tool. Click opens the agent view,
/// double-click jumps into the session.
struct AgentSidebar: View {
    @ObservedObject var hub: Hub

    var body: some View {
        let _ = hub.tick
        let order: [Mood: Int] = [.waiting: 0, .working: 1, .done: 2]
        let list = hub.store.agents.sorted { (order[$0.mood] ?? 3, $0.id) < (order[$1.mood] ?? 3, $1.id) }
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title: "Agenten", count: list.count)
                .padding(.horizontal, 14).padding(.top, 44).padding(.bottom, 8)
            if list.isEmpty {
                Text("Keine Session aktiv.").font(.callout).foregroundStyle(.secondary).padding(12)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 6) { ForEach(list, id: \.id) { row($0) } }
                        .padding(.horizontal, 10).padding(.bottom, 10)
                }
            }
        }
        .frame(width: 260)
    }

    private func row(_ s: Session) -> some View {
        let status = agentStatus(s)
        let selected = hub.agentFilter == s.id
        let work = hub.brain.work(forSession: s)
        return HStack(alignment: .top, spacing: 8) {
            Avatar(look: Look.agent(hub.store.name(for: s.id)), mood: s.mood, prop: hub.prop(s), px: 3)
                .frame(width: 56, height: 50)
            VStack(alignment: .leading, spacing: 3) {
                Text(hub.store.name(for: s.id)).font(.system(size: 13, weight: .semibold))
                Text(hub.brain.topic(s)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                StatusPill(text: status.text, color: status.color)
                if s.mood == .working, !s.detail.isEmpty {
                    Text(s.detail).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
                }
                ForEach(Array(hub.problems(s.id).enumerated()), id: \.offset) { _, p in
                    Text("⚠️ \(p.text)").font(.caption2).foregroundStyle(.orange).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .card(selected ? .accentColor : s.mood == .waiting ? .orange : nil, padding: 8, radius: 10)
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

/// Live view: all agents with task, current tool and duration, running pipelines and reviews,
/// what is waiting on others, and the daily history.
struct LiveView: View {
    @ObservedObject var hub: Hub

    private var store: Store { hub.store }
    private var brain: Brain { hub.brain }

    var body: some View {
        let _ = hub.tick
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                stats
                agents
                changes
                elsewhere
                activity
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    // MARK: Metrics

    private var stats: some View {
        let sessions = store.agents
        let mine = State.shared.data.changes.values.filter { $0.isOpen && $0.mine }
        let today = Calendar.current.startOfDay(for: Date())
        let turns = store.inbox.all.values.filter(\.isAgent).flatMap(\.events).filter { $0.at >= today && $0.icon != "▶️" && $0.icon != "✋" }.count
        let merged = State.shared.data.changes.values.filter { ($0.mergedAt ?? .distantPast) >= today }.count
        let reviews = State.shared.data.changes.values.filter { $0.isOpen && $0.reviewer && !$0.mine && !$0.draft }.count
        let feedback = brain.feedback.items
        let waiting = sessions.filter { $0.mood == .waiting }.count
        let red = mine.filter { $0.pipeline == "failed" }.count
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 8)], spacing: 8) {
            StatTile(icon: "gearshape.2.fill", value: "\(sessions.filter { $0.mood == .working }.count)", label: "arbeiten", tint: .blue)
            StatTile(icon: "hand.raised.fill", value: "\(waiting)", label: "warten auf dich", tint: .orange, alert: waiting > 0)
            StatTile(icon: "checkmark.circle.fill", value: "\(sessions.filter { $0.mood == .done }.count)", label: "fertig", tint: .green)
            StatTile(icon: "hourglass", value: "\(mine.filter { $0.pipeline == "running" || $0.pipeline == "pending" }.count)", label: "Pipelines laufen", tint: .teal)
            StatTile(icon: "xmark.octagon.fill", value: "\(red)", label: "Pipelines rot", tint: .red, alert: red > 0)
            StatTile(icon: "eye.fill", value: "\(reviews)", label: "Reviews für dich", tint: .purple, alert: reviews > 0)
            StatTile(icon: "bubble.left.and.bubble.right.fill", value: "\(mine.filter { !$0.draft && $0.review.isEmpty }.count)", label: "ohne Review", tint: .indigo)
            StatTile(icon: "camera.viewfinder", value: "\(feedback.filter(\.needsMartin).count)/\(feedback.filter(\.needsAgent).count)", label: "Feedback dich/Agent", tint: .pink)
            StatTile(icon: "calendar", value: "\(turns)", label: "Turns heute", tint: .gray)
            StatTile(icon: "arrow.triangle.merge", value: "\(merged)", label: "heute gemergt", tint: .mint)
        }
    }

    // MARK: Agents

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

        return HStack(alignment: .top, spacing: 12) {
            Avatar(look: Look.agent(store.name(for: s.id)), mood: s.mood, prop: hub.prop(s), px: 4)
                .frame(width: 74, height: 66)
                .background(Circle().fill(color.opacity(0.08)).frame(width: 84, height: 84))
            agentBody(s, peek: peek, links: links, status: status, color: color, meta: meta)
        }
        .card(s.mood == .waiting ? .orange : nil, padding: 14)
    }

    private func agentBody(_ s: Session, peek: Peek?, links: [(String, () -> Void)], status: String, color: Color, meta: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center) {
                Text(store.name(for: s.id)).font(.system(size: 15, weight: .bold))
                Text(brain.topic(s)).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                StatusPill(text: status, color: color)
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

    // MARK: MRs in progress

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
        .card()
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

    // MARK: With others and automatic

    private var elsewhere: some View {
        let list = brain.items.filter { $0.who != .you && $0.group != "agent" }
        return VStack(alignment: .leading, spacing: 3) {
            heading("Liegt bei anderen oder läuft von allein", list.count)
            ForEach(Array(list.prefix(15).enumerated()), id: \.offset) { _, a in
                Text("\(a.icon) \(a.phrase)").font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .card()
    }

    // MARK: History

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
        .card()
    }

    private func heading(_ title: String, _ count: Int) -> some View {
        SectionTitle(title: title, count: count)
    }
}
