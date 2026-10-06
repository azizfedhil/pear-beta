import SwiftUI

/// Navigation value for Continue Watching: opens the title with the episode you were on selected.
struct ResumeTarget: Hashable {
    let item: MetaPreview
    let season: Int?
    let episode: Int?
}

@MainActor @Observable
final class HomeModel {
    var rows: [CatalogRow] = []
    var suggested: [CatalogRow] = []
    var lists: [CatalogRow] = []
    var upNext: [UpNextItem] = []
    var themes: [ThemeRow] = []

    /// Next episode for each show whose last episode you finished. Resolved concurrently, order kept.
    func loadUpNext(_ entries: [WatchHistory.Entry]) async {
        let batch = Array(entries.prefix(8))
        guard !batch.isEmpty else { upNext = []; return }
        var done: [Int: UpNextItem] = [:]
        await withTaskGroup(of: (Int, UpNextItem?).self) { group in
            for (i, e) in batch.enumerated() { group.addTask { (i, await UpNext.resolve(e)) } }
            for await (i, n) in group {
                if let n { done[i] = n }
                upNext = done.keys.sorted().compactMap { done[$0] }
            }
        }
    }

    /// Two themed collections, different every day.
    func loadThemes() async {
        await ThemeCatalog.load(count: 2) { [weak self] rows in self?.themes = rows }
    }

    func loadLists(selected: Set<Int>) async {
        guard MDBListClient.shared.hasKey, !selected.isEmpty else { lists = []; return }
        let meta = MetadataService.shared
        let chosen = (await meta.mdbUserLists()).filter { selected.contains($0.id) }
        var done: [Int: CatalogRow] = [:]
        await withTaskGroup(of: (Int, CatalogRow?).self) { group in
            for (i, l) in chosen.enumerated() {
                group.addTask {
                    let items = await meta.mdbListItems(listID: l.id)
                    return (i, items.isEmpty ? nil : CatalogRow(id: "mdb-\(l.id)", title: l.name, items: items, symbol: "list.star"))
                }
            }
            for await (i, row) in group {
                guard let row else { continue }
                done[i] = row
                lists = done.keys.sorted().compactMap { done[$0] }
            }
        }
    }

    /// Trending movies and shows interleaved, so the hero mixes both.
    var hero: [MetaPreview] {
        let m = suggested.first { $0.id == "trend-movie" }?.items ?? []
        let t = suggested.first { $0.id == "trend-tv" }?.items ?? []
        var mixed: [MetaPreview] = []
        for i in 0..<max(m.count, t.count) {
            if i < m.count { mixed.append(m[i]) }
            if i < t.count { mixed.append(t[i]) }
        }
        let src = mixed.isEmpty ? (rows.first?.items ?? []) : mixed
        return Array(src.filter { $0.backdropURL != nil || $0.posterURL != nil }.prefix(7))
    }

    /// Trending + recommendations through the unified metadata layer, based on the last thing you watched.
    func loadSuggestions(last: MetaPreview?) async {
        // TMDB key OR a configured AIOMetadata endpoint can answer trending — otherwise a user who
        // relies solely on AIOMetadata would lose the hero and trending rows (Cinemeta replacement).
        guard TMDBClient.shared.hasKey || MetadataService.shared.aioActive else { suggested = []; return }
        let meta = MetadataService.shared
        // Recommendations need an item; start that call only once we have one (no duplicate work).
        var becauseTask: Task<[MetaPreview], Never>? = nil
        if let l = last { becauseTask = Task { await meta.recommendations(for: l) } }
        async let movies = meta.trending(kind: "movie")
        async let shows = meta.trending(kind: "tv")
        let b = await (becauseTask?.value ?? [])
        let (m, t) = await (movies, shows)
        var out: [CatalogRow] = []
        if let l = last, !b.isEmpty {
            out.append(CatalogRow(id: "because", title: "Because you watched \(l.name)", items: b, symbol: "sparkles"))
        }
        if !m.isEmpty { out.append(CatalogRow(id: "trend-movie", title: "Trending Movies", items: m, source: .tmdbTrending("movie"), symbol: "flame.fill")) }
        if !t.isEmpty { out.append(CatalogRow(id: "trend-tv", title: "Trending Shows", items: t, source: .tmdbTrending("tv"), symbol: "flame.fill")) }
        suggested = out
    }

