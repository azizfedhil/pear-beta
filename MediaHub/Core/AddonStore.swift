import Foundation
import Observation

@MainActor @Observable
final class AddonStore {
    /// Every installed add-on, in display order: enabled ones first (by rank), disabled ones trail.
    private(set) var addons: [Addon] = []
    /// Bumps after a reload so Home refetches catalogs even though the add-on ids are unchanged.
    private(set) var revision = 0
    /// The enabled add-ons in priority order — what every request path (catalogs, search, streams) should use.
    var activeAddons: [Addon] { addons.filter(\.enabled) }
    private let key = "addon.manifestURLs"
    static let prefsKey = "addon.prefs"
    // Public metadata-only add-on, so Home isn't empty on first launch.
    private static let defaults = ["https://v3-cinemeta.strem.io/manifest.json"]

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: key) ?? Self.defaults
        Task { await restore(saved) }
    }

    func add(_ input: String) async throws {
        let url = try Addon.normalize(input)
        guard !addons.contains(where: { $0.manifestURL == url }) else { return }
        let manifest = try await AddonClient.shared.manifest(at: url)
        addons.append(Addon(manifestURL: url, manifest: manifest))
        persist()
    }

    /// Re-fetches one add-on's manifest (bypassing the HTTP cache) and refreshes its catalogs.
    func reload(_ addon: Addon) async throws {
        await AddonClient.shared.clearCache()
        let m = try await AddonClient.shared.manifest(at: addon.manifestURL, fresh: true)
        guard let i = addons.firstIndex(where: { $0.id == addon.id }) else { return }
        addons[i] = Addon(manifestURL: addon.manifestURL, manifest: m)
        revision += 1
    }

    /// Reloads every add-on. Returns how many failed (those keep their old manifest).
    func reloadAll() async -> Int {
        await AddonClient.shared.clearCache()
        var failed = 0
        for a in addons {
            if let m = try? await AddonClient.shared.manifest(at: a.manifestURL, fresh: true),
               let i = addons.firstIndex(where: { $0.id == a.id }) {
                addons[i] = Addon(manifestURL: a.manifestURL, manifest: m)
            } else { failed += 1 }
        }
        revision += 1
        return failed
    }

    /// Re-reads the saved add-on list (after a settings import).
    func reloadFromDefaults() async {
        await restore(UserDefaults.standard.stringArray(forKey: key) ?? Self.defaults)
        revision += 1
    }

    func remove(at offsets: IndexSet) {
        addons.remove(atOffsets: offsets)
        persist()
    }

    /// Enables or disables an add-on without deleting it. Disabled add-ons drop out of
    /// `activeAddons` (so no catalog / search / stream request goes to them) and move to the end
    /// of the list; re-enabling puts the add-on back at the top of the enabled block.
    func setEnabled(_ id: String, _ on: Bool) {
        guard let i = addons.firstIndex(where: { $0.id == id }), addons[i].enabled != on else { return }
        addons[i].enabled = on
        persist()   // writes the flag into prefs, then `sortAddons` re-applies the persisted order
    }

    /// Reorders the visible list (Settings' reorder mode); the new order is written as ranks by `persist`.
    func move(from source: IndexSet, to destination: Int) {
        addons.move(fromOffsets: source, toOffset: destination)
        persist(sorted: true)
    }

    // TODO: move to Keychain — debrid add-on URLs embed API keys.
    private func persist(sorted doSort: Bool = false) {
        var prefs = Self.loadPrefs()
        for a in addons { prefs.states[a.id]?.enabled = a.enabled }
        if doSort {
            // A manual move: adopt the UI order, then restore the enabled-first invariant so a
            // disabled add-on dragged into the enabled block can't bake in a rank that flips back
            // on next launch (`sortAddons` always re-splits enabled/disabled). Relative order of
            // the enabled block — the actual priority pipeline — is exactly what the user arranged.
            let moved = addons.sorted { x, y in orderHint[x.id, default: .max] < orderHint[y.id, default: .max] }
            addons = moved.filter(\.enabled) + moved.filter { !$0.enabled }
            orderHint = Dictionary(uniqueKeysWithValues: addons.enumerated().map { ($1.id, $0) })
        } else {
            sortAddons(using: prefs)
        }
        prefs.apply(order: addons.map(\.id))   // rewrites ranks and drops entries of removed add-ons
        UserDefaults.standard.set(addons.map(\.manifestURL.absoluteString), forKey: key)
        savePrefs(prefs)
        publishPriority()
    }

    /// Hands the enabled-in-priority-order list to the metadata facade. One plain array copy per
    /// user-initiated change — no observers, timers or polling involved.
    private func publishPriority() {
        MetadataService.shared.setActiveAddons(activeAddons)
    }

    /// Transient UI order while a manual move hasn't been written to disk yet (reorder mode only).
    private var orderHint: [String: Int] = [:]

    /// Round-trips through `AddonPrefs`' own Codable conformance, so its tolerant per-entry
    /// decoding actually applies: one malformed entry is skipped instead of dropping every
    /// user's enable/order state. The encoded shape is identical to the old `[id: State]`
    /// dictionary, so existing stored files migrate unchanged.
    static func loadPrefs() -> AddonPrefs {
        guard let d = UserDefaults.standard.data(forKey: prefsKey),
              let p = try? JSONDecoder().decode(AddonPrefs.self, from: d) else { return AddonPrefs() }
        return p
    }

    private static func savePrefs(_ prefs: AddonPrefs) {
        if let d = try? JSONEncoder().encode(prefs) {
            UserDefaults.standard.set(d, forKey: prefsKey)
        }
    }

    /// Applies the persisted enable/order state to the in-memory list (enabled first, then rank).
    private func sortAddons(using prefs: AddonPrefs) {
        for i in addons.indices { addons[i].enabled = prefs.isEnabled(addons[i].id) }
        addons.sort { prefs.order($0, $1) }
    }

    private func sortAddons() { sortAddons(using: Self.loadPrefs()) }

    private func restore(_ urls: [String]) async {
        var found: [Int: Addon] = [:]
        await withTaskGroup(of: (Int, Addon?).self) { group in
            for (i, s) in urls.enumerated() {
                group.addTask {
                    guard let url = try? Addon.normalize(s),
                          let m = try? await AddonClient.shared.manifest(at: url) else { return (i, nil) }
                    return (i, Addon(manifestURL: url, manifest: m))
                }
            }
            for await (i, a) in group { found[i] = a }
        }
        addons = found.keys.sorted().compactMap { found[$0] }
        sortAddons()
        // Prune prefs for add-ons that no longer resolve, then rewrite the surviving ranks.
        var prefs = Self.loadPrefs()
        prefs.normalize(ids: Set(addons.map(\.id)))
        Self.savePrefs(prefs)
        publishPriority()
    }
}
