import Foundation

// MARK: Stremio add-on protocol models (tolerant decoding: add-ons are inconsistent)

struct AddonManifest: Decodable, Sendable, Hashable {
    let id: String
    let name: String
    let version: String?
    let description: String?
    let logo: String?
    let types: [String]?
    let catalogs: [CatalogDef]?
    let resources: [Resource]?
    let idPrefixes: [String]?

    struct CatalogDef: Decodable, Sendable, Hashable {
        let type: String
        let id: String
        let name: String?
        let extra: [Extra]?
        // Older manifests declare extras as plain string lists instead of `extra`.
        let extraSupported: [String]?
        let extraRequired: [String]?
        struct Extra: Decodable, Sendable, Hashable {
            let name: String
            let isRequired: Bool?
        }
        var supportedExtras: Set<String> {
            Set((extra ?? []).map(\.name) + (extraSupported ?? []) + (extraRequired ?? []))
        }
        var requiredExtras: Set<String> {
            Set((extra ?? []).filter { $0.isRequired ?? false }.map(\.name) + (extraRequired ?? []))
        }
        /// Home rows can't satisfy required params (e.g. search-only catalogs).
        var isBrowsable: Bool { requiredExtras.isEmpty }
        var supportsSkip: Bool { supportedExtras.contains("skip") }
        /// Can answer `search=<query>` without needing any other parameter.
        var isSearchable: Bool { supportedExtras.contains("search") && requiredExtras.subtracting(["search"]).isEmpty }
    }

    /// `resources` is either ["stream"] or [{name, types, idPrefixes}].
    struct Resource: Decodable, Sendable, Hashable {
        let name: String
        let types: [String]?
        let idPrefixes: [String]?
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) {
                name = s; types = nil; idPrefixes = nil
            } else {
                struct D: Decodable { let name: String; let types: [String]?; let idPrefixes: [String]? }
                let d = try c.decode(D.self)
                name = d.name; types = d.types; idPrefixes = d.idPrefixes
            }
        }
    }
}

struct Addon: Identifiable, Sendable, Hashable {
    let manifestURL: URL
    let manifest: AddonManifest
    var id: String { manifestURL.absoluteString }
    var baseURL: URL { manifestURL.deletingLastPathComponent() }
    var homeCatalogs: [AddonManifest.CatalogDef] { (manifest.catalogs ?? []).filter(\.isBrowsable) }

    func provides(_ resource: String, type: String, id: String) -> Bool {
        guard let r = manifest.resources?.first(where: { $0.name == resource }) else { return false }
        if let t = r.types, !t.contains(type) { return false }
        if let p = (r.idPrefixes ?? manifest.idPrefixes), !p.contains(where: id.hasPrefix) { return false }
        return true
    }

    static func normalize(_ input: String) throws -> URL {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("stremio://") { s = "https://" + s.dropFirst("stremio://".count) }
        if !s.hasSuffix("manifest.json") { s = s.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/manifest.json" }
        guard let url = URL(string: s), url.scheme?.hasPrefix("http") == true else { throw URLError(.badURL) }
        return url
    }
}

struct MetaPreview: Identifiable, Sendable, Hashable {
    let id: String
    let type: String
    let name: String
    let poster: String?
    let background: String?
    let logo: String?
    let description: String?
    let releaseInfo: String?
    /// 0-10. IMDb rating for add-on items (`imdbRating`), TMDB vote average for TMDB items.
    var rating: Double? = nil

    var posterURL: URL? { poster.flatMap(URL.init(string:)) ?? metahub("poster") }
    var backdropURL: URL? {
        background.flatMap(URL.init(string:)) ?? metahub("background") ?? poster.flatMap(URL.init(string:))
    }
    private func metahub(_ kind: String) -> URL? {
        id.hasPrefix("tt") ? URL(string: "https://images.metahub.space/\(kind)/medium/\(id)/img") : nil
    }

    /// First four digits of `releaseInfo` ("2021", "2019-2022", "2019-").
    var year: Int? {
        guard let r = releaseInfo?.trimmingCharacters(in: .whitespaces), r.count >= 4 else { return nil }
        return Int(r.prefix(4))
    }
    /// Which service the `rating` number comes from.
    var ratingLabel: String { id.hasPrefix("tmdb:") ? "TMDB" : "IMDb" }
    var typeLabel: String { type == "series" ? "Series" : "Movie" }
    func with(rating r: Double?) -> MetaPreview { var c = self; c.rating = r; return c }