    func load(addons: [Addon]) async {
        let meta = MetadataService.shared
        // Cinemeta takeover (disabled/removed meta add-on): when no enabled add-on declares any
        // browsable catalog, AIOMetadata — if configured and able to answer — supplies Home rows
        // automatically. Deterministic path, checked once per load; the manifest probe behind it is
        // cached per run, so this adds no polling and no repeat requests.
        if !addons.contains(where: { !$0.homeCatalogs.isEmpty }) {
            let movies = await meta.homeRows(type: "movie", limit: 3)
            let series = await meta.homeRows(type: "series", limit: 3)
            let out = movies + series
            if !out.isEmpty { rows = out; return }
        }
        let jobs = addons.flatMap { a in a.homeCatalogs.map { (a, $0) } }.prefix(12)
        var done: [Int: CatalogRow] = [:]
        await withTaskGroup(of: (Int, CatalogRow?).self) { group in
            for (i, job) in jobs.enumerated() {
                group.addTask {
                    let (addon, cat) = job
                    let items = await MetadataService.shared.catalog(addon: addon, catalog: cat)
                    if items.isEmpty { return (i, nil) }
                    let kind = cat.type == "movie" ? "Movies" : cat.type == "series" ? "Series" : cat.type.capitalized
                    return (i, CatalogRow(id: "\(addon.id)/\(cat.type)/\(cat.id)",
                                          title: "\(cat.name ?? cat.id) \(kind)", items: items,
                                          source: .addon(addon, cat), symbol: "film.stack"))
                }
            }
            // Rows appear as each catalog lands; order stays stable.
            for await (i, row) in group {
                guard let row else { continue }
                done[i] = row
                rows = done.keys.sorted().compactMap { done[$0] }
            }
        }
    }
}

extension CatalogRow {
    /// Colour of the row's title icon. ThemeStore is @MainActor, so this must be too.
    @MainActor
    func accent(_ theme: ThemeStore) -> Color {
        switch id {
        case "because": return theme.accent2
        case "trend-movie": return .orange
        case "trend-tv": return .cyan
        default: return id.hasPrefix("mdb-") ? .teal : theme.accent
        }
    }
}

struct HomeView: View {
    @Environment(AddonStore.self) private var store
    @Environment(WatchHistory.self) private var history
    @Environment(ThemeStore.self) private var theme
    @AppStorage("tmdb.key") private var tmdbKey = ""
    @AppStorage("mdblist.key") private var mdbKey = ""
    @AppStorage("mdblist.lists") private var mdbLists = ""
    @State private var model = HomeModel()
    /// Colour pulled from the current hero artwork; washes softly behind the first rows.
    @State private var tint: Color?
    private var selectedLists: Set<Int> { Set(mdbLists.split(separator: ",").compactMap { Int($0) }) }

    var body: some View {
        let hero = model.hero
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 30) {
                    if !hero.isEmpty { HeroCarousel(items: hero, tint: $tint) }
                    if !history.continueEntries.isEmpty || !model.upNext.isEmpty {
                        ContinueRow(entries: history.continueEntries, upNext: model.upNext)
                    }
                    if let t = model.themes.first { ThemeCarousel(row: t) }
                    ForEach(model.suggested) { CatalogRowView(row: $0) }
                    if model.themes.count > 1 { ThemeCarousel(row: model.themes[1]) }
                    ForEach(model.lists) { CatalogRowView(row: $0) }
                    ForEach(model.rows) { CatalogRowView(row: $0) }
                }
                .padding(.bottom, 40)
                .animation(.smooth(duration: 0.5), value: model.rows.count + model.suggested.count + model.lists.count + model.upNext.count + model.themes.count)
                .background(alignment: .top) { ambient }
            }
            .ignoresSafeArea(edges: .top)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .scrollEdgeEffectHidden(true, for: .top)
            .profileToolbar(logo: true)
            .scrollIndicators(.hidden)
            .refreshable { await refresh() }
            .overlay { if model.rows.isEmpty && model.suggested.isEmpty { ProgressView() } }
            .navigationDestination(for: MetaPreview.self) { DetailView(item: $0) }
            .navigationDestination(for: ResumeTarget.self) { DetailView(item: $0.item, startSeason: $0.season, startEpisode: $0.episode) }
            .navigationDestination(for: CatalogRow.self) { CatalogGridView(row: $0) }
            .task(id: store.activeAddons.map(\.id) + [String(store.revision)]) { await model.load(addons: store.activeAddons) }
            .task(id: tmdbKey) { await model.loadThemes() }
            .task(id: mdbKey + mdbLists) { await model.loadLists(selected: selectedLists) }
            .task(id: tmdbKey + (history.lastWatched?.id ?? "")) { await model.loadSuggestions(last: history.lastWatched) }
            .task(id: history.finishedSeries) { await model.loadUpNext(history.finishedEntries) }
        }
    }

    @ViewBuilder private var ambient: some View {
        let t = tint ?? theme.accent
        LinearGradient(colors: [t.opacity(0.7), t.opacity(0.25), .clear], startPoint: .top, endPoint: .bottom)
            .frame(height: 1100)
            .allowsHitTesting(false)
    }

    private func refresh() async {
        async let a: () = model.load(addons: store.activeAddons)
        async let b: () = model.loadSuggestions(last: history.lastWatched)
        async let c: () = model.loadLists(selected: selectedLists)
        async let d: () = model.loadUpNext(history.finishedEntries)
        async let e: () = model.loadThemes()
        _ = await (a, b, c, d, e)
    }
}

