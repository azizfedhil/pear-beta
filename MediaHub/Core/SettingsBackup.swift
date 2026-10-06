import SwiftUI
import UniformTypeIdentifiers

/// Export / import of app settings as a property-list file.
/// Includes API keys, add-on URLs, appearance, playback, subtitle style, profiles and pinned sources.
/// Optionally includes each profile's watch history and local library.
/// Not included: the Simkl login (reconnect after importing).
enum SettingsBackup {
    static let formatKey = "_pearBackupVersion"
    static let version = 1

    static let keys = [
        "addon.manifestURLs", "addon.prefs", "metadata.source", "aio.baseURL", "aio.apiKeyDefault", "tmdb.key", "tvdb.key", "tvdb.pin", "mdblist.key", "mdblist.lists", "simkl.clientID",
        "ui.accent", "ui.networkBadges", "ui.titleLogos", "player.glass", "player.autoplayNext",
        "skip.enabled", "skip.fallbackSeconds", "sub.lang", "sub.style", "subs.online", "subs.baseURL", "library.collapsed",
        "profiles.list", "profiles.active", "pinned.sources",
    ]
    /// Per-profile data: "watch.history" and "library.local", plus their ".<profile id>" variants.
    static let dataPrefixes = ["watch.history", "watch.archive", "watch.log", "library.local", "library.prefs"]

    enum Failure: LocalizedError {
        case unreadable, notBackup, newer
        var errorDescription: String? {
            switch self {
            case .unreadable: return "That file couldn't be read."
            case .notBackup: return "That isn't a Pear settings backup."
            case .newer: return "That backup was made by a newer version of the app."
            }
        }
    }

    static func export(includeData: Bool) throws -> Data {
        let all = UserDefaults.standard.dictionaryRepresentation()
        var out: [String: Any] = [formatKey: version]
        for (k, v) in all where isAllowed(k, includeData: includeData) { out[k] = v }
        return try PropertyListSerialization.data(fromPropertyList: out, format: .xml, options: 0)
    }

    /// Writes the file's settings into UserDefaults. Returns the number of values restored.
    static func restore(_ data: Data) throws -> Int {
        guard let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = obj as? [String: Any] else { throw Failure.unreadable }
        guard let v = dict[formatKey] as? Int else { throw Failure.notBackup }
        guard v <= version else { throw Failure.newer }
        var n = 0
        for (k, val) in dict where isAllowed(k, includeData: true) {
            UserDefaults.standard.set(val, forKey: k); n += 1
        }
        return n
    }

    private static func isAllowed(_ k: String, includeData: Bool) -> Bool {
        if keys.contains(k) { return true }
        // AIOMetadata adopts the API-key name its manifest declares ("aio.<name>"); back it up too.
        if k.hasPrefix("aio.") { return true }
        return includeData && dataPrefixes.contains { k == $0 || k.hasPrefix($0 + ".") }
    }
}

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.propertyList] }
    var data: Data
    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
