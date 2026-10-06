import Foundation

/// One shared, cache-aware client. HTTP caching (ETag / Cache-Control) is honored by URLCache,
/// so repeat launches don't refetch catalogs the add-on says are still fresh.
actor AddonClient {
    static let shared = AddonClient()
    private let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = URLCache(memoryCapacity: 20 << 20, diskCapacity: 150 << 20)
        cfg.requestCachePolicy = .useProtocolCachePolicy
        cfg.timeoutIntervalForRequest = 12
        cfg.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: cfg)
    }

    private func data(_ url: URL, fresh: Bool = false) async throws -> Data {
        var req = URLRequest(url: url)
        if fresh { req.cachePolicy = .reloadIgnoringLocalCacheData }
        let (d, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return d
    }

    func manifest(at url: URL, fresh: Bool = false) async throws -> AddonManifest {
        try JSONDecoder().decode(AddonManifest.self, from: try await data(url, fresh: fresh))
    }

    /// Drops every cached catalog / manifest response, so the next fetch goes to the network.
    func clearCache() { session.configuration.urlCache?.removeAllCachedResponses() }

    /// `skip` pages through add-ons that declare it; `search` queries add-ons that declare it.
    func catalog(addon: Addon, catalog: AddonManifest.CatalogDef, skip: Int = 0, search: String? = nil) async throws -> [MetaPreview] {
        var extras: [String] = []
        if let q = search?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty {
            let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            extras.append("search=" + (q.addingPercentEncoding(withAllowedCharacters: safe) ?? q))
        }
        if skip > 0 { extras.append("skip=\(skip)") }
        var path = "catalog/\(catalog.type)/\(catalog.id)"
        if !extras.isEmpty { path += "/" + extras.joined(separator: "&") }
        // Built as a string: appendingPathComponent would double-encode the % escapes.
        guard let url = URL(string: addon.baseURL.absoluteString + path + ".json") else { throw URLError(.badURL) }
        return try MetaPreview.decodeList(try await data(url))
    }

    /// Fans out only to add-ons that declare the `stream` resource for this type/id.
    func streams(for id: String, type: String, addons: [Addon]) async -> [(Addon, [StreamItem])] {
        await withTaskGroup(of: (Addon, [StreamItem])?.self) { group in
            for addon in addons where addon.provides("stream", type: type, id: id) {
                group.addTask {
                    let url = addon.baseURL.appendingPathComponent("stream/\(type)/\(id).json")
                    guard let d = try? await self.data(url),
                          let s = try? StreamItem.decodeList(d) else { return nil }
                    return (addon, s)
                }
            }
            var out: [(Addon, [StreamItem])] = []
            for await r in group { if let r { out.append(r) } }
            return out
        }
    }
}
