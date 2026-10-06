import Foundation

/// Persisted enable/disable + ordering state for the installed add-ons.
///
/// Stored as a dictionary keyed by add-on id (the manifest URL), so removing an add-on later can't
/// leave stale entries behind and re-adding one restores its previous switch and rank. The order is
/// derived from each entry's `rank` rather than being stored as a separate URL list, which keeps it
/// consistent with `addon.manifestURLs` automatically: ids missing here default to enabled and sort
/// last in their saved-list order; ids that no longer resolve are dropped on the next persist.
///
/// Pure value type — decoding never fails, so old installs migrate safely (missing key = everything
/// enabled, in the order they were added).
struct AddonPrefs: Codable {
    struct State: Codable {
        var enabled: Bool = true
        var rank: Int = 0
    }

    var states: [String: State]   /// writable so `AddonStore.persist` can sync live enable flags before rewriting ranks

    init(states: [String: State] = [:]) { self.states = states }

    /// Decodes tolerantly: a malformed entry is skipped instead of dropping the whole file.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: StringCodingKey.self)
        var out: [String: State] = [:]
        for k in c.allKeys {
            if let s = try? c.decode(State.self, forKey: k) { out[k.stringValue] = s }
        }
        states = out
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: StringCodingKey.self)
        for (k, v) in states { try c.encode(v, forKey: StringCodingKey(k)) }
    }

    func state(for id: String) -> State { states[id] ?? State() }
    func isEnabled(_ id: String) -> Bool { state(for: id).enabled }

    /// Sort comparator: enabled first, then by rank, then by add-on id so ties stay stable.
    func order(_ a: Addon, _ b: Addon) -> Bool {
        let sa = state(for: a.id), sb = state(for: b.id)
        if sa.enabled != sb.enabled { return sa.enabled }
        if sa.rank != sb.rank { return sa.rank < sb.rank }
        return a.id < b.id
    }

    /// Rebuilds the ranks from an ordered id list (current UI order), preserving every enabled flag.
    mutating func apply(order: [String]) {
        var new: [String: State] = [:]
        for (i, id) in order.enumerated() {
            var s = state(for: id); s.rank = i
            new[id] = s
        }
        states = new
    }

    /// Drops entries whose add-on is gone, then rewrites the ranks in sorted order (enabled first).
    mutating func normalize(ids: Set<String>) {
        states = states.filter { ids.contains($0.key) }
        apply(order: sortedIDs())
    }

    /// All known ids in display order (disabled ones trail at the end by rank).
    func sortedIDs() -> [String] {
        states.keys.sorted { x, y in
            let sx = state(for: x), sy = state(for: y)
            if sx.enabled != sy.enabled { return sx.enabled }
            if sx.rank != sy.rank { return sx.rank < sy.rank }
            return x < y
        }
    }

    /// Keeps only the ids present in `ids`, preserving their relative order.
    func filtered(_ ids: Set<String>) -> [String] { sortedIDs().filter { ids.contains($0) } }
}

private struct StringCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
