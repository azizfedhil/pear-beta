import Foundation
import Observation

/// Which metadata backend answers title lookups: the built-in integrations
/// (TMDB / TheTVDB / MDBList / Cinemeta + Stremio add-ons) or AIOMetadata.
/// Persisted in UserDefaults, so it survives relaunches and settings backups;
/// switching modes never touches API keys or installed add-ons.
enum MetadataSourceMode: String, CaseIterable, Identifiable, Sendable {
    case builtin
    case aiometadata
    var id: String { rawValue }
    var label: String { self == .builtin ? "Built-in integrations" : "AIOMetadata" }
}

/// The single entry point for metadata: provider selection, ID resolution, fallbacks and merging.
///
/// Views and view models call this facade instead of deciding which provider to hit — but only for
/// *metadata* concerns (title details, recommendations, search, catalogs, episodes, logos, ratings,
/// cross-service ids). Stream/add-on selection stays on `AddonClient.streams(...)` and is unaffected
/// by the metadata mode: streams are a separate concern from metadata.
///
/// In `.builtin` mode every call routes to exactly the clients that were used directly before this
/// layer existed, so behavior is unchanged. In `.aiometadata` mode the calls go through
/// `AIOMetadataClient`, which currently reports "not configured": every capability then falls back
/// to the built-in chain (and caches negative results per run), so no request storms happen while
/// the API integration is pending. See `AIOMetadataClient` for the exact plug-in points.
///
/// Lightweight by design: no timers, no polling, no background refresh. The @Observable surface
/// exposes only the mode and the active add-on list, so SwiftUI views re-render solely when one of
/// those two values actually changes.
@MainActor @Observable
final class MetadataService {
    static let shared = MetadataService()

    private static let modeKey = "metadata.source"

    /// Current metadata backend. Writing persists immediately; nothing else recomputes.
    var mode: MetadataSourceMode {
        didSet {
            guard mode != oldValue else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
        }
    }

    /// Enabled add-ons in priority order — mirrors `AddonStore.activeAddons`. Catalog/search code
    /// reads this through the facade so it never has to know how enable/disable state is stored.
    /// Kept as a plain copy (updated on store revisions) to avoid derived-observable overhead.
    private(set) var activeAddons: [Addon] = []

    private init() {
        mode = MetadataSourceMode(rawValue: UserDefaults.standard.string(forKey: Self.modeKey) ?? "") ?? .builtin
    }

    // MARK: Wiring (called from AddonStore after any order/enable change)

    /// Publishes the add-on priority list to everyone consuming metadata through the facade.
    func setActiveAddons(_ addons: [Addon]) {
        let ids = addons.map(\.id)
        guard ids != activeAddons.map(\.id) else { return }   // no spurious redraws on no-op updates
        activeAddons = addons
    }

    // MARK: Mode helpers

    /// Whether the AIOMetadata backend should be consulted at all right now.
    /// False until the integration is implemented, so `.aiometadata` mode behaves exactly like
    /// `.builtin` (plus cached misses) instead of failing requests one by one.
    var aioActive: Bool {
        guard mode == .aiometadata else { return false }
        // Same UserDefaults key AIOMetadataClient reads/writes — no actor hop, no duplication.
        return (UserDefaults.standard.string(forKey: AIOMetadataClient.baseURLKey) ?? "").isEmpty == false
    }

    /// Re-reads persisted settings after a backup import.
    func reload() {
        mode = MetadataSourceMode(rawValue: UserDefaults.standard.string(forKey: Self.modeKey) ?? "") ?? .builtin
    }

    // MARK: Title details (movies/shows)

    /// Full detail payload for a title (overview, genres, cast, seasons, ...).
    /// AIOMetadata answers first when live; every field it lacks is filled from the built-in chain
    /// (TMDB → TVDB), and populated values are never overwritten by nil/empty ones.
    func details(for item: MetaPreview) async -> TMDBClient.Details? {
        if aioActive {
            let aio = try? await AIOMetadataClient.shared.details(id: item.id, type: item.type)
            let builtin = try? await TMDBClient.shared.details(for: item.id, type: item.type)
            if let a = aio { return merge(primary: a, fill: builtin) }
            return builtin
        }
        return try? await TMDBClient.shared.details(for: item.id, type: item.type)
    }

