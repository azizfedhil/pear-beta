import SwiftUI

@MainActor @Observable
final class ExploreModel {
    private(set) var kind = "movie"            // TMDB kind: "movie" | "tv"
    private(set) var genre: Int?
    private(set) var year: Int?
    private(set) var sort: DiscoverSort = .popular
    private(set) var items: [MetaPreview] = []
    private(set) var genres: [TMDBClient.Genre] = []
    private(set) var isLoading = false
    private(set) var hasMore = true
    private(set) var themes: [ThemeRow] = []
    private var page = 0
    private var generation = 0

    /// No filters: show what's trending this week.
    var isTrending: Bool { genre == nil && year == nil && sort == .popular }
    var hasFilters: Bool { genre != nil || year != nil || sort != .popular }

    func setKind(_ k: String) async {
        guard k != kind else { return }
        kind = k; genre = nil                  // genre ids differ between movies and shows
        genres = []
        async let g: () = loadGenres()
        await reload()
        await g
    }
    func setGenre(_ g: Int?) async { guard g != genre else { return }; genre = g; await reload() }
    func setYear(_ y: Int?) async { guard y != year else { return }; year = y; await reload() }
    func setSort(_ s: DiscoverSort) async { guard s != sort else { return }; sort = s; await reload() }
    func clearFilters() async { genre = nil; year = nil; sort = .popular; await reload() }

    /// Three themed rows (the ones after Home's), shown above the grid while no filter is active.
    func loadThemes() async {
        await ThemeCatalog.load(count: 3, offset: 2, limit: 16) { [weak self] rows in self?.themes = rows }
    }
    /// Movies tab shows movie rows, Shows tab shows series rows.
    var themeRows: [ThemeRow] { themes.compactMap { $0.filtered(type: kind == "tv" ? "series" : "movie") } }

    func loadGenres() async {
        let k = kind
        let list = await MetadataService.shared.genres(kind: k)
        if k == kind { genres = list }
    }

    func reload() async {
        generation += 1
        items = []; page = 0; hasMore = true; isLoading = false
        await loadMore()
    }

    func loadMore() async {
        // The facade's gate: a TMDB key, or AIOMetadata mode with an endpoint configured.
        guard hasMore, !isLoading, MetadataService.shared.browseAvailable else { return }
        let gen = generation
        isLoading = true
        defer { if gen == generation { isLoading = false } }
        let next = page + 1
        let fresh: [MetaPreview]
        if isTrending { fresh = await MetadataService.shared.trending(kind: kind, page: next) }
        else { fresh = await MetadataService.shared.discover(kind: kind, genre: genre, year: year, sort: sort, page: next) }
        guard gen == generation else { return }          // filters changed while this page was loading
        page = next
        let known = Set(items.map(\.id))
        items += fresh.filter { !known.contains($0.id) }
        hasMore = !fresh.isEmpty && page < 40
    }
}