    /// Bigger artwork for full-width hero cards (the list sizes are tuned for small posters).
    func heroURL(wide: Bool) -> URL? {
        let raw = wide ? (backdropURL ?? posterURL) : (posterURL ?? backdropURL)
        guard var s = raw?.absoluteString else { return nil }
        if s.contains("/t/p/w342/") { s = s.replacingOccurrences(of: "/t/p/w342/", with: "/t/p/w780/") }
        else if s.contains("/t/p/w780/") { s = s.replacingOccurrences(of: "/t/p/w780/", with: "/t/p/w1280/") }
        else if s.contains("metahub.space/") { s = s.replacingOccurrences(of: "/medium/", with: "/large/") }
        return URL(string: s) ?? raw
    }
}

/// Hand-written so one odd field (rating as a string, year as a number...) never drops a whole catalog.
extension MetaPreview: Codable {
    private enum K: String, CodingKey {
        case id, type, name, poster, background, logo, description, releaseInfo, rating, imdbRating
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = try c.decode(String.self, forKey: .id)
        type = try c.decode(String.self, forKey: .type)
        name = try c.decode(String.self, forKey: .name)
        poster = try? c.decodeIfPresent(String.self, forKey: .poster)
        background = try? c.decodeIfPresent(String.self, forKey: .background)
        logo = try? c.decodeIfPresent(String.self, forKey: .logo)
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        if let s = try? c.decodeIfPresent(String.self, forKey: .releaseInfo) { releaseInfo = s }
        else if let n = try? c.decodeIfPresent(Int.self, forKey: .releaseInfo) { releaseInfo = String(n) }
        else { releaseInfo = nil }
        let r = Self.number(c, .rating) ?? Self.number(c, .imdbRating)
        rating = (r ?? 0) > 0 ? r : nil
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(id, forKey: .id)
        try c.encode(type, forKey: .type)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(poster, forKey: .poster)
        try c.encodeIfPresent(background, forKey: .background)
        try c.encodeIfPresent(logo, forKey: .logo)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(releaseInfo, forKey: .releaseInfo)
        try c.encodeIfPresent(rating, forKey: .rating)
    }

    private static func number(_ c: KeyedDecodingContainer<K>, _ k: K) -> Double? {
        if let d = try? c.decodeIfPresent(Double.self, forKey: k) { return d }
        if let s = try? c.decodeIfPresent(String.self, forKey: k) { return Double(s) }
        return nil
    }
}

struct StreamItem: Decodable, Identifiable, Sendable {
    let name: String?
    let title: String?
    let description: String?
    let url: String?        // directly playable
    let infoHash: String?   // torrent: not playable on iOS without a debrid add-on
    let externalUrl: String?
    let behaviorHints: Hints?
    var id: String { url ?? infoHash ?? externalUrl ?? UUID().uuidString }
    var isPlayable: Bool { url != nil }

    /// Optional add-on hints. Some debrid add-ons require custom request headers to fetch the file.
    struct Hints: Decodable, Sendable {
        let filename: String?
        let proxyHeaders: ProxyHeaders?
        struct ProxyHeaders: Decodable, Sendable { let request: [String: String]? }
        enum K: String, CodingKey { case filename, proxyHeaders }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: K.self)
            filename = try? c.decode(String.self, forKey: .filename)
            proxyHeaders = try? c.decode(ProxyHeaders.self, forKey: .proxyHeaders)
        }
    }

    var requestHeaders: [String: String] { behaviorHints?.proxyHeaders?.request ?? [:] }
    var fileExtension: String {
        let f = behaviorHints?.filename ?? URL(string: url ?? "")?.lastPathComponent ?? ""
        return URL(fileURLWithPath: f).pathExtension.lowercased()
    }
    /// AVPlayer handles MP4/MOV/HLS; these containers usually fail.
    var likelyUnsupported: Bool { ["mkv", "avi", "wmv", "flv", "webm"].contains(fileExtension) }
}

/// Where a row came from, so its "See all" page knows how to load more.
enum CatalogSource: Hashable, Sendable {
    case none
    case tmdbTrending(String)                              // "movie" | "tv"
    case addon(Addon, AddonManifest.CatalogDef)
}

struct CatalogRow: Identifiable, Sendable, Hashable {
    let id: String
    let title: String
    let items: [MetaPreview]
    var source: CatalogSource = .none
    /// SF Symbol shown next to the row title on Home.
    var symbol: String? = nil

    // Identity only: rows are navigation values, not data to compare.
    static func == (a: CatalogRow, b: CatalogRow) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

private struct MetasResponse: Decodable { let metas: [MetaPreview] }
private struct StreamsResponse: Decodable { let streams: [StreamItem] }
extension MetaPreview { static func decodeList(_ d: Data) throws -> [MetaPreview] { try JSONDecoder().decode(MetasResponse.self, from: d).metas } }
extension StreamItem { static func decodeList(_ d: Data) throws -> [StreamItem] { try JSONDecoder().decode(StreamsResponse.self, from: d).streams } }
