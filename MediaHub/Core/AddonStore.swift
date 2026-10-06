import Foundation
import Observation

@MainActor @Observable
final class AddonStore {
    private(set) var addons: [Addon] = []
    /// Bumps after a reload so Home refetches catalogs even though the add-on ids are unchanged.
    private(set) var revision = 0
    private let key = "addon.manifestURLs"
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

    // TODO: move to Keychain — debrid add-on URLs embed API keys.
    private func persist() {
        UserDefaults.standard.set(addons.map(\.manifestURL.absoluteString), forKey: key)
    }

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
    }
}