// MARK: - Hero

struct HeroCarousel: View {
    let items: [MetaPreview]
    @Binding var tint: Color?
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var page: String?
    @State private var visible = true

    private static let interval = 7.0
    private var wide: Bool { hSize == .regular }
    private var height: CGFloat { wide ? 640 : 600 }
    private var currentID: String { page ?? items.first?.id ?? "" }
    private var index: Int { items.firstIndex(where: { $0.id == currentID }) ?? 0 }

    private struct AutoKey: Hashable { let page: String; let visible: Bool }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(items) { item in
                    HeroPage(item: item, active: item.id == currentID && visible, wide: wide, height: height)
                        .containerRelativeFrame(.horizontal)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $page)
        .scrollIndicators(.hidden)
        .frame(height: height)
        .overlay(alignment: .bottom) {
            if items.count > 1 { HeroIndicator(count: items.count, index: index, duration: Self.interval).padding(.bottom, 12) }
        }
        .sensoryFeedback(.selection, trigger: page)
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .onChange(of: items.map(\.id)) { _, ids in
            if let p = page, !ids.contains(p) { page = ids.first }
        }
        // Auto-advance. The task restarts on every page change (manual swipes included) and pauses off-screen.
        .task(id: AutoKey(page: currentID, visible: visible)) {
            guard visible, items.count > 1 else { return }
            try? await Task.sleep(for: .seconds(Self.interval))
            guard !Task.isCancelled else { return }
            let next = (index + 1) % items.count
            if next == 0 {
                var t = Transaction(); t.disablesAnimations = true     // rewind without streaking through every page
                withTransaction(t) { page = items[0].id }
            } else {
                withAnimation(.easeInOut(duration: 0.9)) { page = items[next].id }
            }
        }
        .task(id: currentID) { await updateTint() }
    }

    private func updateTint() async {
        guard let item = items.first(where: { $0.id == currentID }),
              let url = item.heroURL(wide: wide),
              let c = await ImagePipeline.shared.averageColor(for: url), !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.9)) { tint = Color(uiColor: c) }
    }
}

private struct HeroPage: View {
    let item: MetaPreview
    let active: Bool
    let wide: Bool
    let height: CGFloat

    var body: some View {
        NavigationLink(value: item) {
            ZStack(alignment: .bottomLeading) {
                // Slow Ken Burns zoom while this page is showing. The darkening scrim sits on the artwork and both
                // are faded out together along one eased curve, so the art melts into the page background with no
                // visible start line and no hard edge where the hero ends. One static mask, nothing animated.
                ZStack {
                    KenBurns(active: active) {
                        RemoteImage(url: item.heroURL(wide: wide), size: wide ? 1200 : 800)
                    }
                    LinearGradient.easedFade(start: 0.4, from: 0, to: 0.6)
                }
                .mask { LinearGradient.easedFade(start: 0.42, from: 1, to: 0) }
                info
            }
            .frame(height: height)
            .clipped()
        }
        .buttonStyle(.plain)
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(item.typeLabel.uppercased(), systemImage: item.type == "series" ? "tv" : "film")
                    .font(.caption2.weight(.heavy)).tracking(1.2)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(.white.opacity(0.18), in: Capsule())
                if let y = item.year { Text(String(y)).font(.subheadline.weight(.semibold)).opacity(0.9) }
            }
            // Logo when we have one, title text otherwise (text shows first, then swaps once the logo has loaded).
            TitleArt(item: item, maxWidth: 270, maxHeight: 86, font: .system(size: 38, weight: .heavy, design: .rounded))
            InlineRatings(item: item)
            if let d = item.description, !d.isEmpty {
                Text(d).font(.subheadline).lineLimit(2).opacity(0.85)
            }
            // Flat on purpose: live glass over artwork that is moving would be re-sampled every frame.
            Label("Details", systemImage: "info.circle")
                .font(.subheadline.weight(.semibold)).padding(.horizontal, 18).padding(.vertical, 10)
                .background(.white.opacity(0.2), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.28), lineWidth: 0.5))
                .padding(.top, 2)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20).padding(.bottom, 46)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Text slides slightly faster than the artwork while paging, and fades out as it leaves.
        .scrollTransition(axis: .horizontal) { content, phase in
            content.opacity(1 - min(abs(phase.value) * 1.6, 1)).offset(x: phase.value * 70)
        }
    }
}

