import Foundation

/// Something noteworthy about an agent, e.g. "going in circles".
struct Problem {
    var kind: String
    var text: String
}

/// Checks every 30 s whether an agent is stuck: repeatedly failing tools, the same calls in a loop,
/// long silence, or a very full context. Each anomaly is posted to the inbox once per turn.
final class Watchdog {
    let store: Store
    let logs: SessionLogs
    let works: Works
    private(set) var problems: [String: [Problem]] = [:]
    private var told: Set<String> = []

    /// From here on the context counts as full. The window size per model isn't in the transcript, so it's hardcoded.
    static let fullContext = 800_000

    init(store: Store, logs: SessionLogs, works: Works) {
        self.store = store
        self.logs = logs
        self.works = works
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.check() }
    }

    func check() {
        var out: [String: [Problem]] = [:]
        for s in store.agents {
            var list: [Problem] = []
            let log = logs.log(s.transcript)
            if s.mood == .working {
                let quiet = Date().timeIntervalSince(s.updated)
                if s.lastEvent == "pretool", quiet > 20 * 60 {
                    list.append(Problem(kind: "slow", text: "Ein Werkzeug läuft seit \(duration(quiet)): \(shorten(s.detail, 70))"))
                } else if s.lastEvent != "pretool", quiet > 10 * 60 {
                    list.append(Problem(kind: "silent", text: "Seit \(duration(quiet)) kein Lebenszeichen."))
                }
                if let turn = log?.turns.last {
                    let recent = turn.tools.suffix(3)
                    if recent.count == 3, recent.allSatisfy(\.error), let c = recent.last {
                        list.append(Problem(kind: "errors", text: "Die letzten drei Werkzeugaufrufe sind fehlgeschlagen (\(c.name): \(shorten(c.detail, 60)))."))
                    }
                    let counts = Dictionary(grouping: turn.tools.suffix(14), by: { $0.name + " · " + $0.detail }).mapValues(\.count)
                    if let top = counts.max(by: { $0.value < $1.value }), top.value >= 4 {
                        list.append(Problem(kind: "loop", text: "Dreht sich im Kreis: \(top.value)× \(shorten(top.key, 70))"))
                    }
                }
            }
            if let ctx = log?.usage.last?.context, ctx >= Self.fullContext {
                list.append(Problem(kind: "context", text: "Kontext bei \(ctx / 1000)k Tokens. Zeit für /compact oder eine neue Session."))
            }
            if !list.isEmpty { out[s.id] = list }
            announce(s, list, turn: log?.turns.last?.start)
        }
        problems = out
    }

    private func announce(_ s: Session, _ list: [Problem], turn: Date?) {
        let stamp = Int((turn ?? s.busySince ?? .distantPast).timeIntervalSince1970)
        let fresh = list.filter { told.insert("\(s.id)|\($0.kind)|\(stamp)").inserted }
        guard !fresh.isEmpty else { return }
        store.post(Session(id: "warn-\(s.id)", mood: .waiting, project: s.project, agent: "Wächter",
                           text: fresh.map(\.text).joined(separator: " "), icon: "⚠️", click: s.click, isAgent: false))
    }
}
