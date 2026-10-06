import Foundation

/// Finds a title logo (clear-logo PNG) for a movie or show. Sources, in order:
/// TMDB images (needs the TMDB key) → TheTVDB (needs the TVDB key) → the add-on's own logo → Metahub (no key).
/// Results are cached on disk, so each title is looked up once.
actor LogoResolver {
    static let shared = LogoResolver()
    private var cache: [String: URL] = [:]
    private var misses = Set<String>()
    /// Lookups already running, so a title asked for by several views at once is resolved (and fetched) only once.
    private var inflight: [String: Task<URL?, Never>] = [:]
    private let storeKey = "logo.cache"

    nonisolated var enabled: Bool { UserDefaults.standard.object(forKey: "ui.titleLogos") as? Bool ?? true }

    init() {
        if let d = UserDefaults.standard.dictionary(forKey: "logo.cache") as? [String: String] {
            cache = d.compactMapValues { URL(string: $0) }
        }
    }

    func logo(for item: MetaPreview) async -> URL? {
        guard enabled else { return nil }
        if let hit = cache[item.id] { return hit }
        if misses.contains(item.id) { return nil }
        if let running = inflight[item.id] { return await running.value }
        let lookup = Task { await find(item) }
        inflight[item.id] = lookup
        let result = await lookup.value
        inflight[item.id] = nil
        guard let found = result else { misses.insert(item.id); return nil }
        cache[item.id] = found
        persist()
        return found
    }

    private func find(_ item: MetaPreview) async -> URL? {
        if TMDBClient.shared.hasKey, let u = await TMDBClient.shared.logo(for: item.id, type: item.type) { return u }

        var imdb: String? = item.id.hasPrefix("tt") ? item.id : nil
        if imdb == nil, TMDBClient.shared.hasKey, item.id.hasPrefix("tmdb:"), let n = Int(item.id.dropFirst(5)) {
            imdb = await TMDBClient.shared.imdbID(tmdb: n, type: item.type)
        }
        if let imdb, TVDBClient.shared.hasKey, let u = await TVDBClient.shared.logo(imdb: imdb, type: item.type) { return u }
        if let l = item.logo.flatMap(URL.init(string:)), await exists(l) { return l }
        if let imdb, let u = URL(string: "https://images.metahub.space/logo/medium/\(imdb)/img"), await exists(u) { return u }
        return nil
    }

    private func exists(_ url: URL) async -> Bool {
        var r = URLRequest(url: url)
        r.httpMethod = "HEAD"; r.timeoutInterval = 6
        guard let (_, resp) = try? await URLSession.shared.data(for: r) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    private func persist() {
        if cache.count > 600 { cache = Dictionary(uniqueKeysWithValues: Array(cache.prefix(400))) }
        UserDefaults.standard.set(cache.mapValues(\.absoluteString), forKey: storeKey)
    }
}