private extension LinearGradient {
    /// Top-to-bottom gradient that holds `from` opacity down to `start` (0...1 of the height), then eases to `to`
    /// at the bottom along a smoothstep curve. A plain two-stop ramp has a visible kink where it begins; the
    /// eased curve starts and ends with zero slope, which is what makes a fade read as seamless.
    static func easedFade(_ color: Color = .black, start: CGFloat, from a: Double, to b: Double, steps: Int = 10) -> LinearGradient {
        var stops: [Gradient.Stop] = [.init(color: color.opacity(a), location: 0)]
        for i in 0...steps {
            let u = Double(i) / Double(steps)
            let eased = u * u * (3 - 2 * u)
            stops.append(.init(color: color.opacity(a + (b - a) * eased), location: start + (1 - start) * CGFloat(u)))
        }
        return LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
    }
}

/// Slow zoom on the hero artwork. Motion this small doesn't need the display's full refresh rate: it steps at 24 Hz
/// (a fraction of a point per step, so it still reads as continuous) instead of 120 Hz, and it stops completely
/// off screen, under Reduce Motion, and in Low Power Mode.
private struct KenBurns<Content: View>: View {
    let active: Bool
    let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var began = Date()

    init(active: Bool, @ViewBuilder content: () -> Content) {
        self.active = active
        self.content = content()
    }

    private var moving: Bool { active && !reduceMotion && !PowerMode.shared.saving }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !moving)) { tl in
            content.scaleEffect(scale(at: tl.date))
        }
        .onChange(of: moving) { _, on in if on { began = Date() } }
    }

    private func scale(at date: Date) -> CGFloat {
        guard moving else { return 1 }
        let t = min(max(date.timeIntervalSince(began), 0) / 9, 1)
        return 1 + 0.08 * CGFloat(t)
    }
}

private struct HeroIndicator: View {
    let count: Int
    let index: Int
    let duration: Double

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                let on = i == index
                Capsule().fill(.white.opacity(0.35))
                    .frame(width: on ? 28 : 6, height: 5)
                    .overlay(alignment: .leading) { if on { AutoFill(duration: duration) } }
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: index)
            }
        }
    }
}

/// White fill that sweeps across the active indicator over one auto-advance interval.
private struct AutoFill: View {
    let duration: Double
    @State private var on = false

    var body: some View {
        Capsule().fill(.white)
            .frame(width: on ? 28 : 0, height: 5)
            .onAppear { withAnimation(.linear(duration: duration)) { on = true } }
    }
}

/// Rating pills with brand icons. Uses MDBList (IMDb / Rotten Tomatoes / Metacritic...) when a key is set,
/// and otherwise the rating that came with the title (IMDb from add-ons, TMDB from TMDB).
struct InlineRatings: View {
    let item: MetaPreview
    @State private var extra: [MDBListClient.Rating] = []

    private var chips: [MDBListClient.Rating] {
        if !extra.isEmpty {
            let order = ["IMDb", "Rotten Tomatoes", "RT Audience", "Metacritic", "Letterboxd", "Trakt"]
            return extra.sorted { (order.firstIndex(of: $0.label) ?? 99) < (order.firstIndex(of: $1.label) ?? 99) }
        }
        if let r = item.rating {
            return [MDBListClient.Rating(label: item.ratingLabel, text: String(format: "%.1f", r), score: r)]
        }
        return []
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(chips.prefix(3)) { RatingPill(rating: $0) }
        }
        .task(id: item.id) {
            extra = []
            guard MDBListClient.shared.hasKey else { return }
            // ID resolution + ratings go through the unified metadata layer (TMDB id cache dedupes lookups).
            guard let imdb = await MetadataService.shared.stremioID(for: item) else { return }
            extra = await MetadataService.shared.ratings(for: item, imdb: imdb)
        }
    }
}

