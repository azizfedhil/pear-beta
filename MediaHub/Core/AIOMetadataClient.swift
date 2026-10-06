import Foundation

/// AIOMetadata backend (metadata source mode 2), implemented against the Stremio add-on protocol:
/// manifest discovery plus `/meta/{type}/{id}.json` detail lookups and `/catalog/…` listings.
/// Only `MetadataService` talks to this type, and everything maps onto the app's existing models
/// (`MetaPreview`, `EpisodeItem`, `TMDBClient.Details`) — no parallel UI structures.
///
/// Cinemeta replacement: when the user disables (or removes) the Cinemeta add-on while AIOMetadata
/// is configured, `MetadataService` routes catalogs/search/details/episode-lists here instead —
/// see `hasMetaCatalogs` and the catalog/search/meta paths below. No manual reconfiguration needed.
///
/// Networking mirrors `AddonClient`: one shared URLCache-backed session honoring ETag /
/// Cache-Control, so repeat launches don't refetch what the server says is fresh. On top of that:
/// * per-run result caches (details / lists / seasons / logos / ids) and negative caches, so a
///   flapping or offline endpoint is asked at most once per run — no retry storms, no timers;
/// * actor-isolated in-flight coalescing (the `LogoResolver` pattern), so two views opening the
///   same title share one request;
/// * transient failures are NOT cached — a later screen may try again exactly once.
///
/// Stream providers stay out of this file on purpose: addon/stream selection remains
/// `AddonClient.streams(for:type:addons:)` driven by `AddonStore.activeAddons`.
actor AIOMetadataClient {
    static let shared = AIOMetadataClient()

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = URLCache(memoryCapacity: 10 << 20, diskCapacity: 100 << 20)
        cfg.requestCachePolicy = .useProtocolCachePolicy
        cfg.timeoutIntervalForRequest = 12
        cfg.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: cfg)
    }()

    // Per-run caches (cleared on relaunch; HTTP caching covers cross-launch freshness).
    private var manifestCache: AIOManifest?                 // nil = not fetched yet; failure flag below
    private var manifestFailed = false
    private var metaCache: [String: AIMeta] = [:]          // "type:id" -> raw meta (ids/artwork/videos)
    private var detailsCache: [String: TMDBClient.Details] = [:]
    private var listCache: [String: [MetaPreview]] = [:]   // trending/discover/search/recommendations
    private var seasonCache: [String: [EpisodeItem]] = [:] // "id:season"
    private var seasonListCache: [String: [TMDBClient.SeasonInfo]?] = [:]  // imdb -> seasons (nil = asked, no answer)
    private var logoCache: [String: URL?] = [:]
    private var idCache: [String: String?] = [:]           // tmdb:… -> stremio/IMDb id
    private var inflight: [String: Task<Any, Error>] = [:]

    /// Safe default: nothing is configured until the user enters a URL, so `.aiometadata` mode
    /// behaves exactly like `.builtin` (zero extra requests) until then.
    nonisolated static let defaultBaseURL = ""

    /// Normalizes any entered URL to its scheme://host/base path (credentials/query dropped).
    nonisolated static func normalizedBase(_ raw: String) -> String? {
        guard var c = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = c.host, !host.isEmpty else { return nil }
        c.user = nil; c.password = nil; c.query = nil; c.fragment = nil
        var p = c.path
        while p.hasSuffix("/") { p = String(p.dropLast()) }
        return "\(scheme)://\(host)\(p)"
    }

    nonisolated static let baseURLKey = "aio.baseURL"
    nonisolated static let apiKeyDefaultKey = "aio.apiKeyDefault"   // first manifest key, remembered across launches

    /// The configured endpoint, empty when unset. Read straight from UserDefaults (like every other
    /// client's key access) — no observers or polling involved.
    nonisolated var baseURL: String {
        get { UserDefaults.standard.string(forKey: Self.baseURLKey) ?? Self.defaultBaseURL }
        set {
            if let v = newValue.isEmpty ? nil : Self.normalizedBase(newValue), !v.isEmpty {
                UserDefaults.standard.set(v, forKey: Self.baseURLKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.baseURLKey)
            }
        }
    }
    /// True once an endpoint is configured; gates `MetadataService.aioActive`. Nonisolated on
    /// purpose (plain UserDefaults read, like every other client's key access) so the facade can
    /// check cheaply without hopping actors.
    nonisolated var isConfigured: Bool { !baseURL.isEmpty }

    /// Actor-isolated configuration check for code that already crosses into this actor.
    func configured() -> Bool { isConfigured }

    /// Optional API key. AIOMetadata-style manifests declare it themselves (`resources[].apiKeys`);
    /// we remember the first declared key name so the user only has to enter the value.
    nonisolated var apiKeyName: String {
        UserDefaults.standard.string(forKey: Self.apiKeyDefaultKey) ?? "apiKey"
    }
    nonisolated var apiKeyValue: String { UserDefaults.standard.string(forKey: "aio.\(apiKeyName)") ?? "" }

    private init() {}

    /// Drops every in-memory cache after the endpoint/key changes (HTTP cache is left alone).
    /// In-flight coalescing entries are cleared too, so a request started against the OLD endpoint
    /// can't register its result into the fresh caches when it lands.
    func resetCaches() {
        manifestCache = nil; manifestFailed = false
        metaCache.removeAll(); detailsCache.removeAll(); listCache.removeAll()
        seasonCache.removeAll(); logoCache.removeAll(); idCache.removeAll()
        inflight.removeAll()
    }

    // MARK: Wire format (tolerant decoding — third-party servers are inconsistent)

    /// Manifest shapes. Declared `internal` (not `private`) on purpose: capability methods such as
    /// `catalogList(_:)` expose these types in their signatures, and Swift requires any type used in
    /// an internal method signature to be at least internal itself. They stay implementation details
    /// — only `MetadataService` talks to this actor.
    struct AIOManifest: Decodable {
        struct Resource: Decodable {
            let name: String
            let types: [String]?
            let idPrefixes: [String]?
            let apiKeys: [String]?
        }
        struct Catalog: Decodable {
            let type: String
            let id: String
            let name: String?
            let extra: [Extra]?
            let extraSupported: [String]?
            let extraRequired: [String]?
            struct Extra: Decodable { let name: String; let isRequired: Bool? }
            var supportedExtras: Set<String> {
                Set((extra ?? []).map(\.name) + (extraSupported ?? []) + (extraRequired ?? []))
            }
            var requiredExtras: Set<String> {
                Set((extra ?? []).filter { $0.isRequired ?? false }.map(\.name) + (extraRequired ?? []))
            }
            var isBrowsable: Bool { requiredExtras.isEmpty }
            var supportsSkip: Bool { supportedExtras.contains("skip") }
            var isSearchable: Bool { supportedExtras.contains("search") && requiredExtras.subtracting(["search"]).isEmpty }
        }
        let id: String?
        let name: String?
        let version: String?
        let description: String?
        let resources: [Resource]?
        let catalogs: [Catalog]?

        private enum CodingKeys: String, CodingKey {
            case id, name, version, description, catalogs, resources
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try c.decodeIfPresent(String.self, forKey: .id)
            self.name = try c.decodeIfPresent(String.self, forKey: .name)
            self.version = try c.decodeIfPresent(String.self, forKey: .version)
            self.description = try c.decodeIfPresent(String.self, forKey: .description)
            self.catalogs = try c.decodeIfPresent([Catalog].self, forKey: .catalogs)
            if let objs = try? c.decode([Resource].self, forKey: .resources) {
                self.resources = objs
            } else if let strs = try? c.decode([String].self, forKey: .resources) {
                self.resources = strs.map { Resource(name: $0, types: nil, idPrefixes: nil) }
            } else {
                self.resources = nil
            }
        }
    }

    /// One AIOMetadata/Stremio "meta" object. `MetaPreview`'s own fields cover the basics; the rest
    /// carries cast, runtime, external ids and videos for the richer mappings below.
    private struct AIMeta: Decodable {
        let id: String
        let type: String
        let name: String
        let poster: String?
        let background: String?
        let logo: String?
        let description: String?
        let releaseInfo: String?
        let imdbRating: String?
        let genres: [String]?
        let released: String?
        let year: String?
        let runtime: String?
        let cast: [String]?
        let director: [String]?
        let writer: [String]?
        let imdbId: String?
        let link: String?
        let videos: [AIVideo]?
        struct AIVideo: Decodable {
            let id: String?; let title: String?; let released: String?
            let trailer: String?; let ytId: String?
        }
        var preview: MetaPreview {
            MetaPreview(id: id, type: type, name: name, poster: poster, background: background,
                        logo: logo, description: description, releaseInfo: releaseInfo,
                        rating: imdbRating.flatMap(Double.init))
        }
        var stremioType: String { type == "tv" || type == "series" ? "series" : "movie" }
        var yearNumber: Int? {
            if let y = Self.digits(year), (1880...2100).contains(y) { return y }
            if let y = Self.digits(released), (1880...2100).contains(y) { return y }
            return MetaPreview.yearOf(releaseInfo) ?? Self.digits(releaseInfo)
        }
        var imdbID: String? {
            if let i = imdbId, i.hasPrefix("tt") { return i }
            if let l = link, let r = l.range(of: "/tt") ?? l.range(of: "?i=") {
                let tail = l[r.upperBound...].prefix(while: { $0.isLetter || $0.isNumber })
                if tail.hasPrefix("tt"), tail.count >= 8 { return String(tail) }
            }
            return id.hasPrefix("tt") ? id : nil
        }
        var tmdbID: Int? {
            if id.hasPrefix("tmdb:"), let n = Int(id.dropFirst(5)) { return n }
            guard let l = link?.lowercased(), let r = l.range(of: "themoviedb.org/") else { return nil }
            let after = l[r.upperBound...]
            let seg = after.prefix { $0.isNumber }
            return Int(seg)
        }
        var tvdbID: Int? {
            if id.hasPrefix("tvdb:"), let n = Int(id.dropFirst(5)) { return n }
            guard let l = link?.lowercased(), let r = l.range(of: "thetvdb.com/") else { return nil }
            let after = l[r.upperBound...]
            let seg = after.prefix { $0.isNumber }
            return Int(seg)
        }
        /// All digits of a string as one number ("1 h 32 min" is intentionally NOT parsed here —
        /// callers pass already-scoped values like "tmdb:123" tails or plain numbers).
        static func digits(_ s: String?) -> Int? {
            guard let s else { return nil }
            let d = s.filter(\.isNumber)
            return d.isEmpty ? nil : Int(d)
        }
    }

    private struct AIMetaResponse: Decodable { let meta: AIMeta? }
    private struct AICatalogResponse: Decodable { let metas: [AIMeta]? }

    // MARK: Fetch plumbing

    private func data(_ url: URL) async throws -> Data {
        guard isConfigured else { throw URLError(.unsupportedURL) }
        var req = URLRequest(url: url)
        if !apiKeyValue.isEmpty {
            req.setValue(apiKeyValue, forHTTPHeaderField: "X-API-KEY")     // common gateway convention
            req.url = appendingQuery(to: url, items: [(apiKeyName, apiKeyValue)])
        }
        let (d, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return d
    }

    /// Builds URLs manually: `appendingPathComponent` would percent-encode the "/" inside
    /// "tmdb:123" style ids, which Stremio-protocol servers expect verbatim.
    private func appendingQuery(to url: URL, items: [(String, String)]) -> URL {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var q = c.queryItems ?? []
        for (k, v) in items where !v.isEmpty {
            let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            q.append(URLQueryItem(name: k, value: v.addingPercentEncoding(withAllowedCharacters: safe) ?? v))
        }
        c.queryItems = q
        return c.url ?? url
    }

    /// Coalesces identical concurrent lookups (one network request even if several views ask at once).
    /// The leader registers an actor-isolated `Task` whose result every caller awaits directly, and
    /// clears the entry when it finishes. A follower that arrives while a request is in flight joins
    /// the same task — no second request can start; if the cache re-check in front of this call
    /// already hit, the network is skipped entirely. `inflight` is only mutated by actor-isolated
    /// code with no suspension between check-and-register, so there is no leader race, and because
    /// callers share one task there is no "leader finished but cache still empty" retry storm.
    private func coalesce<T: Sendable>(key: String, _ body: @Sendable @escaping () async throws -> T) async throws -> T {
        if let running = inflight[key] {
            return try await running.value as! T
        }
        let task = Task<Any, Error> {
            try await body()
        }
        inflight[key] = task
        defer { inflight[key] = nil }
        return try await task.value as! T
    }

    private func encoded(_ s: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~:"))
        return s.addingPercentEncoding(withAllowedCharacters: safe) ?? s
    }

    // MARK: Manifest

    private func manifest() async -> AIOManifest? {
        if let m = manifestCache { return m }
        if manifestFailed || !isConfigured { return nil }
        return await coalesce("manifest") { () -> AIOManifest? in
            if let m = self.manifestCache { return m }
            guard let url = URL(string: self.baseURL + "/manifest.json"),
                  let d = try? await self.data(url),
                  let m = try? JSONDecoder().decode(AIOManifest.self, from: d) else {
                self.manifestFailed = true       // unreachable endpoint: stop asking this run
                return nil
            }
            self.manifestCache = m
            // Adopt the key name the server declares (e.g. "apiKey"), remembering it across launches.
            if let declared = m.resources?.first(where: { !($0.apiKeys ?? []).isEmpty })?.apiKeys?.first,
               UserDefaults.standard.string(forKey: Self.apiKeyDefaultKey) != declared {
                UserDefaults.standard.set(declared, forKey: Self.apiKeyDefaultKey)
            }
            return m
        }
    }

    private func provides(_ resource: String, type: String, id: String) async -> Bool {
        guard let rs = await manifest()?.resources else { return false }
        for r in rs where r.name == resource {
            if let t = r.types, !t.contains(type) { continue }
            if let p = r.idPrefixes, !p.contains(where: id.hasPrefix) { continue }
            return true
        }
        return false
    }

    /// Whether AIOMetadata can serve browsable catalogs for a type — the flag `MetadataService` uses
    /// to decide whether it should take over the role of a disabled Cinemeta.
    func hasMetaCatalogs(type: String) async -> Bool {
        let wanted = type == "tv" ? "series" : type   // callers pass either vocabulary
        return (await manifest()?.catalogs ?? []).contains { $0.type == wanted && $0.isBrowsable }
    }

    // MARK: Title meta (raw)

    private func rawMeta(id: String, type: String) async -> AIMeta? {
        let key = "\(type):\(id)"
        if let hit = metaCache[key] { return hit }
        guard await provides("metadata", type: type, id: id) else { return nil }
        return await coalesce("meta:" + key) { () -> AIMeta? in
            if let hit = self.metaCache[key] { return hit }
            guard let url = URL(string: self.baseURL + "/meta/\(type)/\(self.encoded(id)).json"),
                  let d = try? await self.data(url) else { return nil }
            guard let res = try? JSONDecoder().decode(AIMetaResponse.self, from: d),
                  let m = res.meta else { return nil }
            self.metaCache[key] = m
            return m
        }
    }

    // MARK: Capabilities (signatures mirror MetadataService's fallback points)

    func details(id: String, type: String) async throws -> TMDBClient.Details {
        let key = "\(type):\(id)"
        if let hit = detailsCache[key] { return hit }
        // Coalesced through `rawMeta` (which owns the network hop + its own in-flight joining);
        // the mapping below is pure and synchronous, so concurrent callers can't duplicate work.
        guard let m = await rawMeta(id: id, type: type) else { throw URLError(.cannotParseResponse) }
        var crew: [TMDBClient.Details.Person]?
        if let w = m.writer, !w.isEmpty { crew = w.map { .init(name: $0, job: "Writer") } }
        if let di = m.director, !di.isEmpty { crew = (crew ?? []) + di.map { .init(name: $0, job: "Director") } }
        let d = TMDBClient.Details(
            overview: m.description, tagline: nil,
            runtime: AIMeta.digits(m.runtime), episodeRunTime: nil,
            voteAverage: m.imdbRating.flatMap(Double.init),
            genres: m.genres?.map { .init(name: $0) },
            numberOfSeasons: nil, numberOfEpisodes: nil,
            credits: (m.cast?.isEmpty == false || crew?.isEmpty == false)
                ? .init(cast: m.cast?.map { .init(name: $0, job: nil) }, crew: crew) : nil,
            seasons: nil, networks: nil, status: nil,
            productionCompanies: nil, productionCountries: nil, spokenLanguages: nil, createdBy: nil,
            firstAirDate: m.released, lastAirDate: nil, releaseDate: m.released, budget: nil, revenue: nil)
        detailsCache[key] = d
        return d
    }

    func recommendations(id: String, type: String) async throws -> [MetaPreview] {
        let key = "rec:\(type):\(id)"
        if let hit = listCache[key] { return hit }
        guard let cat = await manifest()?.catalogs?.first(where: {
            $0.type == type && (($0.id.lowercased().contains("similar") || $0.id.lowercased().contains("recommend"))
                                || ($0.name?.lowercased().contains("similar") ?? false))
        }) else { throw URLError(.resourceUnavailable) }
        let items = await catalogList(cat, type: type, skip: 0, search: nil, extra: [("id", id)])
        guard !items.isEmpty else { throw URLError(.zeroByteResource) }
        listCache[key] = items
        return items
    }

    func trending(kind: String, page: Int) async throws -> [MetaPreview] {
        let key = "trend:\(kind):\(page)"
        if let hit = listCache[key] { return hit }
        let wanted = kind == "tv" ? "series" : kind
        let cats = (await manifest()?.catalogs ?? []).filter { $0.type == wanted && $0.isBrowsable }
        guard let cat = cats.first(where: { $0.id.lowercased().contains("popular") || $0.id.lowercased().contains("trending") })
                ?? cats.first else { throw URLError(.resourceUnavailable) }
        let skip = cat.supportsSkip ? (max(page, 1) - 1) * 100 : (page > 1 ? 0 : (cat.supportsSkip ? 0 : -1))
        // Pages beyond the first are only meaningful when the server supports skip.
        guard page == 1 || cat.supportsSkip else { throw URLError(.resourceUnavailable) }
        let items = await catalogList(cat, type: wanted, skip: max(skip, 0), search: nil, extra: [])
        guard !items.isEmpty else { throw URLError(.zeroByteResource) }
        listCache[key] = items
        return items
    }

    func discover(kind: String, genre: Int?, year: Int?, sort: DiscoverSort, page: Int) async throws -> [MetaPreview] {
        // Stremio catalogs have no genre-id vocabulary; only pure browsing maps cleanly.
        guard genre == nil, year == nil, sort == .popular else { throw URLError(.unsupportedURL) }
        let wanted = kind == "tv" ? "series" : kind
        let key = "disc:\(wanted):\(page)"
        if let hit = listCache[key] { return hit }
        let cats = (await manifest()?.catalogs ?? []).filter { $0.type == wanted && $0.isBrowsable }
        guard let cat = cats.first(where: { !$0.id.lowercased().contains("popular") && !$0.id.lowercased().contains("trending") })
                ?? cats.first else { throw URLError(.resourceUnavailable) }
        guard page == 1 || cat.supportsSkip else { throw URLError(.resourceUnavailable) }
        let items = await catalogList(cat, type: wanted, skip: (max(page, 1) - 1) * 100, search: nil, extra: [])
        guard !items.isEmpty else { throw URLError(.zeroByteResource) }
        listCache[key] = items
        return items
    }

    func search(query: String) async throws -> [MetaPreview] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let key = "search:\(q.lowercased())"
        if let hit = listCache[key] { return hit }
        let cats = (await manifest()?.catalogs ?? []).filter { $0.isSearchable }
        var out: [MetaPreview] = []
        var seen = Set<String>()
        for cat in cats.prefix(3) {
            for m in await catalogList(cat, type: cat.type, skip: 0, search: q, extra: []) where seen.insert(m.id).inserted {
                out.append(m)
            }
        }
        guard !out.isEmpty else { throw URLError(.zeroByteResource) }
        listCache[key] = out
        return out
    }

    /// One catalog page mapped to `MetaPreview`s (the same wire shape Cinemeta serves).
    func catalogList(_ cat: AIOManifest.Catalog, type: String, skip: Int,
                             search: String?, extra: [(String, String)]) async -> [MetaPreview] {
        let key = "cat:\(cat.id):\(type):\(skip):\(search ?? ""):\(extra.map(\.0))"
        if let hit = listCache[key] { return hit }
        return await coalesce("list:" + key) { () -> [MetaPreview] in
            if let hit = self.listCache[key] { return hit }
            var parts = ["type=\(self.encoded(type))"]
            if skip > 0 { parts.append("skip=\(skip)") }
            if let s = search, !s.isEmpty { parts.append("search=\(self.encoded(s))") }
            for (k, v) in extra { parts.append("\(k)=\(self.encoded(v))") }
            var path = self.baseURL + "/catalog/\(type)/\(cat.id)"
            if !parts.isEmpty { path += "/" + parts.joined(separator: "&") }
            guard let url = URL(string: path + ".json"),
                  let d = try? await self.data(url) else { return [] }
            guard let res = try? JSONDecoder().decode(AICatalogResponse.self, from: d),
                  let metas = res.metas else { return [] }
            let out = metas.map { $0.preview }
            self.listCache[key] = out
            return out
        }
    }

    // MARK: Seasons & episodes

    /// Season numbers AIOMetadata knows about (from the show meta's embedded video ids).
    func seasons(id: String, type: String) async -> [Int] {
        guard let m = await rawMeta(id: id, type: type) else { return [] }
        var out = Set<Int>()
        for v in m.videos ?? [] {
            guard let vid = v.id else { continue }
            let comps = vid.split(separator: ":")
            if comps.count >= 3, comps.last?.allSatisfy(\.isNumber) == true,
               let s = Int(comps[comps.count - 3]) { out.insert(s) }
        }
        return out.sorted()
    }

    // MARK: Season details ("Seasons" section on Detail)

    private struct SEExtra: Decodable { let name: String?; let value: String? }
    private struct SESeason: Decodable {
        let season: Int?
        let title: String?
        let subtitle: String?
        let releaseInfo: String?
        let firstAired: String?
        let poster: String?
        let runtime: String?
        let id: String?
        let extras: [SEExtra]?
        var total: Int? {
            guard let e = extras else { return nil }
            for x in e where x.name?.lowercased().hasPrefix("total") == true {
                if let n = AIMeta.digits(x.value) { return n }
            }
            return nil
        }
    }
    private struct SEResponse: Decodable { let seasons: [SESeason]? }

    // MARK: Season details (community AIOMetadata endpoint)

    /// Base for the season-details service. Resolution order (no hardcoded production host):
    ///   1. explicit override `aio.seasonBase` (injected configuration, normalized like baseURL);
    ///   2. the user's configured AIOMetadata `baseURL`;
    ///   3. local debug builds only: the community dev host;
    ///   4. otherwise nil → the feature is simply skipped and callers fall back to TMDB.
    /// Requests go through their own plain session — no API-key injection ever happens here.
    /// Best-effort by design: any failure falls back to TMDB's season data.
    nonisolated static let seasonBaseKey = "aio.seasonBase"
    #if DEBUG
    nonisolated private static let fallbackSeasonBase = "https://bxtsai35n7.execute-api.eu-west-1.amazonaws.com"
    #else
    nonisolated private static let fallbackSeasonBase: String? = nil
    #endif

    private static let seasonSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = URLCache(memoryCapacity: 2 << 20, diskCapacity: 20 << 20)
        cfg.requestCachePolicy = .useProtocolCachePolicy
        cfg.timeoutIntervalForRequest = 12
        return URLSession(configuration: cfg)
    }()

    nonisolated private static func seasonDetailsURL(imdb: String) -> URL? {
        // Injected override wins; then the user's AIOMetadata endpoint; then the debug-only host.
        let raw = UserDefaults.standard.string(forKey: seasonBaseKey) ?? ""
        let base = !raw.isEmpty ? normalizedBase(raw)
            : (!AIOMetadataClient.shared.baseURL.isEmpty ? AIOMetadataClient.shared.baseURL
               : (fallbackSeasonBase ?? ""))
        guard let base, !base.isEmpty else { return nil }
        let path = base.hasSuffix("/proxy") ? "" : "/proxy"
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let e = imdb.addingPercentEncoding(withAllowedCharacters: safe) else { return nil }
        return URL(string: base + path + "/seasons/details/" + e)
    }

    /// Season list for a show (IMDb id), mapped onto `TMDBClient.SeasonInfo` so the existing UI
    /// consumes it unchanged. Returns nil when it cannot answer — callers then fall back to TMDB,
    /// never the other way round. Cached per run (misses included): at most one request per show.
    func seasonDetails(imdb: String) async -> [TMDBClient.SeasonInfo]? {
        guard imdb.hasPrefix("tt"), imdb.count >= 10 else { return nil }
        let key = "se:\(imdb)"
        if let hit = seasonListCache[key] { return hit }
        // The leader's result IS the cache value (nil = cached miss), so every joined caller gets
        // the same answer and the endpoint is asked exactly once per show per run.
        let out: [TMDBClient.SeasonInfo]? = await coalesce("list:" + key) { () -> [TMDBClient.SeasonInfo]? in
            if let hit = self.seasonListCache[key] { return hit }
            var result: [TMDBClient.SeasonInfo]?
            if let url = Self.seasonDetailsURL(imdb: imdb),
               let (d, resp) = try? await Self.seasonSession.data(from: url),
               (resp as? HTTPURLResponse)?.statusCode == 200 {
                guard let res = try? JSONDecoder().decode(SEResponse.self, from: d),
                      let list = res.seasons else {
                    self.seasonListCache[key] = result      // cached miss included: ask once per run
                    return result
                }
                let parsed = list.compactMap { s -> TMDBClient.SeasonInfo? in
                    guard let n = s.season else { return nil }
                    return TMDBClient.SeasonInfo(id: n, name: s.title, seasonNumber: n,
                                                 posterPath: nil, episodeCount: s.total, airDate: s.firstAired)
                }
                result = parsed.isEmpty ? nil : parsed
            }
            self.seasonListCache[key] = result      // cached miss included: ask once per run
            return result
        }
        return out
    }

    /// Episodes of one season. Returns nil ONLY when AIOMetadata cannot answer (facade falls back);
    /// an empty array means "answered: this season has no episodes". Numbering, titles, descriptions
    /// and air dates come straight from the `{imdb}:{season}:{episode}` video ids.
    func episodes(id: String, type: String, season: Int) async -> [EpisodeItem]? {
        let key = "\(id):\(season)"
        if let hit = seasonCache[key] { return hit }
        guard let m = await rawMeta(id: id, type: type) else { return nil }
        var out: [EpisodeItem] = []
        for v in m.videos ?? [] {
            guard let vid = v.id else { continue }
            let comps = vid.split(separator: ":")
            guard comps.count >= 3,
                  let ep = Int(comps[comps.count - 1]), ep >= 1,
                  let sn = Int(comps[comps.count - 2]), sn == season else { continue }
            let title = (v.title ?? "").replacingOccurrences(of: "\(sn):\(ep)", with: "").trimmingCharacters(in: .whitespaces)
            out.append(EpisodeItem(id: ep, name: title.isEmpty ? "Episode \(ep)" : title,
                                   overview: nil, image: nil, rating: nil, runtime: nil,
                                   airDate: Self.isoDay(v.released)))
        }
        out.sort { $0.id < $1.id }
        seasonCache[key] = out
        return out
    }

    private static func isoDay(_ s: String?) -> String? {
        guard let s, s.count >= 10, s.dropFirst(4).first == "-" else { return nil }
        return String(s.prefix(10))
    }

    // MARK: Artwork / extras / ids

    /// Clear-art logo carried in the meta object. Cached misses included: artwork lookups shouldn't
    /// re-hit the network every time the hero rotates.
    func logo(id: String, type: String) async -> URL? {
        let key = "\(type):\(id)"
        if let hit = logoCache[key] { return hit }
        guard await provides("metadata", type: type, id: id) else { logoCache[key] = nil; return nil }
        let url = await rawMeta(id: id, type: type)?.logo.flatMap(URL.init(string:))
        logoCache[key] = url
        return url
    }

    /// YouTube trailers embedded in the meta object, mapped onto the existing `Video` model.
    func videos(id: String, type: String) async -> [TMDBClient.Video]? {
        guard let m = await rawMeta(id: id, type: type) else { return nil }
        let out = (m.videos ?? []).compactMap { v -> TMDBClient.Video? in
            guard v.trailer == "true" || v.trailer == "1" || (v.title ?? "").lowercased().contains("trailer"),
                  let key = v.ytId ?? v.id?.components(separatedBy: "#").last, !key.isEmpty else { return nil }
            return TMDBClient.Video(id: key, key: key, name: v.title ?? "Trailer", site: "YouTube",
                                    type: "Trailer", official: nil, publishedAt: v.released)
        }
        return out
    }

    /// Cross-service id mapping. AIOMetadata ids ARE Stremio/IMDb ids, so this only converts
    /// "tmdb:…" sources via the meta object's external ids — never a guess.
    func resolveStremioID(id: String, type: String) async -> String? {
        guard id.hasPrefix("tmdb:") else { return id }
        let key = "\(type):\(id)"
        if let hit = idCache[key] { return hit }
        guard let m = await rawMeta(id: id, type: type) else { idCache[key] = nil; return nil }
        let out = m.imdbID ?? m.id
        idCache[key] = out
        return out
    }

    /// Full external-id record (IMDb / TMDB / TVDB / Stremio) for a title, best-effort.
    nonisolated struct ExternalIDs: Sendable {
        let stremio: String?
        let imdb: String?
        let tmdb: Int?
        let tvdb: Int?
    }
    func externalIDs(id: String, type: String) async -> ExternalIDs? {
        guard let m = await rawMeta(id: id, type: type) else { return nil }
        return ExternalIDs(stremio: m.id, imdb: m.imdbID, tmdb: m.tmdbID, tvdb: m.tvdbID)
    }

    /// True when AIOMetadata can serve as a Cinemeta replacement for `type`: it must be configured
    /// AND actually declare either a browsable catalog or a metadata resource for that type.
    /// The manifest fetch inside is cached per run (and negatively cached on failure), so callers
    /// may ask repeatedly without introducing extra requests or polling.
    func canReplaceCinemeta(for type: String) async -> Bool {
        guard isConfigured else { return false }
        if await hasMetaCatalogs(type: type) { return true }
        guard let rs = await manifest()?.resources else { return false }
        return rs.contains { r in
            guard r.name == "metadata" else { return false }
            return r.types == nil || r.types!.contains(type)
        }
    }

    /// Browsable catalogs mapped to the app's row model — the automatic stand-in for a disabled
    /// Cinemeta's Home rows. Deterministic priority: popular/trending first, then manifest order;
    /// capped so takeover can't fan out into a request storm. Titles carry the endpoint name so
    /// users can tell where takeover rows come from.
    func homeRows(type: String, limit: Int = 4) async -> [CatalogRow] {
        guard isConfigured, let cats = await manifest()?.catalogs else { return [] }
        let wanted = type == "tv" ? "series" : type
        // Rank ALL browsable catalogs of this type deterministically first, then cap — taking the
        // raw manifest prefix before sorting could drop a trending catalog that appears late.
        let ordered = cats.filter { $0.type == wanted && $0.isBrowsable }.sorted { a, b in
            func score(_ c: AIOManifest.Catalog) -> Int {
                let i = c.id.lowercased()
                if i.contains("trending") { return 0 }
                if i.contains("popular") { return 1 }
                return 2
            }
            let (sa, sb) = (score(a), score(b))
            if sa != sb { return sa < sb }
            return a.id < b.id
        }
        var out: [CatalogRow] = []
        var seen = Set<String>()
        for cat in ordered.prefix(max(limit, 1)) {   // cap requests per call (see doc comment)
            let items = await catalogList(cat, type: wanted, skip: 0, search: nil, extra: [])
            let fresh = items.filter { seen.insert($0.id).inserted }
            guard !fresh.isEmpty else { continue }
            let kind = wanted == "movie" ? "Movies" : "Series"
            out.append(CatalogRow(id: "aio/\(wanted)/\(cat.id)",
                                  title: "\(cat.name ?? cat.id) \(kind)",
                                  items: fresh, source: .none, symbol: "sparkles"))
        }
        return out
    }
}
