import Foundation

/// A change to an MR/PR that the notifier bundles with others from the same task into a single notification.
struct Signal {
    enum Kind { case failed, fixed, comment, changes, approved, reviewRequested, conflict, merged, lost }
    var kind: Kind
    var change: Change
    var who: [String] = []
    var count = 1
    var excerpt = ""
}

/// Added lines of a diff that are meaningful enough for content checking.
func addedLines(_ patch: String) -> [String] {
    patch.split(separator: "\n").compactMap { line -> String? in
        guard line.hasPrefix("+"), !line.hasPrefix("+++") else { return nil }
        let t = line.dropFirst().trimmingCharacters(in: .whitespaces)
        return t.count >= 10 && t.rangeOfCharacter(from: .alphanumerics) != nil ? t : nil
    }
}

/// At least 70% of the added lines are still present in the files of the target branch; deleted files are missing there.
func contentPresent(_ files: [(path: String, added: [String], deleted: Bool)], fetch: (String) -> String?) -> Bool {
    var total = 0, found = 0
    for f in files where !f.path.isEmpty {
        let content = fetch(f.path)
        if f.deleted {
            total += 1
            if content == nil { found += 1 }
            continue
        }
        let sample = f.added.count > 12 ? stride(from: 0, to: f.added.count, by: f.added.count / 12).map { f.added[$0] } : f.added
        guard !sample.isEmpty else { continue }
        total += sample.count
        guard let content else { continue }
        found += sample.filter(content.contains).count
    }
    return total == 0 || Double(found) / Double(total) >= 0.7
}

/// Turns signals from a per-task query into a plain-language message, without numbers:
/// „Kalender grau: Fabian hat zwei neue Review-Punkte, die Backend-Pipeline ist rot.“ (Calendar gray: Fabian has two new review items, the backend pipeline is red.)
final class Notifier {
    let store: Store
    let works: Works
    var onKind: ((Signal.Kind) -> Void)?

    init(store: Store, works: Works) {
        self.store = store
        self.works = works
    }

    func post(_ signals: [Signal]) {
        guard !signals.isEmpty else { return }
        var groups: [String: [Signal]] = [:]
        for s in signals { groups[works.key(for: s.change), default: []].append(s) }
        for (key, list) in groups {
            let topic = works.topic(for: list[0].change)
            let sentences = list.map(sentence)
            let urgent = list.contains { [.failed, .comment, .changes, .reviewRequested, .conflict, .lost].contains($0.kind) }
            let icon = icon(list)
            let target = list.first { [.lost, .failed, .changes, .comment, .conflict, .reviewRequested].contains($0.kind) }?.change ?? list[0].change
            var body = sentences.joined(separator: " ")
            if list.count == 1, list[0].kind == .comment, !list[0].excerpt.isEmpty {
                body += " „\(shorten(list[0].excerpt, 110))“"
            }
            store.post(Session(id: "work-\(key)", mood: urgent ? .waiting : .done, project: topic, agent: "Änderungen", text: body,
                               icon: icon, click: ["-execute", "open \(shellQuote(link(target, failed: icon == "🔴")))"], isAgent: false))
            list.forEach { onKind?($0.kind) }
        }
    }

    /// When the pipeline is red, go straight to the pipelines or checks instead of the MR overview.
    private func link(_ c: Change, failed: Bool) -> String {
        guard failed else { return c.url }
        return c.url + (c.host == "github" ? "/checks" : "/pipelines")
    }

    private func icon(_ list: [Signal]) -> String {
        let kinds = Set(list.map(\.kind))
        if kinds.contains(.lost) { return "🕳" }
        if kinds.contains(.failed) { return "🔴" }
        if kinds.contains(.changes) { return "✏️" }
        if kinds.contains(.conflict) { return "⚔️" }
        if kinds.contains(.comment) { return "💬" }
        if kinds.contains(.reviewRequested) { return "👀" }
        if kinds.contains(.merged) { return "🎉" }
        if kinds.contains(.approved) { return "👍" }
        return "🟢"
    }

    private func sentence(_ s: Signal) -> String {
        let side = s.change.side
        let names = joinedList(Array(NSOrderedSet(array: s.who).compactMap { $0 as? String }))
        let who = names.isEmpty ? "Jemand" : names
        switch s.kind {
        case .failed: return "Die \(side)-Pipeline ist rot."
        case .fixed: return "Die \(side)-Pipeline ist wieder grün."
        case .merged: return "Die \(side)-Änderung ist gemergt."
        case .conflict: return "Die \(side)-Änderung hat einen Merge-Konflikt."
        case .approved: return "\(who) hat die \(side)-Änderung freigegeben."
        case .changes: return "\(who) wünscht Änderungen am \(side)."
        case .reviewRequested: return "\(who) bittet dich um ein Review im \(side)."
        case .lost: return "Die \(side)-Änderung wurde gemergt, fehlt aber inzwischen im Zielbranch."
        case .comment:
            let points = s.count == 1 ? "einen neuen Review-Punkt" : "\(numberWord(s.count)) neue Review-Punkte"
            return "\(who) hat \(points) im \(side) hinterlassen."
        }
    }
}