// MARK: - Continue Watching

/// One carousel holds both in-progress titles and the next episode of finished ones, most recent first.
struct ContinueRow: View {
    let entries: [WatchHistory.Entry]
    let upNext: [UpNextItem]
    @Environment(ThemeStore.self) private var theme

    private enum Card: Identifiable {
        case resume(WatchHistory.Entry)
        case next(UpNextItem)
        var id: String {
            switch self {
            case .resume(let e): return "r-\(e.id)"
            case .next(let n): return "n-\(n.id)"
            }
        }
        var date: Date {
            switch self {
            case .resume(let e): return e.updated
            case .next(let n): return n.updated
            }
        }
    }

    private var cards: [Card] {
        (entries.map(Card.resume) + upNext.map(Card.next)).sorted { $0.date > $1.date }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "play.circle.fill").font(.system(size: 15, weight: .bold)).foregroundStyle(theme.accent2)
                Text("Continue Watching").font(.title3.bold())
            }
            .padding(.horizontal, 16)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 14) {
                    ForEach(cards) { card in
                        switch card {
                        case .resume(let e): ContinueCard(entry: e)
                        case .next(let n): UpNextCard(entry: n)
                        }
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
        }
    }
}

/// 16:9 card: episode still (or movie backdrop), where you stopped, and how much is left.
private struct ContinueCard: View {
    let entry: WatchHistory.Entry
    @Environment(WatchHistory.self) private var history
    @Environment(ThemeStore.self) private var theme
    private let width: CGFloat = 270

    private var thumb: URL? {
        entry.thumb.flatMap(URL.init(string:)) ?? entry.item.backdropURL ?? entry.item.posterURL
    }

    private var subtitle: String {
        let left = Fmt.remaining(entry.duration - entry.position)
        if let se = entry.seasonEpisode { return "S\(se.season) · E\(se.episode) · \(left)" }
        return left
    }

    var body: some View {
        NavigationLink(value: ResumeTarget(item: entry.item, season: entry.seasonEpisode?.season, episode: entry.seasonEpisode?.episode)) {
            VStack(alignment: .leading, spacing: 8) {
                Color.clear
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .frame(width: width)
                    .overlay { RemoteImage(url: thumb, size: width) }
                    .overlay { LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .center, endPoint: .bottom) }
                    .overlay {
                        Image(systemName: "play.fill").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 42, height: 42).background(.black.opacity(0.38), in: Circle())
                            .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                    }
                    .overlay(alignment: .topTrailing) {
                        Text(Fmt.clock(entry.position)).font(.system(size: 11, weight: .bold)).monospacedDigit()
                            .foregroundStyle(.white).padding(.horizontal, 7).padding(.vertical, 3)
                            .background(.black.opacity(0.62), in: Capsule()).padding(8)
                    }
                    .overlay(alignment: .bottom) { progressBar }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.item.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(width: width, alignment: .leading)
            }
        }
        .buttonStyle(PressableStyle())
        .contextMenu {
            Button("Remove from Continue Watching", systemImage: "xmark.circle", role: .destructive) {
                withAnimation { history.remove(entry.id) }
            }
            Divider()
            PosterContextMenu(item: entry.item)
        }
    }

    private var progressBar: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Rectangle().fill(.white.opacity(0.3))
                Rectangle().fill(theme.gradient).frame(width: g.size.width * entry.progress)
            }
        }
        .frame(height: 4)
    }
}

// MARK: - Up Next

private struct UpNextCard: View {
    let entry: UpNextItem
    @Environment(ThemeStore.self) private var theme
    private let width: CGFloat = 270

    var body: some View {
        NavigationLink(value: ResumeTarget(item: entry.item, season: entry.season, episode: entry.episode)) {
            VStack(alignment: .leading, spacing: 8) {
                Color.clear
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .frame(width: width)
                    .overlay { RemoteImage(url: entry.thumb, size: width) }
                    .overlay { LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .center, endPoint: .bottom) }
                    .overlay {
                        Image(systemName: "play.fill").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 42, height: 42).background(.black.opacity(0.38), in: Circle())
                            .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                    }
                    .overlay(alignment: .topLeading) {
                        Text("UP NEXT").font(.system(size: 10, weight: .heavy)).tracking(0.8).foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(theme.accent, in: Capsule()).padding(8)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.item.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text("S\(entry.season) · E\(entry.episode) · \(entry.title)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(width: width, alignment: .leading)
            }
        }
        .buttonStyle(PressableStyle())
    }
}

