import SwiftUI

/// Every external service in one place: API keys, the Simkl login, and what each one is used for.
struct IntegrationsView: View {
    @Environment(SimklStore.self) private var simkl
    @AppStorage("simkl.clientID") private var simklID = ""
    @AppStorage("mdblist.key") private var mdbKey = ""
    @AppStorage("tvdb.key") private var tvdbKey = ""
    @AppStorage("tvdb.pin") private var tvdbPin = ""
    @AppStorage("tmdb.key") private var tmdbKey = ""
    @AppStorage("skip.enabled") private var skipEnabled = true

    var body: some View {
        Form {
            Section {
                SecureField("TMDB API key", text: $tmdbKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                status(tmdbKey.isEmpty ? nil : "Key set")
            } header: { Text("TMDB") } footer: {
                Text("Metadata, trending, Explore, recommendations, episode thumbnails, title logos and matching skip-intro timestamps. Free key at themoviedb.org/settings/api. This product uses the TMDB API but is not endorsed or certified by TMDB.")
            }

            Section {
                SecureField("TVDB API key", text: $tvdbKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("PIN (subscriber keys only)", text: $tvdbPin)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                status(tvdbKey.isEmpty ? nil : "Key set")
            } header: { Text("TheTVDB") } footer: {
                Text("Fills in missing episode thumbnails and title logos. Metadata provided by TheTVDB. Get a key at thetvdb.com/api-information.")
            }

            Section {
                SecureField("MDBList API key", text: $mdbKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                if !mdbKey.isEmpty { NavigationLink("Choose lists") { MDBListPicker() } }
                status(mdbKey.isEmpty ? nil : "Key set")
            } header: { Text("MDBList") } footer: {
                Text("IMDb, Rotten Tomatoes, Metacritic and Letterboxd ratings, and your lists on Home. Get a key at mdblist.com/preferences.")
            }

            simklSection

            Section {
                Toggle("Skip intro, recap and credits", isOn: $skipEnabled)
            } header: { Text("TheIntroDB") } footer: {
                Text("Community-verified timestamps for intros, recaps, credits and previews. No account or key needed; titles are matched through TMDB.")
            }
        }
        .navigationTitle("Integrations")
        .navigationBarTitleDisplayMode(.inline)
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

    @ViewBuilder private func status(_ text: String?) -> some View {
        if let text { Label(text, systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(.green) }
    }

    // MARK: Simkl (PIN / device-code login: no browser redirect, works inside LiveContainer)

    private var simklSection: some View {
        Section {
            if simkl.isConnected {
                Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                if let e = simkl.syncError {
                    Label(e, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange)
                }
                Button("Sync now") { Task { await simkl.sync(force: true) } }
                Button("Disconnect", role: .destructive) { simkl.disconnect() }
            } else {
                TextField("Simkl client ID", text: $simklID)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                if let pin = simkl.pin {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("1. Open this page on any device").font(.footnote).foregroundStyle(.secondary)
                        if let u = URL(string: pin.verificationUrl) {
                            Link(pin.verificationUrl, destination: u).font(.subheadline.weight(.semibold))
                        } else { Text(pin.verificationUrl).font(.subheadline.weight(.semibold)) }
                        Text("2. Enter this code").font(.footnote).foregroundStyle(.secondary)
                        HStack {
                            Text(pin.userCode).font(.system(size: 34, weight: .bold, design: .monospaced)).textSelection(.enabled)
                            Spacer()
                            Button { UIPasteboard.general.string = pin.userCode } label: { Image(systemName: "doc.on.doc") }
                                .buttonStyle(.borderless)
                        }
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(simkl.loginStatus ?? "Waiting for authorisation…").font(.footnote).foregroundStyle(.secondary)
                        }
                        Button("Cancel", role: .cancel) { simkl.cancelLogin() }.font(.footnote)
                    }
                    .padding(.vertical, 4)
                } else {
                    Button("Connect Simkl") { simkl.connect() }
                    if let s = simkl.loginStatus { Text(s).font(.footnote).foregroundStyle(.secondary) }
                }
                if let e = simkl.loginError { Label(e, systemImage: "xmark.octagon.fill").font(.footnote).foregroundStyle(.red) }
            }
        } header: { Text("Simkl") } footer: {
            Text("Sign-in uses a one-time code, so it works inside LiveContainer. Create a free app at simkl.com/settings/developer, paste its Client ID, tap Connect, then enter the code on the Simkl page. No redirect URL or secret is needed.")
        }
    }
}
