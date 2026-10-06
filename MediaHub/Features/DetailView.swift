import SwiftUI
import SafariServices

private struct SeasonChip: Identifiable {
    let id: Int          // season number
    let title: String
    let poster: URL?
    let count: Int?
}

struct DetailView: View {
    let item: MetaPreview
    private let explicitStart: Bool

    /// `startSeason`/`startEpisode`: open with that episode selected (Continue Watching).
    init(item: MetaPreview, startSeason: Int? = nil, startEpisode: Int? = nil) {
        self.item = item
        explicitStart = startSeason != nil
        _season = State(initialValue: startSeason ?? 1)
        _episode = State(initialValue: startEpisode ?? 1)
    }
    @Environment(AddonStore.self) private var store
    @Environment(SimklStore.self) private var simkl
    @Environment(LibraryPrefs.self) private var prefs
    @Environment(PinnedSources.self) private var pins
    @Environment(WatchHistory.self) private var history
    @Environment(LocalLibrary.self) private var library
    @Environment(ThemeStore.self) private var theme
    @State private var imdbID: String?
    @State private var onWatchlist = false
    @State private var ratings: [MDBListClient.Rating] = []
    @State private var logoURL: URL?
    @State private var details: TMDBClient.Details?
    @State private var similar: [MetaPreview] = []
    @State private var streams: [(Addon, [StreamItem])] = []
    @State private var loadingStreams = false
    @State private var showSources = false
    @State private var playRequest: PlayRequest?
    @State private var upNext: UpNextItem?
    @State private var userPicked = false
    @State private var pendingPlay: PlayRequest?
    @State private var season = 1
    @State private var episode = 1
    @State private var episodes: [EpisodeItem] = []
    @State private var loadingEpisodes = false
    @State private var seasonsExpanded = false
    /// Season headers from the unified metadata layer (AIOMetadata season service when live, else
    /// nil and `details?.seasons` is used). Only ever populated in AIOMetadata mode.
    @State private var facadeSeasons: [TMDBClient.SeasonInfo]?
    @State private var trailers: [TMDBClient.Video] = []
    @State private var openTrailer: TMDBClient.Video?

    private var isSeries: Bool { item.type == "series" }

    // MARK: Derived data

    private var metaLine: String {
        var parts: [String] = []
        if let y = item.releaseInfo { parts.append(y) }
        if let m = details?.minutes { parts.append("\(m) min") }
        if let g = details?.genres?.prefix(2).map(\.name), !g.isEmpty { parts.append(g.joined(separator: ", ")) }
        return parts.joined(separator: "  ")
    }