    /// Field-level merge with `primary` winning; `fill` only supplies nil/empty gaps.
    private func merge(primary p: TMDBClient.Details, fill f: TMDBClient.Details?) -> TMDBClient.Details {
        guard let f else { return p }
        func ok(_ s: String?) -> String? { (s?.isEmpty == false) ? s : nil }
        return TMDBClient.Details(
            overview: ok(p.overview) ?? f.overview, tagline: ok(p.tagline) ?? f.tagline,
            runtime: p.runtime ?? f.runtime, episodeRunTime: p.episodeRunTime ?? f.episodeRunTime,
            voteAverage: p.voteAverage ?? f.voteAverage,
            genres: (p.genres?.isEmpty == false) ? p.genres : f.genres,
            numberOfSeasons: p.numberOfSeasons ?? f.numberOfSeasons,
            numberOfEpisodes: p.numberOfEpisodes ?? f.numberOfEpisodes,
            credits: (p.credits?.cast?.isEmpty == false || p.credits?.crew?.isEmpty == false) ? p.credits : f.credits,
            seasons: (p.seasons?.isEmpty == false) ? p.seasons : f.seasons,
            networks: (p.networks?.isEmpty == false) ? p.networks : f.networks,
            status: ok(p.status) ?? f.status,
            productionCompanies: (p.productionCompanies?.isEmpty == false) ? p.productionCompanies : f.productionCompanies,
            productionCountries: (p.productionCountries?.isEmpty == false) ? p.productionCountries : f.productionCountries,
            spokenLanguages: (p.spokenLanguages?.isEmpty == false) ? p.spokenLanguages : f.spokenLanguages,
            createdBy: (p.createdBy?.isEmpty == false) ? p.createdBy : f.createdBy,
            firstAirDate: p.firstAirDate ?? f.firstAirDate, lastAirDate: p.lastAirDate ?? f.lastAirDate,
            releaseDate: p.releaseDate ?? f.releaseDate, budget: p.budget ?? f.budget, revenue: p.revenue ?? f.revenue)
    }

    /// Details without credits — for lightweight consumers such as profile statistics.
    /// Deliberately TMDB-only (as before this layer existed): routing through `details(for:)`
    /// would fetch a full credits payload that these callers never read, and AIOMetadata's
    /// answer wouldn't be lighter anyway. No extra request is introduced either way.
    func basicDetails(for item: MetaPreview) async -> TMDBClient.Details? {
        await TMDBClient.shared.basicDetails(for: item.id, type: item.type)
    }

    /// Cached variant for quick actions (long-press menus); never blocks on a fresh network call twice.
    func cachedDetails(for item: MetaPreview) async -> TMDBClient.Details? {
        await TMDBClient.shared.cachedDetails(for: item.id, type: item.type)
    }

    // MARK: Suggestions & browsing

    /// "More like this". AIOMetadata first when live, falling back to TMDB recommendations/similar.
    func recommendations(for item: MetaPreview) async -> [MetaPreview] {
        if aioActive, let aio = try? await AIOMetadataClient.shared.recommendations(id: item.id, type: item.type),
           !aio.isEmpty { return aio }
        return (try? await TMDBClient.shared.recommendations(for: item.id, type: item.type)) ?? []
    }

    /// Trending list; `kind` is TMDB's vocabulary ("movie" | "tv").
    func trending(kind: String, page: Int = 1) async -> [MetaPreview] {
        if aioActive, let aio = try? await AIOMetadataClient.shared.trending(kind: kind, page: page),
           !aio.isEmpty { return aio }
        return (try? await TMDBClient.shared.trending(kind, page: page)) ?? []
    }

    /// Filtered browsing for Explore.
    func discover(kind: String, genre: Int?, year: Int?, sort: DiscoverSort, page: Int) async -> [MetaPreview] {
        if aioActive, let aio = try? await AIOMetadataClient.shared.discover(kind: kind, genre: genre, year: year, sort: sort, page: page),
           !aio.isEmpty { return aio }
        return (try? await TMDBClient.shared.discover(kind: kind, genre: genre, year: year, sort: sort, page: page)) ?? []
    }

    /// Whether a grid/paging screen may load content at all: the built-in chain needs a TMDB key;
    /// in AIOMetadata mode a configured endpoint is enough (its trending/discover calls fall back
    /// to TMDB when they can't answer, and every miss is cached per run — no retry storms).
    /// Pure UserDefaults/enum reads — no actor hop, safe to call from view guards.
    var browseAvailable: Bool {
        TMDBClient.shared.hasKey || aioActive
    }

    func genres(kind: String) async -> [TMDBClient.Genre] {
        await TMDBClient.shared.genres(kind)
    }

