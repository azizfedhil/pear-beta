import SwiftUI

/// Backs the "See all" page: starts from the row's items, then keeps loading pages as you scroll.
@MainActor @Observable
final class GridModel {
    private(set) var items: [MetaPreview]
    private(set) var isLoading = false
    private(set) var hasMore: Bool
    private let source: CatalogSource
    private var tmdbPage = 1
    private var fetched: Int      // raw count served by an add-on so far (its `skip` cursor)

    init(row: CatalogRow) {
        items = row.items
        source = row.source
        fetched = row.items.count
        switch row.source {
        case .none: hasMore = false
        case .tmdbTrending: hasMore = true
        case .addon(_, let cat): hasMore = cat.supportsSkip
        }
    }

    func loadMore() async {
        guard hasMore, !isLoading else { return }
        isLoading = true; defer { isLoading = false }
        var fresh: [MetaPreview] = []
        switch source {
        case .none:
            break
        case .tmdbTrending(let kind):
            fresh = await MetadataService.shared.trending(kind: kind, page: tmdbPage + 1)
            if !fresh.isEmpty { tmdbPage += 1 }
        case .addon(let addon, let cat):
            fresh = await MetadataService.shared.catalog(addon: addon, catalog: cat, skip: fetched)
            fetched += fresh.count
        }
        let known = Set(items.map(\.id))
        let new = fresh.filter { !known.contains($0.id) }
        items += new
        // Stop when a page is empty or adds nothing new (avoids looping on add-ons that ignore `skip`).
        hasMore = !new.isEmpty
    }
}

struct CatalogGridView: View {
    let row: CatalogRow
    @State private var model: GridModel
    @State private var order: Order = .newest
    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 160), spacing: 12, alignment: .top)]

    enum Order: String, CaseIterable, Identifiable {
        case newest = "Newest first"
        case oldest = "Oldest first"
        case original = "Original order"
        var id: String { rawValue }
    }

    init(row: CatalogRow) {
        self.row = row
        _model = State(initialValue: GridModel(row: row))
    }

    private struct YearSection { let title: String; let items: [MetaPreview] }

    /// Grouped by release year; within a year the source order is kept.
    private var sections: [YearSection] {
        if order == .original { return [YearSection(title: "", items: model.items)] }
        let groups = Dictionary(grouping: model.items) { $0.year }
        let years = groups.keys.compactMap { $0 }.sorted { order == .newest ? $0 > $1 : $0 < $1 }
        var out = years.map { YearSection(title: String($0), items: groups[$0] ?? []) }
        if let unknown = groups[Int?.none], !unknown.isEmpty {
            out.append(YearSection(title: "Unknown year", items: unknown))
        }
        return out
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(sections, id: \.title) { sec in
                    Section {
                        LazyVGrid(columns: columns, spacing: 18) {
                            ForEach(sec.items) { PosterCard(item: $0, width: nil, showsTitle: true) }
                        }
                        .padding(.horizontal, 16).padding(.bottom, 22)
                    } header: {
                        if !sec.title.isEmpty { header(sec) }
                    }
                }
                // Reaching the bottom loads the next page; re-fires after each page until the screen is full.
                Color.clear.frame(height: 1).task(id: model.items.count) { await model.loadMore() }
                if model.isLoading { ProgressView().frame(maxWidth: .infinity).padding(24) }
            }
        }
        .scrollIndicators(.hidden)
        .navigationTitle(row.title)
        .navigationSubtitle("\(model.items.count) titles")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Order", selection: $order) {
                        ForEach(Order.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: { Image(systemName: "calendar") }
            }
        }
        .animation(.smooth(duration: 0.35), value: order)
    }

    private func header(_ sec: YearSection) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(sec.title).font(.title3.bold())
            Text("\(sec.items.count)").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color(.systemBackground).opacity(0.94))
    }
}