// MARK: - Rows + posters

struct CatalogRowView: View {
    let row: CatalogRow
    @Environment(ThemeStore.self) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Tapping the title opens the full list for this row.
            NavigationLink(value: row) {
                HStack(spacing: 8) {
                    if let s = row.symbol {
                        Image(systemName: s).font(.system(size: 15, weight: .bold)).foregroundStyle(row.accent(theme))
                    }
                    Text(row.title).font(.title3.bold())
                    Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain).padding(.horizontal, 16)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(row.items) { item in
                        PosterCard(item: item)
                            .scrollTransition(axis: .horizontal) { content, phase in
                                content.scaleEffect(phase.isIdentity ? 1 : 0.92).opacity(phase.isIdentity ? 1 : 0.6)
                            }
                    }
                    NavigationLink(value: row) {
                        VStack(spacing: 8) {
                            Image(systemName: "arrow.right.circle").font(.title)
                            Text("See all").font(.footnote.weight(.semibold))
                        }
                        .foregroundStyle(.secondary).frame(width: 67, height: 131)
                    }
                    .buttonStyle(.plain)
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
        }
    }
}

/// Springy press feedback for tappable cards.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Poster with a rating chip and an optional network icon (shows only). `width: nil` fills its grid column.
/// `showsTitle` adds the title and year underneath (grids and search).
/// Tap opens the detail page; long tap shows the actions dropdown (watched / library / details).
struct PosterCard: View {
    let item: MetaPreview
    var width: CGFloat? = 87          // 33% smaller than the old 130, closer to the Apple TV+ look
    var showsTitle = false
    @Environment(WatchHistory.self) private var history
    @Environment(ThemeStore.self) private var theme
    @AppStorage("ui.networkBadges") private var showNetwork = true
    @State private var network: TMDBClient.NetworkBadge?

    /// Small row posters get slightly smaller badges so they don't cover the artwork.
    private var compact: Bool { (width ?? 130) < 100 }

    private var caption: String {
        [item.year.map(String.init), item.typeLabel].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        poster
            .frame(width: width, alignment: .topLeading)
            // Visible cards only (LazyHStack/LazyVGrid); cancelled when scrolled away, cached afterwards.
            .task(id: item.id) {
                network = nil
                guard showNetwork, item.type == "series", TMDBClient.shared.hasKey else { return }
                network = await MetadataService.shared.networkBadge(for: item)
            }
            // Long tap: dropdown with mark as watched / add to library / details.
            .posterContextMenu(item)
    }

    /// Checkmark shown over posters of titles marked as watched.
    @ViewBuilder private var watchedBadge: some View {
        if history.entry(for: item.id)?.isFinished == true {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: compact ? 14 : 17, weight: .bold))
                .foregroundStyle(.white, theme.accent)
                .padding(compact ? 4 : 6)
                .accessibilityLabel("Watched")
        }
    }

    private var poster: some View {
        NavigationLink(value: item) {
            VStack(alignment: .leading, spacing: 7) {
                RemoteImage(url: item.posterURL, size: (width ?? 120) * 1.5)
                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
                    .frame(width: width)
                    .clipShape(RoundedRectangle(cornerRadius: compact ? 9 : 12, style: .continuous))
                    .overlay(alignment: .topLeading) { watchedBadge }
                    .overlay(alignment: .topLeading) {
                        if let logo = network?.logo {
                            LogoImage(url: logo)
                                .frame(maxWidth: compact ? 24 : 34, maxHeight: compact ? 10 : 14)
                                .padding(.horizontal, compact ? 4 : 6).padding(.vertical, compact ? 3 : 5)
                                .background(.white.opacity(0.92), in: RoundedRectangle(cornerRadius: compact ? 6 : 8, style: .continuous))
                                .padding(compact ? 4 : 6)
                                .accessibilityLabel(network?.name ?? "")
                        }
                    }
                    .overlay(alignment: .bottomLeading) { RatingChip(item: item).padding(compact ? 4 : 6) }
                if showsTitle {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(.footnote.weight(.semibold))
                            .lineLimit(2, reservesSpace: true).multilineTextAlignment(.leading)
                        Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .buttonStyle(PressableStyle())
    }
}