    /// Season list for a show ("Seasons" section on Detail). Deterministic priority:
    /// AIOMetadata's season-details service (when live) → TMDB. Nil/empty answers fall through —
    /// never the other way round. The TMDB hop uses the credits-free variant, so no full payload
    /// is fetched just for season headers; both sources are per-run cached by their clients.
    func seasons(for item: MetaPreview, imdb: String?) async -> [TMDBClient.SeasonInfo]? {
        if aioActive, let i = imdb, let s = await AIOMetadataClient.shared.seasonDetails(imdb: i), !s.isEmpty {
            return s
        }
        return await TMDBClient.shared.basicDetails(for: item.id, type: item.type)?.seasons
    }

    /// Whether the "Seasons" section should ask this facade instead of reading `details?.seasons`
    /// directly: only when AIOMetadata can actually answer (mode selected + endpoint configured).
    /// Pure UserDefaults/enum reads — safe to call from view code without an actor hop.
    var aioSeasonSourceAvailable: Bool { aioActive }

    /// Keyword-tagged themed rows (Home). Built-in only for now; AIOMetadata will expose an equivalent.
    func themed(keywords: [String], limit: Int = 8) async -> [ThemedTitle] {
        await TMDBClient.shared.themed(keywords: keywords, limit: limit)
    }

    // MARK: Search (metadata side)

