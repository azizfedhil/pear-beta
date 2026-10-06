import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AddonStore.self) private var store
    @Environment(SimklStore.self) private var simkl
    @Environment(ThemeStore.self) private var theme
    @Environment(ProfileStore.self) private var profiles
    @Environment(WatchHistory.self) private var history
    @Environment(LocalLibrary.self) private var library
    @Environment(LibraryPrefs.self) private var libraryPrefs
    @Environment(WatchLog.self) private var watchLog
    @Environment(PinnedSources.self) private var pins
    @AppStorage("tmdb.key") private var tmdbKey = ""
    @AppStorage("tvdb.key") private var tvdbKey = ""
    @AppStorage("mdblist.key") private var mdbKey = ""
    @AppStorage("ui.networkBadges") private var networkBadges = true
    @AppStorage("ui.titleLogos") private var titleLogos = true
    @AppStorage("player.glass") private var glass = true
    @AppStorage("player.autoplayNext") private var autoplayNext = true
    @AppStorage("skip.enabled") private var skipEnabled = true
    @AppStorage("skip.fallbackSeconds") private var fallbackSkip = 85
    @AppStorage("sub.lang") private var subLang = "off"
    @State private var urlText = ""
    @State private var error: String?
    @State private var busy = false
    @State private var reloading = Set<String>()
    @State private var reloadNote: String?
    @State private var includeData = false
    @State private var exportDoc: BackupDocument?
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var backupNote: String?

    private var connected: Int {
        [!tmdbKey.isEmpty, !tvdbKey.isEmpty, !mdbKey.isEmpty, simkl.isConnected].filter { $0 }.count
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink { IntegrationsView() } label: {
                        HStack {
                            Label("Integrations", systemImage: "puzzlepiece.extension.fill")
                            Spacer()
                            Text("\(connected) of 4 set up").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("TMDB, TheTVDB, MDBList and Simkl: API keys, logins and metadata sources.")
                }

                Section {
                    LibrarySourceControls()
                } header: { Text("Library · \(profiles.active.name)") } footer: {
                    Text("Chosen per profile. A library on this device keeps its own watch history and watch time and never contacts Simkl. Syncing merges both libraries without deleting anything on either side.")
                }

                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Accent colour").font(.subheadline.weight(.medium))
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 40), spacing: 12)], spacing: 12) {
                            ForEach(Theme.presets, id: \.hex) { p in
                                Button { theme.setAccent(hex: p.hex) } label: {
                                    Circle().fill(Color(hex: p.hex) ?? .gray).frame(width: 36, height: 36)
                                        .overlay {
                                            if theme.hex.uppercased() == p.hex {
                                                Image(systemName: "checkmark").font(.footnote.weight(.black)).foregroundStyle(.white)
                                            }
                                        }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(p.name)
                            }
                        }
                        ColorPicker("Custom colour", selection: Binding(get: { theme.accent },
                                                                          set: { theme.setAccent(hex: $0.hexString) }),
                                    supportsOpacity: false)
                    }
                    .padding(.vertical, 4)
                    Toggle("Network icons on posters", isOn: $networkBadges)
                    Toggle("Logos instead of title text", isOn: $titleLogos)
                } header: { Text("Appearance") } footer: {
                    Text("Network icons need a TMDB key and make one small request per visible poster. Logos come from TMDB, TheTVDB and Metahub and are cached after the first lookup.")
                }

                Section {
                    NavigationLink {
                        SubtitleSettingsView()
                    } label: {
                        HStack {
                            Label("Subtitles", systemImage: "captions.bubble")
                            Spacer()
                            Text(subLang == "off" ? "Off" : (SubLanguages.all.first { $0.code == subLang }?.name ?? subLang))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Toggle("Liquid Glass controls", isOn: $glass)
                    Toggle("Autoplay next episode", isOn: $autoplayNext)
                    Toggle("Skip intro / recap / credits", isOn: $skipEnabled)
                    if skipEnabled {
                        Stepper(fallbackSkip == 0 ? "Manual skip button: off" : "Manual skip button: \(fallbackSkip) s",
                                value: $fallbackSkip, in: 0...180, step: 5)
                    }
                } header: { Text("Playback") } footer: {
                    Text("Skip buttons use community timestamps from TheIntroDB. When a show has none, the manual button jumps ahead by the chosen time. Set it to 0 to hide it. Turn Liquid Glass off if playback ever feels heavy on an older device.")
                }

                Section {
                    Toggle("Include watch history & library", isOn: $includeData)
                    Button { export() } label: { Label("Export settings", systemImage: "square.and.arrow.up") }
                    Button { showImporter = true } label: { Label("Import settings", systemImage: "square.and.arrow.down") }
                    if let backupNote { Text(backupNote).font(.footnote).foregroundStyle(.secondary) }
                } header: { Text("Backup") } footer: {
                    Text("The file contains your API keys and add-on URLs, so keep it private. The Simkl login isn't included; reconnect it after importing.")
                }

                Section("Add-ons") {
                    ForEach(store.addons) { a in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(a.manifest.name).font(.headline)
                                if let d = a.manifest.description { Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                            }
                            Spacer()
                            if reloading.contains(a.id) { ProgressView() }
                        }
                        .swipeActions(edge: .leading) {
                            Button { reload(a) } label: { Label("Reload", systemImage: "arrow.clockwise") }.tint(.blue)
                        }
                        .contextMenu {
                            Button { reload(a) } label: { Label("Reload", systemImage: "arrow.clockwise") }
                        }
                    }
                    .onDelete { store.remove(at: $0) }
                    if !store.addons.isEmpty {
                        Button {
                            Task {
                                reloading = Set(store.addons.map(\.id))
                                let failed = await store.reloadAll()
                                reloading = []
                                reloadNote = failed == 0 ? "Add-ons reloaded." : "\(failed) add-on(s) couldn't be reached and were left as they were."
                            }
                        } label: { Label("Reload all add-ons", systemImage: "arrow.clockwise") }
                            .disabled(!reloading.isEmpty)
                    }
                    if let reloadNote { Text(reloadNote).font(.footnote).foregroundStyle(.secondary) }
                }
                Section {
                    TextField("Add-on URL", text: $urlText)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    Button(busy ? "Adding…" : "Add add-on") {
                        Task {
                            busy = true; defer { busy = false }
                            do { try await store.add(urlText); urlText = ""; error = nil }
                            catch { self.error = "Couldn't load that manifest. Check the URL and try again." }
                        }
                    }
                    .disabled(urlText.isEmpty || busy)
                } footer: {
                    if let error { Text(error).foregroundStyle(.red) }
                }
            }
            .fileExporter(isPresented: $showExporter, document: exportDoc ?? BackupDocument(),
                          contentType: .propertyList, defaultFilename: "Pear-Settings") { r in
                if case .failure = r { backupNote = "Export failed." } else { backupNote = "Settings exported." }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.propertyList]) { r in
                importSettings(r)
            }
            .navigationTitle("Settings")
            .profileToolbar()
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                }
            }
        }
    }

    private func reload(_ a: Addon) {
        reloading.insert(a.id)
        Task {
            defer { reloading.remove(a.id) }
            do { try await store.reload(a); reloadNote = "\(a.manifest.name) reloaded." }
            catch { reloadNote = "Couldn't reach \(a.manifest.name)." }
        }
    }

    private func export() {
        do {
            exportDoc = BackupDocument(data: try SettingsBackup.export(includeData: includeData))
            showExporter = true
        } catch { backupNote = "Export failed." }
    }

    private func importSettings(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let n = try SettingsBackup.restore(try Data(contentsOf: url))
            theme.reload(); profiles.reload(); history.reload(); library.reload(); watchLog.reload(); pins.reload(); libraryPrefs.reload()
            Task { await store.reloadFromDefaults() }
            backupNote = "Imported \(n) settings."
        } catch {
            backupNote = (error as? LocalizedError)?.errorDescription ?? "Import failed."
        }
    }
}