struct ExploreView: View {
    @State private var model = ExploreModel()
    @AppStorage("tmdb.key") private var tmdbKey = ""
    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 160), spacing: 12, alignment: .top)]
    private let years: [Int] = {
        let now = Calendar.current.component(.year, from: .now)
        return Array((1950...(now + 1)).reversed())
    }()

    var body: some View {
        NavigationStack {
            Group {
                // Browsing needs either a TMDB key or AIOMetadata mode with an endpoint configured;
                // the facade decides which backend answers each call.
                if !MetadataService.shared.browseAvailable {
                    ContentUnavailableView("Explore needs TMDB", systemImage: "safari",
                        description: Text("Add a free TMDB API key in Settings → Integrations to browse trending titles and filter by genre and year — or pick AIOMetadata as the metadata source and set its endpoint there."))
                } else { content }
            }
            .navigationTitle("Explore")
            .profileToolbar()
            .navigationDestination(for: MetaPreview.self) { DetailView(item: $0) }
        }
        .task(id: tmdbKey) {
            // Re-runs when the key changes; AIOMetadata-mode switches re-enter via `mode` below.
            guard MetadataService.shared.browseAvailable else { return }
            async let g: () = model.loadGenres()
            async let t: () = model.loadThemes()
            if model.items.isEmpty { await model.reload() }
            _ = await (g, t)
        }
        .task(id: MetadataService.shared.mode) {
            // A user who enables AIOMetadata later gets Explore content without relaunching —
            // one-shot on change, no polling involved.
            guard MetadataService.shared.mode == .aiometadata,
                  MetadataService.shared.browseAvailable else { return }
            if model.items.isEmpty { await model.reload() }
        }
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                filters
                if !model.hasFilters && !model.themeRows.isEmpty {
                    VStack(alignment: .leading, spacing: 26) {
                        ForEach(model.themeRows) { ThemeCarousel(row: $0) }
                    }
                    .padding(.bottom, 10)
                }
                HStack(spacing: 8) {
                    Image(systemName: model.isTrending ? "flame.fill" : "line.3.horizontal.decrease.circle.fill")
                        .foregroundStyle(model.isTrending ? .orange : Color.accentColor)
                    Text(heading).font(.title3.bold())
                }
                .padding(.horizontal, 16)

                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(model.items) { PosterCard(item: $0, width: nil, showsTitle: true) }
                }
                .padding(.horizontal, 16)
                .animation(.smooth(duration: 0.3), value: model.items.count)

                Color.clear.frame(height: 1).task(id: model.items.count) { await model.loadMore() }
                if model.isLoading { ProgressView().frame(maxWidth: .infinity).padding(24) }
                else if model.items.isEmpty && !model.hasMore {
                    ContentUnavailableView("Nothing found", systemImage: "film.stack",
                        description: Text("Try a different genre or year."))
                }
            }
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
        .refreshable {
            async let t: () = model.loadThemes()
            await model.reload()
            await t
        }
    }

    private var heading: String {
        let noun = model.kind == "tv" ? "Shows" : "Movies"
        if model.isTrending { return "Trending \(noun)" }
        var parts: [String] = []
        if let g = model.genres.first(where: { $0.id == model.genre }) { parts.append(g.name) }
        if let y = model.year { parts.append(String(y)) }
        parts.append(noun)
        return parts.joined(separator: " · ")
    }

    // MARK: Filters

    private var filters: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Type", selection: Binding(get: { model.kind }, set: { k in Task { await model.setKind(k) } })) {
                Text("Movies").tag("movie"); Text("Shows").tag("tv")
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    chip("All genres", on: model.genre == nil) { Task { await model.setGenre(nil) } }
                    ForEach(model.genres) { g in
                        chip(g.name, on: model.genre == g.id) { Task { await model.setGenre(g.id) } }
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)

            HStack(spacing: 10) {
                Menu {
                    Picker("Year", selection: Binding(get: { model.year ?? 0 }, set: { y in Task { await model.setYear(y == 0 ? nil : y) } })) {
                        Text("Any year").tag(0)
                        ForEach(years, id: \.self) { Text(String($0)).tag($0) }
                    }
                } label: {
                    menuLabel(model.year.map(String.init) ?? "Any year", symbol: "calendar", on: model.year != nil)
                }
                Menu {
                    Picker("Sort", selection: Binding(get: { model.sort }, set: { s in Task { await model.setSort(s) } })) {
                        ForEach(DiscoverSort.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: {
                    menuLabel(model.sort.rawValue, symbol: "arrow.up.arrow.down", on: model.sort != .popular)
                }
                if model.hasFilters {
                    Button { Task { await model.clearFilters() } } label: {
                        Label("Reset", systemImage: "xmark.circle.fill").font(.footnote.weight(.semibold))
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
        }
    }

    private func chip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.footnote.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(on ? Color.accentColor : Color.white.opacity(0.1), in: Capsule())
                .foregroundStyle(on ? Color.white : Color.primary)
        }
        .buttonStyle(PressableStyle())
        .animation(.snappy(duration: 0.2), value: on)
    }

    private func menuLabel(_ title: String, symbol: String, on: Bool) -> some View {
        Label(title, systemImage: symbol)
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(on ? Color.accentColor.opacity(0.25) : Color.white.opacity(0.1), in: Capsule())
            .foregroundStyle(on ? Color.accentColor : Color.primary)
    }
}