    /// Free-text title search. Add-on hits (IMDb ids) are merged ahead of the provider hits
    /// (deduplicated by name+year, borrowing ratings), exactly as the old SearchModel did —
    /// the facade just owns *which* provider answers.
    func search(query: String) async -> [MetaPreview] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return [] }
        if aioActive, let aio = try? await AIOMetadataClient.shared.search(query: q), !aio.isEmpty { return aio }
        // Cinemeta takeover: when no enabled add-on declares a searchable meta catalog (the usual
        // case being the user disabled/removed Cinemeta) and AIOMetadata can answer searches, it
        // steps into that role automatically — no manual reconfiguration. Checked per query; the
        // manifest lookup behind it is cached, so repeat keystrokes don't refetch.
        if mode != .aiometadata, AIOMetadataClient.shared.isConfigured,
           !(await addonSearchAvailable()),
           let aio = try? await AIOMetadataClient.shared.search(query: q), !aio.isEmpty { return aio }
        return await TMDBClient.shared.search(q)
    }

    /// Whether any *enabled* add-on in the priority list offers a searchable meta catalog
    /// (Cinemeta's job). Uses the published copy only — no network, no store round-trip.
    private func addonSearchAvailable() async -> Bool {
        activeAddons.contains { a in
            (a.manifest.catalogs ?? []).contains(where: \.isSearchable) ||
            (a.manifest.resources ?? []).contains { $0.name == "search" }
        }
    }

    // MARK: Catalog takeover (disabled Cinemeta)

    /// Home rows for one type from the enabled add-ons in priority order. When no enabled add-on
    /// declares browsable catalogs of this type — the usual case being the user disabled or removed
    /// Cinemeta — and AIOMetadata is configured and can answer, it takes over that role with its
    /// own catalogs automatically; nothing else in the app has to be reconfigured. Deterministic:
    /// add-on rows first (user priority), takeover rows appended only when there are none.
    func homeRows(type: String, limit: Int = 4) async -> [CatalogRow] {
        var jobs: [(Addon, AddonManifest.CatalogDef)] = []
        for a in activeAddons.prefix(limit) {
            for c in a.homeCatalogs where c.type == type { jobs.append((a, c)) }
            if !jobs.isEmpty { break }   // highest-priority add-on that answers wins (stable ordering)
        }
        if jobs.isEmpty {
            if await AIOMetadataClient.shared.canReplaceCinemeta(for: type) {
                return await AIOMetadataClient.shared.homeRows(type: type, limit: limit)
            }
            return []
        }
        var out: [CatalogRow] = []
        var seen = Set<String>()
        for (addon, cat) in jobs.prefix(limit) {
            let items = await catalog(addon: addon, catalog: cat)
            let fresh = items.filter { seen.insert($0.id).inserted }
            guard !fresh.isEmpty else { continue }
            let kind = type == "movie" ? "Movies" : "Series"
            out.append(CatalogRow(id: "aioless/\(addon.id)/\(cat.type)/\(cat.id)",
                                  title: "\(cat.name ?? cat.id) \(kind)",
                                  items: fresh, source: .addon(addon, cat), symbol: "film.stack"))
        }
        return out
    }

    // MARK: Catalogs (Stremio add-ons)

    /// One catalog page from one add-on. HTTP caching (ETag/Cache-Control) still happens inside
    /// `AddonClient`, so repeat launches don't refetch what the add-on says is fresh.
    func catalog(addon: Addon, catalog: AddonManifest.CatalogDef, skip: Int = 0, search query: String? = nil) async -> [MetaPreview] {
        (try? await AddonClient.shared.catalog(addon: addon, catalog: catalog, skip: skip, search: query)) ?? []
    }

    // MARK: Episodes

    /// Episode list for a season. Deterministic priority: AIOMetadata (when live) → TMDB → TVDB.
    /// Missing fields are filled from the built-in chain without ever overwriting populated values;
    /// season/episode numbering and ids stay intact for stream matching (`{imdb}:{s}:{e}`).
    func episodes(for item: MetaPreview, season: Int) async -> [EpisodeItem] {
        if aioActive {
            let aio = await AIOMetadataClient.shared.episodes(id: item.id, type: item.type, season: season)
            if let aio, !aio.isEmpty { return await fillEpisodes(aio, item: item, season: season) }
            // nil / empty answer: fall through to the built-in chain below.
        }
        return await EpisodeLoader.load(itemID: item.id, type: item.type, season: season) {
            await self.stremioID(for: item)
        }
    }

    /// Gap-filling only: images/runtimes/overviews/air dates taken from TMDB then TVDB when the
    /// primary list is missing them. All three lookups are per-run cached by their clients, so this
    /// costs no extra requests on repeat visits.
    private func fillEpisodes(_ eps: [EpisodeItem], item: MetaPreview, season: Int) async -> [EpisodeItem] {
        var out = eps
        let needsArt = out.contains { $0.image == nil || $0.overview == nil || $0.runtime == nil }
        guard needsArt else { return out }
        let tmdb = await TMDBClient.shared.episodes(for: item.id, type: item.type, season: season)
        for i in out.indices {
            guard let t = tmdb.first(where: { $0.episodeNumber == out[i].id }) else { continue }
            if out[i].image == nil { out[i].image = t.stillURL }
            if out[i].overview == nil { out[i].overview = t.overview }
            if out[i].runtime == nil { out[i].runtime = t.runtime }
            if out[i].airDate == nil { out[i].airDate = t.airDate }
            if out[i].rating == nil { out[i].rating = t.voteAverage }
        }
        if out.contains(where: { $0.image == nil }), TVDBClient.shared.hasKey,
           let imdb = await stremioID(for: item), imdb.hasPrefix("tt") {
            let tvdb = await TVDBClient.shared.episodes(imdb: imdb, season: season)
            for i in out.indices where out[i].image == nil {
                out[i].image = tvdb.first(where: { $0.number == out[i].id })?.imageURL
            }
        }
        return out
    }

    // MARK: Artwork

    func logo(for item: MetaPreview) async -> URL? {
        if aioActive, let u = await AIOMetadataClient.shared.logo(id: item.id, type: item.type) { return u }
        return await LogoResolver.shared.logo(for: item)
    }

    func trailerVideos(for item: MetaPreview) async -> [TMDBClient.Video] {
        if aioActive, let v = await AIOMetadataClient.shared.videos(id: item.id, type: item.type), !v.isEmpty { return v }
        return await TMDBClient.shared.videos(for: item.id, type: item.type)
    }

    func networkBadge(for item: MetaPreview) async -> TMDBClient.NetworkBadge? {
        await TMDBClient.shared.network(for: item.id, type: item.type)
    }

    // MARK: Ratings

    /// Aggregated critic/audience ratings (MDBList today; AIOMetadata may serve these later).
    func ratings(for item: MetaPreview, imdb: String) async -> [MDBListClient.Rating] {
        await MDBListClient.shared.ratings(imdb: imdb, type: item.type)
    }

    func mdbUserLists() async -> [MDBListClient.UserList] {
        await MDBListClient.shared.userLists()
    }

    func mdbListItems(listID: Int) async -> [MetaPreview] {
        await MDBListClient.shared.items(listID: listID)
    }

    // MARK: ID resolution (cross-service matching)

    /// Stremio/IMDb id for a title: TMDB-sourced items are mapped to their IMDb id. Single source of
    /// truth for the mapping `SourceResolver` used to own; stream code keeps calling it unchanged.
    func stremioID(for item: MetaPreview) async -> String? {
        if aioActive, let id = await AIOMetadataClient.shared.resolveStremioID(id: item.id, type: item.type) { return id }
        if item.id.hasPrefix("tmdb:"), let n = Int(item.id.dropFirst(5)) {
            return await TMDBClient.shared.imdbID(tmdb: n, type: item.type)
        }
        return item.id
    }

    /// Numeric TMDB id for any title id we hold ("tt…" or "tmdb:…"); needed by IntroDB matching.
    func tmdbIdentifier(for item: MetaPreview) async -> Int? {
        await TMDBClient.shared.tmdbIdentifier(for: item.id, type: item.type)
    }
}
