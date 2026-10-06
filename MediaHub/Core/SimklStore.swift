import Foundation
import Observation

/// Response of `POST /oauth2/device` (AUTH V2, RFC 8628). Decoded with `.convertFromSnakeCase`.
/// `deviceCode` is the polling credential: it is never shown, logged or put in a URL.
struct DeviceAuthorization: Decodable, Sendable {
    let deviceCode: String
    let userCode: String                    // shown exactly as returned, hyphen included ("BDWP-HQPK")
    let verificationUri: String             // "https://simkl.com/pin"
    let verificationUriComplete: String?    // same page with the code pre-filled
    let expiresIn: Int                      // 900
    let interval: Int?                      // 5

    var verificationUrl: String { verificationUri }
    var completeURL: URL? { verificationUriComplete.flatMap(URL.init(string:)) }
}

/// Token response of `POST /oauth2/token`, identical for the device, refresh and code grants.
private struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int?                     // always 604800 (7 days)
    let scope: String?                      // "media:read" or "media:read media:write"
}

/// RFC 6749 error envelope: branch on `error`, never on `errorDescription`.
private struct OAuthError: Decodable { let error: String; let errorDescription: String? }

/// Skips one malformed entry instead of failing the whole library.
private struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from d: Decoder) throws { value = try? T(from: d) }
}
private struct AllItems: Decodable {
    let movies: [Entry]; let shows: [Entry]; let anime: [Entry]
    enum K: String, CodingKey { case movies, shows, anime }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        func list(_ k: K) -> [Entry] { ((try? c.decodeIfPresent([Lossy<Entry>].self, forKey: k)) ?? []).compactMap(\.value) }
        movies = list(.movies); shows = list(.shows); anime = list(.anime)
    }
}
private struct Entry: Decodable {
    let status: String?; let movie: Media?; let show: Media?
    // ISO-8601 strings sort correctly as plain text, so no date parsing is needed to order by recency.
    let lastWatchedAt: String?; let addedToWatchlistAt: String?
    let watchedEpisodesCount: Int?; let totalEpisodesCount: Int?
    var activity: String { lastWatchedAt ?? addedToWatchlistAt ?? "" }
}
private struct Media: Decodable {
    let title: String; let year: Int?; let poster: String?; let ids: IDs
    struct IDs: Decodable {
        let imdb: String?; let tmdb: String?
        enum K: String, CodingKey { case imdb, tmdb }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: K.self)
            imdb = try? c.decode(String.self, forKey: .imdb)
            tmdb = (try? c.decode(String.self, forKey: .tmdb)) ?? (try? c.decode(Int.self, forKey: .tmdb)).map(String.init)
        }
    }
}

private enum SimklError: LocalizedError {
    case http(Int, String)
    case message(String)
    var errorDescription: String? {
        switch self {
        case .http(let code, let body): return "Simkl answered HTTP \(code)" + (body.isEmpty ? "." : ": \(body)")
        case .message(let m): return m
        }
    }
}

/// Episodes watched / in total for one Simkl show.
struct SimklEpisodeCount: Sendable { let watched: Int; let total: Int }

private enum PollResult { case tokens(TokenResponse), pending, slowDown, failed(String), transient }

/// Simkl AUTH V2 via the OAuth 2.0 device flow (RFC 8628): `POST /oauth2/device`, then poll `POST /oauth2/token`.
/// It needs only a client ID: no redirect URL, no client secret, no browser callback, so it works inside
/// LiveContainer where OAuth redirects can't return to the app.
///
/// V2 access tokens last 7 days; the refresh token (180 days, sliding) is kept in the Keychain and used
/// automatically, so the user is not sent back through the code screen.
///
/// Network use is event-driven: sync on foreground (max every 15 min) or pull-to-refresh, scrobble start/stop only.
@MainActor @Observable
final class SimklStore {
    private(set) var token: String? = Keychain.get("simkl.token")
    private(set) var library: [CatalogRow] = []
    /// Per-title episode counts from Simkl (id = IMDb or "tmdb:<id>", same as the library items). Feeds the profile statistics.
    private(set) var episodeCounts: [String: SimklEpisodeCount] = [:]
    private(set) var isSyncing = false
    private(set) var pin: DeviceAuthorization?
    private(set) var loginError: String?
    private(set) var loginStatus: String?
    private(set) var syncError: String?
    @ObservationIgnored private var lastSync: Date?
    @ObservationIgnored private var loginTask: Task<Void, Never>?
    @ObservationIgnored private var refreshToken: String? = Keychain.get("simkl.refresh")
    @ObservationIgnored private var tokenExpiry: Date? = UserDefaults.standard.object(forKey: "simkl.tokenExpiry") as? Date
    /// One refresh at a time: V2 refreshing replaces the access token, so two overlapping refreshes would
    /// invalidate each other.
    @ObservationIgnored private var refreshTask: Task<Bool, Never>?
    private static let expiryKey = "simkl.tokenExpiry"

