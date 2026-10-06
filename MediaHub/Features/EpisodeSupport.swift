import Foundation

struct EpisodeItem: Identifiable {
    let id: Int          // episode number
    var name: String
    var overview: String?
    var image: URL?
    var rating: Double?
    var runtime: Int?
    var airDate: String?        // yyyy-MM-dd, when known
}

struct NextEpisode {
    let season: Int
    let episode: EpisodeItem
}

struct SeasonOption: Identifiable, Hashable {
    let id: Int          // season number
    let title: String
}

/// What the player needs to browse and switch episodes without going back to the detail page.
/// Built by DetailView, which owns the add-ons, pins and metadata clients.
struct EpisodeProvider {
    var seasons: [SeasonOption]
    var episodes: @MainActor (Int) async -> [EpisodeItem]
    /// Finds a playable source for the episode and returns a ready-to-play request, or nil if none exists.
    var resolve: @MainActor (Int, EpisodeItem, PlayRequest) async -> PlayRequest?
    /// The episode after the one in `PlayRequest`, if there is one that has aired.
    var next: @MainActor (PlayRequest) async -> NextEpisode?
}

enum EpisodeLoader {
    /// TMDB first (stills, overviews, ratings); TVDB fills missing thumbnails or stands in when TMDB has nothing.
    static func load(itemID: String, type: String, season: Int,
                     imdb resolveIMDB: () async -> String?) async -> [EpisodeItem] {
        var list = await TMDBClient.shared.episodes(for: itemID, type: type, season: season).map {
            EpisodeItem(id: $0.episodeNumber, name: $0.name ?? "Episode \($0.episodeNumber)", overview: $0.overview,
                        image: $0.stillURL, rating: $0.voteAverage, runtime: $0.runtime, airDate: $0.airDate)
        }
        let needsArt = list.contains(where: { $0.image == nil })
        if (list.isEmpty || needsArt), TVDBClient.shared.hasKey, let imdb = await resolveIMDB() {
            let tv = await TVDBClient.shared.episodes(imdb: imdb, season: season)
            if list.isEmpty {
                list = tv.compactMap { e in
                    e.number.map { EpisodeItem(id: $0, name: e.name ?? "Episode \($0)", overview: e.overview,
                                               image: e.imageURL, rating: nil, runtime: e.runtime) }
                }
            } else {
                for i in list.indices where list[i].image == nil {
                    list[i].image = tv.first(where: { $0.number == list[i].id })?.imageURL
                }
            }
        }
        return list
    }
}

enum SourceResolver {
    /// Stremio id for a title: TMDB-sourced items are mapped to their IMDb id.
    static func stremioID(for item: MetaPreview) async -> String? {
        if item.id.hasPrefix("tmdb:"), let n = Int(item.id.dropFirst(5)) {
            return await TMDBClient.shared.imdbID(tmdb: n, type: item.type)
        }
        return item.id
    }

    /// Picks the stream for another episode, preferring (1) the add-on and release name that is playing now,
    /// (2) the pinned source, (3) the first playable stream from any add-on.
    @MainActor
    static func request(season: Int, episode: EpisodeItem, current: PlayRequest,
                        addons: [Addon], pins: PinnedSources) async -> PlayRequest? {
        let groups = await AddonClient.shared.streams(for: "\(current.imdb):\(season):\(episode.id)",
                                                      type: "series", addons: addons)
        // Task-group results arrive in completion order; keep the user's add-on order.
        let ordered = addons.compactMap { a in groups.first(where: { $0.0.id == a.id }) }

        func match(_ addonID: String, _ signature: String?) -> (Addon, StreamItem)? {
            guard let g = ordered.first(where: { $0.0.id == addonID }) else { return nil }
            let playable = g.1.filter(\.isPlayable)
            guard let s = playable.first(where: { $0.signature == signature }) ?? playable.first else { return nil }
            return (g.0, s)
        }

        // The source you are watching now wins (so "next episode" keeps your quality / provider), then the pin.
        var chosen: (Addon, StreamItem)?
        if let a = current.sourceAddonID { chosen = match(a, current.sourceSignature) }
        if chosen == nil, let pin = pins.pin(for: current.imdb) { chosen = match(pin.addonID, pin.signature) }
        if chosen == nil {
            for g in ordered { if let s = g.1.first(where: \.isPlayable) { chosen = (g.0, s); break } }
        }
        guard let (addon, stream) = chosen, let url = stream.url.flatMap(URL.init(string:)) else { return nil }

        return PlayRequest(url: url, headers: stream.requestHeaders, item: current.item,
                           key: "\(season):\(episode.id)", imdb: current.imdb,
                           season: season, episode: episode.id, episodeTitle: episode.name,
                           logo: current.logo, thumb: episode.image ?? current.item.backdropURL,
                           sourceAddonID: addon.id, sourceSignature: stream.signature)
    }
}
