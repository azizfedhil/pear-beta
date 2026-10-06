import SwiftUI

/// Editorial-style collections for Home ("Small-Town Secrets"). Each theme is a set of TMDB keywords;
/// the row shows the most popular shows and movies tagged with any of them. Two themes are on Home at a
/// time and the pair changes every day.
struct ThemeDef { let title: String; let keywords: [String] }

struct ThemeRow: Identifiable, Sendable {
    let id: String
    let title: String
    let items: [ThemedTitle]

    /// Only movies ("movie") or only shows ("series"); nil when too few are left to fill a row.
    func filtered(type: String) -> ThemeRow? {
        let kept = items.filter { $0.item.type == type }
        return kept.count >= 3 ? ThemeRow(id: id + "-" + type, title: title, items: kept) : nil
    }
}

enum ThemeCatalog {
    /// Add your own: any phrase TMDB uses as a keyword works.
    static let all: [ThemeDef] = [
        ThemeDef(title: "Small-Town Secrets", keywords: ["small town"]),
        ThemeDef(title: "Cold Case Obsessions", keywords: ["cold case", "serial killer"]),
        ThemeDef(title: "Beyond the Stars", keywords: ["space travel", "outer space"]),
        ThemeDef(title: "Heists & Con Artists", keywords: ["heist", "con artist"]),
        ThemeDef(title: "Time After Time", keywords: ["time travel", "time loop"]),
        ThemeDef(title: "Based on True Stories", keywords: ["based on true story"]),
        ThemeDef(title: "Spy Games", keywords: ["spy", "espionage"]),
        ThemeDef(title: "After the End", keywords: ["post-apocalyptic", "dystopia"]),
        ThemeDef(title: "Courtroom Drama", keywords: ["courtroom", "lawyer"]),
        ThemeDef(title: "Epic Fantasy Worlds", keywords: ["dragon", "sword and sorcery"]),
        ThemeDef(title: "Behind Closed Doors", keywords: ["dysfunctional family", "family secrets"]),
        ThemeDef(title: "Survival Against the Odds", keywords: ["survival", "wilderness"]),
    ]

    /// The same themes all day, new ones tomorrow. `offset` lets another screen take the themes after Home's,
    /// so Home (offset 0, 2 rows) and Explore (offset 2) never show the same one.
    static func today(count: Int, offset: Int = 0) -> [ThemeDef] {
        let day = Calendar.current.ordinality(of: .day, in: .era, for: .now) ?? 0
        let start = (day * 2) % all.count
        return (0..<count).map { all[(start + offset + $0) % all.count] }
    }

    /// Loads the rows concurrently and reports after each one lands (in theme order). A theme with too little data is skipped.
    static func load(count: Int, offset: Int = 0, limit: Int = 8,
                     update: @MainActor @escaping ([ThemeRow]) -> Void) async {
        guard TMDBClient.shared.hasKey else { await update([]); return }
        var done: [Int: ThemeRow] = [:]
        await withTaskGroup(of: (Int, ThemeRow?).self) { group in
            for (i, t) in today(count: count, offset: offset).enumerated() {
                group.addTask {
                    let items = await TMDBClient.shared.themed(keywords: t.keywords, limit: limit)
                    return (i, items.count >= 3 ? ThemeRow(id: "theme-\(t.title)", title: t.title, items: items) : nil)
                }
            }
            for await (i, row) in group {
                guard let row else { continue }
                done[i] = row
                await update(done.keys.sorted().compactMap { done[$0] })
            }
        }
    }
}

struct ThemeCarousel: View {
    let row: ThemeRow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(row.title).font(.title2.bold()).padding(.horizontal, 16)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 14) {
                    ForEach(row.items) { ThemeCard(entry: $0) }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
        }
    }
}

/// Big 4:5 card: key art, a small tag, the title logo and "TV Show · Thriller · Mystery". The next card peeks in.
private struct ThemeCard: View {
    let entry: ThemedTitle
    private var item: MetaPreview { entry.item }

    private var tag: String? {
        var parts: [String] = []
        if let y = item.year { parts.append(String(y)) }
        if let r = item.rating { parts.append("★ " + String(format: "%.1f", r)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    private var caption: String {
        ([item.type == "series" ? "TV Show" : "Movie"] + entry.genres).joined(separator: " · ")
    }

    var body: some View {
        NavigationLink(value: item) {
            Color.clear
                .aspectRatio(4.0 / 5.0, contentMode: .fit)
                .containerRelativeFrame(.horizontal) { w, _ in min(w - 56, 440) }
                .overlay { RemoteImage(url: item.heroURL(wide: false), size: 440) }
                .overlay {
                    LinearGradient(stops: [.init(color: .clear, location: 0.4), .init(color: .black.opacity(0.85), location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                }
                .overlay(alignment: .bottomLeading) { info }
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(.white.opacity(0.15), lineWidth: 1) }
        }
        .buttonStyle(PressableStyle())
        .posterContextMenu(item)
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let tag {
                Text(tag).font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(.black.opacity(0.35), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1))
            }
            TitleArt(item: item, maxWidth: 260, maxHeight: 72, font: .system(size: 30, weight: .heavy, design: .rounded))
            HStack(spacing: 8) {
                Image(systemName: item.type == "series" ? "tv" : "film")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 26, height: 26).background(.black.opacity(0.35), in: Circle())
                Text(caption).font(.subheadline.weight(.medium)).lineLimit(1)
            }
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