    /// TV: broadcaster/streamer. Movies: production studio.
    private var networkText: String? {
        let list = (isSeries ? details?.networks : details?.productionCompanies) ?? []
        let names = list.prefix(2).map(\.name)
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    private var allRatings: [MDBListClient.Rating] {
        var out = ratings
        if let r = details?.voteAverage, r > 0, !out.contains(where: { $0.label == "TMDB" }) {
            out.append(MDBListClient.Rating(label: "TMDB", text: String(format: "%.1f", r), score: r))
        }
        return out
    }

    private var seasonChips: [SeasonChip] {
        if let s = facadeSeasons ?? details?.seasons, !s.isEmpty {
            return s.filter { ($0.episodeCount ?? 1) > 0 }
                .sorted { ($0.seasonNumber == 0 ? Int.max : $0.seasonNumber) < ($1.seasonNumber == 0 ? Int.max : $1.seasonNumber) }
                .map { SeasonChip(id: $0.seasonNumber, title: $0.name ?? "Season \($0.seasonNumber)", poster: seasonPoster($0), count: $0.episodeCount) }
        }
        return (1...max(details?.numberOfSeasons ?? 1, 1)).map {
            SeasonChip(id: $0, title: "Season \($0)", poster: nil, count: nil)
        }
    }

    /// TMDB's `SeasonInfo` carries only `posterPath`; the artwork URL is built here so the facade
    /// season list and the merged-details list render identically.
    private func seasonPoster(_ s: TMDBClient.SeasonInfo) -> URL? {
        guard let p = s.posterPath else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/" + "w185" + p)
    }

    /// Season headers from the unified layer when AIOMetadata is live, else the (merged) TMDB ones.
    private var seasonList: [TMDBClient.SeasonInfo]? { facadeSeasons ?? details?.seasons }

    /// Episode count of a season, preferring the loaded episode list for the open season.
    private func seasonTotal(_ s: Int, loaded: Int) -> Int? {
        if s == season && loaded > 0 { return loaded }
        return seasonList?.first(where: { $0.seasonNumber == s })?.episodeCount
    }

    // MARK: Reactive metadata-source key

    /// Changes whenever the metadata mode or the AIOMetadata endpoint changes. Used as a `.task(id:)`
    /// value so switching sources in Settings reloads details/seasons/episodes without pop-and-push.
    /// Pure UserDefaults reads — no polling, no observers; re-evaluated only when the view's state
    /// changes (e.g. right after the picker write) or the body otherwise re-renders.
    private var metaKey: String {
        let m = meta.mode == .aiometadata ? "aio" : "builtin"
        return "\(m)|\(AIOMetadataClient.shared.baseURL)"
    }

    // MARK: Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                RemoteImage(url: item.backdropURL, size: 800)
                    .frame(height: 420)
                    .overlay(alignment: .bottom) {
                        LinearGradient(colors: [.clear, Color(.systemBackground)], startPoint: .top, endPoint: .bottom)
                            .frame(height: 140)
                    }
                header.padding(.horizontal, 20)
                if isSeries { seasonSection }
                if !trailers.isEmpty { trailersSection }
                if !similar.isEmpty {
                    CatalogRowView(row: CatalogRow(id: "similar-\(item.id)", title: "More like this", items: similar))
                        .padding(.top, 8)
                }
                detailsSection
            }
            .padding(.bottom, 40)
        }
        .ignoresSafeArea(edges: .top)
        .toolbarTitleDisplayMode(.inline)
        .sheet(isPresented: $showSources, onDismiss: startPendingPlayback) { sourceSheet }
        // Presented from the page itself (not from inside the sources sheet): the sheet closes first,
        // then the player opens. This keeps dismissing the player reliable.
        .fullScreenCover(item: $playRequest) { r in
            PlayerScreen(request: r, provider: makeProvider(), onClose: { playRequest = nil })
        }
        .task(id: metaKey) {
            // Native metadata + suggestions (no-ops without a TMDB key), via the unified metadata
            // layer. Keyed on the metadata mode/endpoint so switching sources in Settings reloads
            // this view's data instead of keeping answers from the previous provider.
            async let d = meta.details(for: item)
            async let s = meta.recommendations(for: item)
            details = await d
            similar = await s
        }
        .task(id: metaKey) {
            guard MDBListClient.shared.hasKey, let imdb = await stremioID() else { return }
            imdbID = imdb
            ratings = await meta.ratings(for: item, imdb: imdb)
        }
        .task(id: metaKey) { logoURL = await meta.logo(for: item) }
        .task(id: metaKey) { trailers = await meta.trailerVideos(for: item) }
        .task(id: "season|\(isSeries ? item.id : "")|\(metaKey)") {
            // Season headers through the unified layer, but only when AIOMetadata can actually
            // answer (mode selected + endpoint configured). In builtin mode `details?.seasons`
            // already carries TMDB's list — fetching here would duplicate that request.
            guard isSeries, meta.aioSeasonSourceAvailable else { return }
            let imdb = item.id.hasPrefix("tt") ? item.id : await stremioID()
            let s = await meta.seasons(for: item, imdb: imdb)
            guard !Task.isCancelled else { return }
            facadeSeasons = s
        }

        .task { await configureFromHistory() }
        .task(id: "eps|\(season)|\(metaKey)") { await loadEpisodes() }
        .task(id: showSources) {
            // Query stream add-ons only when the picker opens. Stream selection is deliberately
            // independent of the metadata-source mode: it always uses the active addon list.
            guard showSources else { return }
            streams = []
            loadingStreams = true; defer { loadingStreams = false }
            guard let imdb = await stremioID() else { return }
            imdbID = imdb
            let sid = isSeries ? "\(imdb):\(season):\(episode)" : imdb
            streams = await AddonClient.shared.streams(for: sid, type: item.type, addons: store.activeAddons)
        }
    }

    /// Unified metadata facade (provider selection, fallbacks and merging live there).
    private var meta: MetadataService { .shared }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            TitleArt(item: item, maxWidth: 280, maxHeight: 100, font: .largeTitle.bold())
            if let t = details?.tagline, !t.isEmpty { Text(t).italic().foregroundStyle(.secondary) }
            if let d = descriptionText { ExpandableText(text: d) }
            if !metaLine.isEmpty || networkText != nil { metaRow }
            if !allRatings.isEmpty { ratingsRow }
            actionBar
        }
    }

    /// Year, runtime and genres, with the network / studio right next to them.
    private var metaRow: some View {
        let icon = isSeries ? "tv" : "building.2"
        let lead = metaLine.isEmpty ? "" : metaLine + "   "
        return Group {
            if let n = networkText { Text("\(lead)\(Image(systemName: icon)) \(n)") } else { Text(metaLine) }
        }
        .font(.subheadline).foregroundStyle(.secondary)
    }

    private var descriptionText: String? {
        [details?.overview, item.description].lazy.compactMap { $0 }.first { !$0.isEmpty }
    }

    // MARK: Action bar (play + small round buttons)

    /// Play button with compact round actions next to it: library toggle and watched toggle.
    private var actionBar: some View {
        HStack(spacing: 10) {
            Button { showSources = true } label: {
                Label(isSeries ? "Play S\(season):E\(episode)" : "Play", systemImage: "play.fill")
                    .font(.headline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent).controlSize(.large)
            listButton
            watchedButton
        }
    }

    /// Round bookmark button: adds/removes the title from the watchlist (Simkl when connected).
    private var listButton: some View {
        Button {
            if viaSimkl {
                guard !onWatchlist else { return }
                Task {
                    if let imdb = await stremioID() { await simkl.addToWatchlist(imdb, type: item.type); onWatchlist = true }
                }
            } else {
                withAnimation {
                    if inList { library.remove(item.id) } else { saveLocal(.planToWatch) }
                }
            }
        } label: {
            Image(systemName: listSaved ? "bookmark.fill" : "bookmark")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .disabled(viaSimkl && onWatchlist)
        .accessibilityLabel(listSaved ? "Remove from watchlist" : "Add to watchlist")
    }

    /// Round checkmark button: marks the whole title watched, or unmarks it.
    private var watchedButton: some View {
        Button {
            withAnimation {
                if isWatched {
                    TitleActions.unmarkWatched(item, history: history)
                } else {
                    TitleActions.markWatched(item, history: history)
                    if let e = library.entry(for: item.id), e.status != .watched { library.set(e.item, status: .watched) }
                }
            }
        } label: {
            Image(systemName: isWatched ? "checkmark.circle.fill" : "checkmark.circle")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(isWatched ? theme.accent : Color.primary)
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .accessibilityLabel(isWatched ? "Unmark as watched" : "Mark as watched")
    }

    private var isWatched: Bool { history.entry(for: item.id)?.isFinished ?? false }
    private var inList: Bool { library.entry(for: item.id) != nil }
    /// Simkl is this profile's library (connected and chosen); otherwise the list button works on the local library.
    private var viaSimkl: Bool { prefs.usesSimkl(simkl) }
    private var listSaved: Bool { viaSimkl ? onWatchlist : inList }

    /// Saves instantly, then looks up the title's other id in the background so it is recognised from any source.
    private func saveLocal(_ status: LocalLibrary.Status) {
        let isNew = library.entry(for: item.id) == nil
        library.set(item, status: status)
        guard isNew else { return }
        Task {
            if let other = await stremioID(), other != item.id { library.setAlias(other, for: item.id) }
        }
    }

    private var ratingsRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(allRatings) { RatingBadge(rating: $0) }
            }
        }
        .scrollIndicators(.hidden)
    }

    // MARK: Up next / continue

    /// Opens on the episode you should watch: where you stopped, or the one after a finished episode.
    private func configureFromHistory() async {
        guard isSeries, let e = history.entry(for: item.id), let se = e.seasonEpisode else { return }
        if e.isFinished {
            guard let n = await UpNext.resolve(e) else { return }
            upNext = n
            if !explicitStart && !userPicked { season = n.season; episode = n.episode }
        } else if e.position > 30, !explicitStart, !userPicked {
            season = se.season; episode = se.episode
        }
    }

    // MARK: Seasons + episodes

    private var seasonSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Seasons").font(.title3.bold())
                Spacer()
                if seasonChips.contains(where: { $0.poster != nil }) {
                    Button { withAnimation(.snappy) { seasonsExpanded.toggle() } } label: {
                        HStack(spacing: 4) {
                            Text("Artwork")
                            Image(systemName: "chevron.down").rotationEffect(.degrees(seasonsExpanded ? 180 : 0))
                        }
                        .font(.subheadline)
                    }
                }
            }
            .padding(.horizontal, 20)
            seasonPills
            if seasonsExpanded { seasonPosters.transition(.opacity.combined(with: .move(edge: .top))) }
            episodeCarousel
        }
    }

    private func select(season n: Int) {
        guard n != season else { return }
        userPicked = true
        withAnimation(.snappy) { season = n; episode = 1; episodes = [] }
    }

    private var seasonPills: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(seasonChips) { c in
                    Button { select(season: c.id) } label: {
                        Text(c.title).font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16).padding(.vertical, 9)
                            .glassEffect(c.id == season ? .regular.tint(.accentColor).interactive() : .regular.interactive(),
                                         in: .capsule)
                    }
                    .buttonStyle(.plain)
                    // Long tap: mark the whole season as watched (or unmark it).
                    .contextMenu {
                        if isSeasonWatched(c.id) {
                            Button("Unmark Season as Watched", systemImage: "circle") { setSeasonWatched(c.id, false) }
                        } else {
                            Button("Mark Season as Watched", systemImage: "checkmark.circle") { setSeasonWatched(c.id, true) }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollIndicators(.hidden)
    }

    /// The show's watched marker sits on its last-watched episode; a season counts when that episode is inside it.
    private func seasonProgress(_ s: Int) -> (watchedEpisodes: Int, total: Int)? {
        guard let en = history.entry(for: item.id), en.isFinished, let se = en.seasonEpisode else { return nil }
        let total = seasonTotal(s, loaded: episodes.count)
        guard let total, total > 0 else { return nil }
        if se.season < s { return (total, total) }
        guard se.season == s else { return nil }
        return (min(se.episode, total), total)
    }

    private func isSeasonWatched(_ s: Int) -> Bool {
        guard let p = seasonProgress(s) else { return false }
        return p.watchedEpisodes >= p.total
    }

    private func setSeasonWatched(_ s: Int, _ watched: Bool) {
        withAnimation {
            if watched {
                let count = seasonTotal(s, loaded: episodes.count) ?? 10
                TitleActions.markWatched(item, history: history, season: s, episode: count)
            } else if isSeasonWatched(s), let en = history.entry(for: item.id), let se = en.seasonEpisode {
                // Pull the marker back to the last episode of the previous season.
                let prevSeason = max(se.season - 1, 1)
                let prevCount = seasonList?.first(where: { $0.seasonNumber == prevSeason })?.episodeCount ?? 10
                history.markWatched(item, key: "\(prevSeason):\(prevCount)", season: prevSeason, episode: prevCount,
                                    duration: en.duration)
            } else {
                history.unmarkWatched(item.id)
            }
        }
    }

    private var seasonPosters: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(seasonChips) { c in
                    Button { select(season: c.id) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            RemoteImage(url: c.poster, size: 56).frame(width: 56, height: 84)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(alignment: .topLeading) {
                                    if isSeasonWatched(c.id) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundStyle(.white, theme.accent).padding(3)
                                    }
                                }
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(Color.accentColor, lineWidth: c.id == season ? 2 : 0)
                                }
                            Text(c.title).font(.caption.weight(.medium)).lineLimit(1)
                            if let n = c.count { Text("\(n) episodes").font(.caption2).foregroundStyle(.secondary) }
                        }
                        .frame(width: 84, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    // Long tap: mark the whole season as watched (or unmark it).
                    .contextMenu {
                        if isSeasonWatched(c.id) {
                            Button("Unmark Season as Watched", systemImage: "circle") { setSeasonWatched(c.id, false) }
                        } else {
                            Button("Mark Season as Watched", systemImage: "checkmark.circle") { setSeasonWatched(c.id, true) }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollIndicators(.hidden)
    }

    private var episodeCarousel: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 12) {
                        if loadingEpisodes && episodes.isEmpty {
                            ProgressView().frame(width: EpisodeCard<EmptyView>.width, height: EpisodeCard<EmptyView>.height)
                        }
                        ForEach(episodes) { episodeCard($0).id($0.id) }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, 20, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
                .scrollIndicators(.hidden)
                .onChange(of: episodes.count) { _, _ in
                    if episode > 1 { proxy.scrollTo(episode, anchor: .center) }
                }
            }
            // No TMDB/TVDB data: keep a manual way to pick the episode.
            if episodes.isEmpty && !loadingEpisodes {
                Stepper("Episode \(episode)", value: $episode, in: 1...99).padding(.horizontal, 20)
            }
        }
    }

    private func episodeCard(_ ep: EpisodeItem) -> some View {
        let watched = history.isWatched(id: item.id, season: season, episode: ep.id)
        return EpisodeCard(ep: ep, selected: ep.id == episode,
                    watched: watched,
                    upNext: !watched && upNext?.season == season && upNext?.episode == ep.id,
                    onTap: { userPicked = true; episode = ep.id; showSources = true }) {
            // Same actions in the long-press menu and the card's "..." button.
            Button("Mark as Watched", systemImage: "checkmark.circle") {
                withAnimation {
                    history.markWatched(item, key: "\(season):\(ep.id)", season: season, episode: ep.id,
                                        duration: Double(ep.runtime ?? 45) * 60,
                                        episodeTitle: ep.name, thumb: ep.image?.absoluteString)
                }
            }
            Button("Mark Episodes Until Here as Watched", systemImage: "checkmark.circle.fill") {
                withAnimation {
                    history.markThrough(episode: ep.id, season: season, item: item,
                                        duration: Double(ep.runtime ?? 45) * 60,
                                        episodeTitle: ep.name, thumb: ep.image?.absoluteString)
                }
            }
            Button("Unmark as Watched", systemImage: "circle", role: .destructive) {
                withAnimation {
                    history.unmarkThrough(episode: ep.id, season: season, item: item)
                }
            }
        }
    }

    private func loadEpisodes() async {
        guard isSeries else { return }
        loadingEpisodes = true
        let list = await meta.episodes(for: item, season: season)
        guard !Task.isCancelled else { return }
        episodes = list
        loadingEpisodes = false
    }

    // MARK: Trailers

    private var trailersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Trailers & Extras").font(.title3.bold()).padding(.horizontal, 20)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(trailers) { v in TrailerCard(video: v) { openTrailer = v } }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, 20, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
        }
        .fullScreenCover(item: $openTrailer) { v in
            if let u = v.watchURL { SafariView(url: u).ignoresSafeArea() }
        }
    }

    // MARK: Details footer

    private var detailRows: [(String, String)] {
        guard let d = details else { return [] }
        var rows: [(String, String)] = []
        func add(_ k: String, _ v: String?) { if let v, !v.isEmpty { rows.append((k, v)) } }
        func names(_ a: [TMDBClient.Details.Named]?) -> String? { a?.map(\.name).joined(separator: ", ") }
        func money(_ n: Int?) -> String? {
            guard let n, n > 0 else { return nil }
            return n.formatted(.currency(code: "USD").precision(.fractionLength(0)))
        }
        if isSeries {
            add("Network", names(d.networks))
            add("Status", d.status)
            add("First aired", prettyDate(d.firstAirDate))
            add("Last aired", prettyDate(d.lastAirDate))
            add("Seasons", d.numberOfSeasons.map(String.init))
            add("Episodes", d.numberOfEpisodes.map(String.init))
            add("Created by", names(d.createdBy))
        } else {
            add("Released", prettyDate(d.releaseDate))
            add("Director", d.credits?.crew?.filter { $0.job == "Director" }.map(\.name).joined(separator: ", "))
            add("Budget", money(d.budget))
            add("Box office", money(d.revenue))
        }
        add("Runtime", d.minutes.map { "\($0) min" })
        add("Genres", names(d.genres))
        add("Studio", names(d.productionCompanies))
        add("Country", names(d.productionCountries))
        add("Languages", d.spokenLanguages?.compactMap(\.englishName).joined(separator: ", "))
        add("Cast", d.credits?.cast?.prefix(10).map(\.name).joined(separator: ", "))
        return rows
    }

    private static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func prettyDate(_ s: String?) -> String? {
        guard let s else { return nil }
        return Self.isoDay.date(from: s)?.formatted(date: .long, time: .omitted)
    }

    @ViewBuilder private var detailsSection: some View {
        let rows = detailRows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text(isSeries ? "About the show" : "About the movie").font(.title3.bold()).padding(.bottom, 8)
                ForEach(rows, id: \.0) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.0).font(.caption).foregroundStyle(.secondary)
                        Text(row.1).font(.subheadline)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                    Divider()
                }
            }
            .padding(.horizontal, 20).padding(.top, 8)
        }
    }

    // MARK: IDs

    /// Stremio/IMDb id for this title, through the unified layer (id resolution + caching live there).
    private func stremioID() async -> String? { await meta.stremioID(for: item) }

    // MARK: Sources + pinning

    /// The pinned stream for this show: exact add-on + name match, else that add-on's first playable stream.
    private var pinned: (addon: Addon, stream: StreamItem)? {
        guard let imdb = imdbID, let pin = pins.pin(for: imdb),
              let group = streams.first(where: { $0.0.id == pin.addonID }) else { return nil }
        let playable = group.1.filter(\.isPlayable)
        guard let s = playable.first(where: { $0.signature == pin.signature }) ?? playable.first else { return nil }
        return (group.0, s)
    }

    private func play(_ addon: Addon, _ s: StreamItem) {
        guard let u = s.url.flatMap(URL.init(string:)), let imdb = imdbID else { return }
        let ep = isSeries ? episodes.first(where: { $0.id == episode }) : nil
        pendingPlay = PlayRequest(url: u, headers: s.requestHeaders, item: item,
                                  key: isSeries ? "\(season):\(episode)" : "movie", imdb: imdb,
                                  season: isSeries ? season : nil, episode: isSeries ? episode : nil,
                                  episodeTitle: ep?.name, logo: logoURL,
                                  thumb: ep?.image ?? item.backdropURL,
                                  sourceAddonID: addon.id, sourceSignature: s.signature)
        showSources = false
    }

    /// Runs once the sources sheet has fully closed.
    private func startPendingPlayback() {
        guard let p = pendingPlay else { return }
        pendingPlay = nil
        Task {
            try? await Task.sleep(for: .milliseconds(80))
            playRequest = p
        }
    }

    /// Lets the player browse episodes and jump to another one using the same add-ons and pins.
    /// Metadata (episode lists) goes through the unified layer; stream resolution stays addon-based.
    private func makeProvider() -> EpisodeProvider? {
        guard isSeries else { return nil }
        let item = item, addons = store.activeAddons, pins = pins
        let options = seasonChips.map { SeasonOption(id: $0.id, title: $0.title) }
        return EpisodeProvider(
            seasons: options,
            episodes: { s in
                await MetadataService.shared.episodes(for: item, season: s)
            },
            resolve: { s, ep, current in
                await SourceResolver.request(season: s, episode: ep, current: current, addons: addons, pins: pins)
            },
            next: { current in
                guard let s = current.season, let e = current.episode,
                      let n = await UpNext.next(for: item, after: s, e) else { return nil }
                return NextEpisode(season: n.season, episode: n.episode)
            })
    }

    private func row(_ addon: Addon, _ s: StreamItem, isPinned: Bool) -> some View {
        Button { play(addon, s) } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(s.name ?? s.title ?? "Stream").font(.headline)
                    if let t = s.description ?? s.title { Text(t).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if isPinned { Image(systemName: "pin.fill").foregroundStyle(.tint) }
            }
        }
        .disabled(!s.isPlayable)
        .swipeActions {
            if let imdb = imdbID {
                if isPinned { Button("Unpin", systemImage: "pin.slash") { pins.remove(for: imdb) }.tint(.gray) }
                else if s.isPlayable {
                    Button("Pin", systemImage: "pin") { pins.set(Pin(addonID: addon.id, signature: s.signature), for: imdb) }.tint(.orange)
                }
            }
        }
    }

    private var sourceSheet: some View {
        NavigationStack {
            List {
                if let p = pinned {
                    Section("Pinned · \(p.addon.manifest.name)") { row(p.addon, p.stream, isPinned: true) }
                }
                ForEach(streams, id: \.0.id) { addon, items in
                    Section {
                        ForEach(items.filter { $0.id != pinned?.stream.id }) { row(addon, $0, isPinned: false) }
                    } header: { Text(addon.manifest.name) } footer: {
                        if addon.id == streams.first?.0.id { Text("Swipe a source to pin it to the top for this show.") }
                    }
                }
            }
            .overlay {
                if loadingStreams { ProgressView() }
                else if streams.isEmpty {
                    ContentUnavailableView("No sources", systemImage: "play.slash",
                        description: Text("Add a stream add-on in Settings."))
                }
            }
            .navigationTitle("Sources")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}