    var isConnected: Bool { token != nil }
    /// Trimmed: a pasted ID with a trailing space or newline is the most common reason a login "does nothing".
    private var clientID: String {
        (UserDefaults.standard.string(forKey: "simkl.clientID") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: HTTP

    private static let appName = "mediahub"
    private static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    private static var userAgent: String { "MediaHub/\(appVersion)" }

    /// Every Simkl API call carries `client_id`, `app-name` and `app-version` as URL parameters plus a User-Agent.
    private func request(_ path: String, query: [String: String] = [:], method: String = "GET",
                         body: [String: Any]? = nil, auth: Bool = true) -> URLRequest {
        var c = URLComponents(string: "https://api.simkl.com" + path)!
        c.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } + [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "app-name", value: Self.appName),
            URLQueryItem(name: "app-version", value: Self.appVersion),
        ]
        var r = URLRequest(url: c.url!)
        r.httpMethod = method
        r.timeoutInterval = 20
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if auth, let t = token { r.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        if let body { r.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        return r
    }

    private static func snippet(_ d: Data) -> String {
        String((String(data: d, encoding: .utf8) ?? "").prefix(160)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func send<T: Decodable>(_ r: URLRequest) async throws -> T {
        let (d, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw SimklError.http(code, Self.snippet(d)) }
        let dec = JSONDecoder(); dec.keyDecodingStrategy = .convertFromSnakeCase
        return try dec.decode(T.self, from: d)
    }

    /// OAuth endpoints take a form-encoded body and no Authorization header.
    private func oauthRequest(_ path: String, form: [String: String]) -> URLRequest {
        var r = URLRequest(url: URL(string: "https://api.simkl.com" + path)!)
        r.httpMethod = "POST"
        r.timeoutInterval = 20
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        r.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: safe) ?? $0.value)" }
            .joined(separator: "&").data(using: .utf8)
        return r
    }

    private static func status(_ resp: URLResponse) -> Int { (resp as? HTTPURLResponse)?.statusCode ?? 0 }

    /// Authenticated call: refreshes a token that is about to expire first, and on a 401 refreshes once and retries.
    private func sendAuthed<T: Decodable>(_ make: () -> URLRequest) async throws -> T {
        await refreshIfNeeded()
        do { return try await send(make()) }
        catch SimklError.http(let code, let body) where code == 401 {
            guard await refreshIfNeeded(force: true) else { throw SimklError.http(code, body) }
            return try await send(make())
        }
    }

    // MARK: Device login (AUTH V2)

    /// 1. POST /oauth2/device (client_id, scope)  2. show user_code + verification_uri  3. poll POST /oauth2/token
    /// every `interval` seconds  4. on tokens: store them  5. stop at `expires_in` (declining is never signalled).
    func connect() {
        loginTask?.cancel()
        loginError = nil; loginStatus = nil; pin = nil
        let cid = clientID
        guard !cid.isEmpty else { loginError = "Enter your Simkl client ID first."; return }
        loginTask = Task { await runDeviceFlow(clientID: cid) }
    }

    func cancelLogin() {
        loginTask?.cancel(); pin = nil; loginStatus = nil
    }

    private func requestDeviceCode(clientID cid: String) async throws -> DeviceAuthorization {
        // media:write is needed for scrobbling and Add to Watchlist; omitting scope would give a read-only token.
        let r = oauthRequest("/oauth2/device", form: ["client_id": cid, "scope": "media:read media:write"])
        let (d, resp) = try await URLSession.shared.data(for: r)
        let code = Self.status(resp)
        let dec = JSONDecoder(); dec.keyDecodingStrategy = .convertFromSnakeCase
        if code == 200 { return try dec.decode(DeviceAuthorization.self, from: d) }
        let e = try? dec.decode(OAuthError.self, from: d)
        if e?.error == "invalid_client" {
            throw SimklError.message("Simkl doesn't accept this client ID for the device flow. It must belong to an AUTH V2 app (simkl.com/settings/developer).")
        }
        throw SimklError.http(code, e?.errorDescription ?? Self.snippet(d))
    }

    private func runDeviceFlow(clientID cid: String) async {
        do {
            loginStatus = "Requesting a code…"
            let p = try await requestDeviceCode(clientID: cid)
            pin = p
            loginStatus = "Open the page below and enter the code."
            let deadline = Date().addingTimeInterval(Double(p.expiresIn))
            var wait = max(p.interval ?? 5, 1)          // never faster than the interval Simkl asked for
            var failures = 0
            while Date() < deadline {
                try await Task.sleep(for: .seconds(wait))
                try Task.checkCancellation()
                switch await poll(deviceCode: p.deviceCode, clientID: cid) {
                case .tokens(let t):
                    storeTokens(t)
                    pin = nil; loginStatus = nil; loginError = nil
                    await sync(force: true)
                    if let s = t.scope, !s.contains("media:write") {
                        syncError = "Connected read-only: scrobbling and Add to Watchlist need the media:write permission."
                    }
                    return
                case .pending:
                    failures = 0
                case .slowDown:
                    wait += 5                           // Simkl asks for +5 s; the sleep above is the wait itself
                    failures = 0
                case .failed(let m):
                    pin = nil; loginStatus = nil; loginError = m
                    return
                case .transient:
                    failures += 1
                    if failures >= 6 { pin = nil; loginStatus = nil; loginError = "Lost the connection to Simkl. Try again."; return }
                }
            }
            pin = nil; loginStatus = nil
            loginError = "The code expired. Tap Connect to get a new one."
        } catch is CancellationError {
            pin = nil; loginStatus = nil
        } catch {
            pin = nil; loginStatus = nil
            loginError = error.localizedDescription
        }
    }

    private func poll(deviceCode: String, clientID cid: String) async -> PollResult {
        let r = oauthRequest("/oauth2/token", form: [
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            "client_id": cid,
            "device_code": deviceCode,
        ])
        guard let (d, resp) = try? await URLSession.shared.data(for: r) else { return .transient }
        let status = Self.status(resp)
        if status == 429 { return .slowDown }
        if status >= 500 { return .transient }
        let dec = JSONDecoder(); dec.keyDecodingStrategy = .convertFromSnakeCase
        if status == 200 {
            guard let t = try? dec.decode(TokenResponse.self, from: d), !t.accessToken.isEmpty else {
                return .failed("Simkl sent a sign-in response the app couldn't read.")
            }
            return .tokens(t)
        }
        // Declining on the approval page is never signalled: it looks like "pending" until the code expires.
        switch (try? dec.decode(OAuthError.self, from: d))?.error {
        case "authorization_pending": return .pending
        case "slow_down": return .slowDown
        case "expired_token": return .failed("The code expired. Tap Connect to get a new one.")
        case "invalid_client":
            return .failed("Simkl rejected the client ID. It must belong to an AUTH V2 app (simkl.com/settings/developer).")
        default: return .failed("Simkl answered HTTP \(status): \(Self.snippet(d))")
        }
    }

    // MARK: Tokens (7-day access token, 180-day non-rotating refresh token)

    private func storeTokens(_ t: TokenResponse) {
        token = t.accessToken
        Keychain.set(t.accessToken, "simkl.token")
        if let r = t.refreshToken, !r.isEmpty { refreshToken = r; Keychain.set(r, "simkl.refresh") }
        let exp = Date().addingTimeInterval(Double(t.expiresIn ?? 604_800))
        tokenExpiry = exp
        UserDefaults.standard.set(exp, forKey: Self.expiryKey)
    }

    /// Refreshes when the access token is within a day of expiring (or `force`, after a 401).
    /// Returns whether a usable token is held afterwards.
    @discardableResult
    private func refreshIfNeeded(force: Bool = false) async -> Bool {
        guard isConnected else { return false }
        guard let rt = refreshToken else { return !force }          // token from before V2 has no refresh token
        if !force {
            guard let exp = tokenExpiry, exp.timeIntervalSinceNow < 86_400 else { return true }
        }
        if let running = refreshTask { return await running.value }
        let cid = clientID
        let task = Task { await performRefresh(rt, clientID: cid) }
        refreshTask = task
        let ok = await task.value
        refreshTask = nil
        return ok
    }

    private func performRefresh(_ rt: String, clientID cid: String) async -> Bool {
        let r = oauthRequest("/oauth2/token", form: ["grant_type": "refresh_token", "client_id": cid, "refresh_token": rt])
        guard let (d, resp) = try? await URLSession.shared.data(for: r) else { return false }   // offline: keep what we have
        let status = Self.status(resp)
        let dec = JSONDecoder(); dec.keyDecodingStrategy = .convertFromSnakeCase
        if status == 200, let t = try? dec.decode(TokenResponse.self, from: d), !t.accessToken.isEmpty {
            storeTokens(t)
            return true
        }
        if status == 400 || status == 401 {
            // Grant revoked or refresh token past its 180 days: only a new sign-in helps.
            syncError = "Simkl login expired. Disconnect and connect again."
        }
        return false
    }

    func disconnect() {
        loginTask?.cancel(); pin = nil; library = []; episodeCounts = [:]; loginStatus = nil; syncError = nil
        // Revoking either token ends the whole grant. Fire and forget: the endpoint always answers 200.
        if let rt = refreshToken {
            let r = oauthRequest("/oauth2/revoke", form: ["client_id": clientID, "token": rt])
            Task { _ = try? await URLSession.shared.data(for: r) }
        }
        token = nil; refreshToken = nil; tokenExpiry = nil
        Keychain.remove("simkl.token"); Keychain.remove("simkl.refresh")
        UserDefaults.standard.removeObject(forKey: Self.expiryKey)
    }

    // MARK: Library

    func sync(force: Bool = false) async {
        guard isConnected, !isSyncing else { return }
        if !force, let l = lastSync, Date().timeIntervalSince(l) < 900 { return }
        isSyncing = true; defer { isSyncing = false }
        let all: AllItems
        do { all = try await sendAuthed { request("/sync/all-items/") } }
        catch {
            if case SimklError.http(let c, _) = error, c == 401 || c == 403 {
                syncError = "Simkl rejected the saved login. Disconnect and connect again."
            } else { syncError = error.localizedDescription }
            return
        }
        syncError = nil
        lastSync = .now
        let entries = all.movies + all.shows + all.anime
        func items(_ status: String) -> [MetaPreview] {
            entries.filter { $0.status == status }.sorted { $0.activity > $1.activity }.compactMap { e in
                guard let m = e.movie ?? e.show,
                      let id = m.ids.imdb ?? m.ids.tmdb.map({ "tmdb:\($0)" }) else { return nil }
                return MetaPreview(id: id, type: e.movie != nil ? "movie" : "series", name: m.title,
                    poster: m.poster.map { "https://simkl.in/posters/\($0)_m.jpg" }, background: nil,
                    logo: nil, description: nil, releaseInfo: m.year.map(String.init))
            }
        }
        var counts: [String: SimklEpisodeCount] = [:]
        for e in entries {
            guard let m = e.show, let id = m.ids.imdb ?? m.ids.tmdb.map({ "tmdb:\($0)" }) else { continue }
            counts[id] = SimklEpisodeCount(watched: e.watchedEpisodesCount ?? 0, total: e.totalEpisodesCount ?? 0)
        }
        episodeCounts = counts
        let sections: [(String, String, String)] = [("watching", "Watching", "eye.fill"),
                                                    ("plantowatch", "Plan to Watch", "bookmark.fill"),
                                                    ("completed", "Completed", "checkmark.circle.fill")]
        library = sections.compactMap { s, t, sym in
            let i = items(s)
            return i.isEmpty ? nil : CatalogRow(id: "simkl-\(s)", title: t, items: i, symbol: sym)
        }
    }

    func addToWatchlist(_ imdb: String, type: String) async {
        let body: [String: Any] = [type == "series" ? "shows" : "movies": [["to": "plantowatch", "ids": ["imdb": imdb]]]]
        await refreshIfNeeded()
        _ = try? await URLSession.shared.data(for: request("/sync/add-to-list", method: "POST", body: body))
        await sync(force: true)
    }

    /// Adds many titles to Simkl lists in one request (library sync). Returns whether Simkl accepted it.
    func add(_ items: [SimklListAdd]) async -> Bool {
        guard isConnected else { return false }
        guard !items.isEmpty else { return true }
        func entry(_ i: SimklListAdd) -> [String: Any] {
            var ids: [String: Any] = [:]
            if let imdb = i.imdb { ids["imdb"] = imdb }
            if let tmdb = i.tmdb { ids["tmdb"] = tmdb }
            return ["to": i.list, "ids": ids]
        }
        var body: [String: Any] = [:]
        let movies = items.filter { $0.isMovie }.map(entry)
        let shows = items.filter { !$0.isMovie }.map(entry)
        if !movies.isEmpty { body["movies"] = movies }
        if !shows.isEmpty { body["shows"] = shows }
        await refreshIfNeeded()
        guard let (_, resp) = try? await URLSession.shared.data(for: request("/sync/add-to-list", method: "POST", body: body)) else { return false }
        return (200..<300).contains(Self.status(resp))
    }

    // MARK: Scrobble (start on play, stop on close; Simkl marks watched at >= 80%)
    func scrobble(_ action: String, _ r: PlayRequest, progress: Double) {
        guard isConnected else { return }
        var body: [String: Any] = ["progress": progress]
        if let s = r.season, let e = r.episode {
            body["show"] = ["ids": ["imdb": r.imdb]]; body["episode"] = ["season": s, "number": e]
        } else { body["movie"] = ["ids": ["imdb": r.imdb]] }
        Task {
            await refreshIfNeeded()
            _ = try? await URLSession.shared.data(for: request("/scrobble/\(action)", method: "POST", body: body))
        }
    }
}
