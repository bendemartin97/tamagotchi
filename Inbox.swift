import Foundation

/// Eine Meldung in der Inbox, eine pro Quelle (Agent-Session, Aufgabe, Feedback-Punkt, Ticket). Neue Ereignisse
/// derselben Quelle hängen sich an den Verlauf an. Gelesen und erledigt setzt nur Martin; der echte Zustand
/// eines Agenten bleibt in Store.sessions.
struct Message: Codable {
    struct Event: Codable {
        var at: Date
        var icon: String
        var text: String
    }

    var id: String
    var agent = ""
    var isAgent = false
    var project = ""
    var icon = ""
    var text = ""
    /// Will etwas von Martin (Rückfrage, Freigabe, rote Pipeline, Review-Bitte).
    var question = false
    var click: [String] = []
    var events: [Event] = []
    var created = Date()
    var updated = Date()
    var read = false
    var archived: Date?
    var snoozed: Date?
    var pinned = false
    /// Von Martin gesetzte Einstufung, überstimmt die automatische.
    var priority: Triage.Rank?

    var symbol: String { icon.isEmpty ? (question ? "✋" : "✅") : icon }
    var active: Bool { archived == nil && (snoozed ?? .distantPast) <= Date() }
}

final class Inbox {
    /// So lange zeigt das Haustier eine neue Meldung als Sprechblase.
    static let bubbleFor: TimeInterval = 120

    var onChange: (() -> Void)?
    private(set) var all: [String: Message] = [:]
    /// Letzte Sammel- oder Einzelaktion, die sich zurücknehmen lässt.
    private(set) var undo: (label: String, before: [Message])?

    init() {
        for m in State.shared.data.inbox ?? [] { all[m.id] = m }
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.wake() }
    }

    /// Ungelesen und jünger als zwei Minuten: erscheint als Sprechblase, Rückfragen zuerst.
    var fresh: [Message] {
        all.values.filter { $0.active && !$0.read && Date().timeIntervalSince($0.updated) < Self.bubbleFor }
            .sorted { $0.question != $1.question ? $0.question : $0.updated > $1.updated }
    }

    var active: [Message] { all.values.filter(\.active).sorted { $0.updated > $1.updated } }
    var snoozed: [Message] { all.values.filter { $0.archived == nil && !$0.active }.sorted { ($0.snoozed ?? .distantPast) < ($1.snoozed ?? .distantPast) } }
    var archived: [Message] { all.values.filter { $0.archived != nil }.sorted { $0.archived! > $1.archived! } }
    var unreadCount: Int { all.values.filter { $0.active && !$0.read }.count }

    /// Neue Rückfrage oder Fertigmeldung einer Quelle.
    func record(_ s: Session) {
        var m = all[s.id] ?? Message(id: s.id)
        m.agent = s.agent
        m.isAgent = s.isAgent
        m.project = s.project
        m.icon = s.icon
        m.question = s.mood == .waiting
        m.text = m.question && s.isAgent && !s.detail.isEmpty ? "will: \(s.detail)\n\(s.text)" : s.text
        if !s.click.isEmpty { m.click = s.click }
        if m.events.last?.text != m.text || Date().timeIntervalSince(m.events.last?.at ?? .distantPast) > 600 {
            m.events.append(.init(at: Date(), icon: m.symbol, text: m.text))
            m.events = Array(m.events.suffix(40))
        }
        m.updated = Date()
        m.read = false
        m.archived = nil
        if m.question { m.snoozed = nil }
        all[s.id] = m
        changed()
    }

    /// Ein Agent arbeitet wieder (Martin hat im Terminal geantwortet): die Rückfrage bleibt im Verlauf, ist aber erledigt.
    func resumed(_ id: String) {
        guard var m = all[id], m.question, m.archived == nil else { return }
        m.question = false
        m.read = true
        m.events.append(.init(at: Date(), icon: "▶️", text: "Läuft weiter."))
        all[id] = m
        changed()
    }

    func markRead(_ id: String, _ read: Bool = true) {
        guard all[id]?.read == !read else { return }
        edit(id) { $0.read = read }
    }

    func archive(_ id: String) {
        guard let m = all[id] else { return }
        undo = ("„\(shorten(m.text.isEmpty ? m.project : m.text, 30))“ erledigt", [m])
        edit(id) { $0.archived = Date(); $0.read = true }
    }

    func archiveAll(_ ids: [String]) {
        let before = ids.compactMap { all[$0] }
        guard !before.isEmpty else { return }
        undo = ("\(before.count) Meldungen erledigt", before)
        for id in ids { all[id]?.archived = Date(); all[id]?.read = true }
        changed()
    }

    func restore(_ id: String) { edit(id) { $0.archived = nil } }

    func undoLast() {
        guard let u = undo else { return }
        undo = nil
        for m in u.before { all[m.id] = m }
        changed()
    }

    func snooze(_ id: String, until: Date) {
        guard let m = all[id] else { return }
        undo = ("Zurückgestellt", [m])
        edit(id) { $0.snoozed = until; $0.read = true }
    }

    func pin(_ id: String, _ on: Bool) { edit(id) { $0.pinned = on } }
    func prioritize(_ id: String, _ rank: Triage.Rank?) { edit(id) { $0.priority = rank } }

    private func edit(_ id: String, _ change: (inout Message) -> Void) {
        guard var m = all[id] else { return }
        change(&m)
        all[id] = m
        changed()
    }

    /// Wiedervorlagen werden fällig und Archiviertes älter als 14 Tage fällt raus.
    private func wake() {
        var dirty = false
        let cutoff = Date().addingTimeInterval(-14 * 86400)
        for (id, m) in all {
            if let a = m.archived, a < cutoff { all[id] = nil; dirty = true; continue }
            if let until = m.snoozed, until <= Date() {
                all[id]?.snoozed = nil
                all[id]?.read = false
                all[id]?.updated = Date()
                all[id]?.events.append(.init(at: Date(), icon: "⏰", text: "Wiedervorlage"))
                dirty = true
            }
        }
        if dirty { changed() }
    }

    private func changed() {
        State.shared.data.inbox = Array(all.values)
        State.shared.touch()
        onChange?()
    }
}

/// „Morgen 9 Uhr“, am Freitag und Wochenende der nächste Montag.
func nextMorning() -> Date {
    let cal = Calendar.current
    var day = cal.date(byAdding: .day, value: 1, to: Date())!
    while cal.isDateInWeekend(day) { day = cal.date(byAdding: .day, value: 1, to: day)! }
    return cal.date(bySettingHour: 9, minute: 0, second: 0, of: day)!
}
