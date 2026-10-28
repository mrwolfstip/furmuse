import SwiftUI
import UniformTypeIdentifiers

struct SettingsRow: View {
    let title: String
    let icon: String
    var value: String = ""

    var body: some View {
        HStack {
            Image(systemName: icon).frame(width: 26).foregroundColor(.accentColor)
            Text(title)
            Spacer()
            if !value.isEmpty { Text(value).foregroundColor(.secondary).lineLimit(1) }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var auth: SpotifyAuth
    @EnvironmentObject var lastfm: LastfmClient
    @ObservedObject private var google = GoogleYouTubeAuth.shared
    @Environment(\.colorScheme) private var system

    private var accountvalue: String {
        let count = [auth.connected, google.connected, lastfm.loggedin].filter { $0 }.count
        return count == 0 ? "none connected" : "\(count) of 3 connected"
    }

    var body: some View {
        List {
            Section {
                NavigationLink(destination: AccountsSettingsView()) {
                    SettingsRow(title: "accounts", icon: "person.crop.circle", value: accountvalue)
                }
            }
            Section(header: Text("listening")) {
                NavigationLink(destination: EffectsSettingsView()) { SettingsRow(title: "sound effects", icon: "slider.vertical.3", value: settings.eqon || settings.reverbon || settings.bass > 0 || settings.pitchsemis != 0 ? "on" : "off") }
                NavigationLink(destination: LyricsSettingsView()) { SettingsRow(title: "lyrics", icon: "text.alignleft", value: settings.lyricson ? "on" : "off") }
            }
            Section(header: Text("music")) {
                NavigationLink(destination: SourceSettingsView()) { SettingsRow(title: "where songs play from", icon: "waveform", value: settings.defaultsource) }
                NavigationLink(destination: PlayersSettingsView()) {
                    SettingsRow(title: "players", icon: "play.circle", value: "spotify & youtube")
                }
                NavigationLink(destination: DownloadsSettingsView()) { SettingsRow(title: "downloads", icon: "arrow.down.circle") }
            }
            Section(header: Text("library")) {
                NavigationLink(destination: LibrarySettingsView()) { SettingsRow(title: "library & backup", icon: "books.vertical") }
                NavigationLink(destination: AppleCoversSettingsView()) { SettingsRow(title: "animated covers", icon: "sparkles.tv") }
            }
            Section(header: Text("app")) {
                NavigationLink(destination: AppearanceSettingsView()) { SettingsRow(title: "appearance", icon: "paintpalette") }
                NavigationLink(destination: AdvancedSettingsView()) { SettingsRow(title: "more", icon: "ellipsis.circle") }
            }
            Section {
                Text("made sloppily to satisfy my own quirk - @mrwolfstip")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .listRowBackground(Color.clear)
        }
        .listStyle(.insetGrouped)
        .themed()
        .navigationTitle("settings")
        .navigationBarTitleDisplayMode(.large)
    }
}

struct AccountsSettingsView: View {
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("account", selection: $tab) {
                Text("spotify").tag(0)
                Text("google").tag(1)
                Text("last.fm").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16).padding(.vertical, 10)
            if tab == 0 { SpotifySettingsView() }
            else if tab == 1 { GoogleAccountSettingsView() }
            else { LastfmSettingsView() }
        }
        .themed().navigationTitle("accounts").navigationBarTitleDisplayMode(.inline)
    }
}

struct GoogleAccountSettingsView: View {
    @ObservedObject private var auth = GoogleYouTubeAuth.shared
    @State private var signingIn = false
    @State private var testing = false
    @State private var result: String?

    var body: some View {
        Form {
            Section(header: Text("youtube music"), footer: Text("Your YouTube session is stored securely in the iOS Keychain and is only used by Advanced YouTube.")) {
                Label(auth.connected ? "Google account connected" : "not connected", systemImage: auth.connected ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(auth.connected ? .green : .orange)
                if auth.connected {
                    Button(testing ? "testing…" : "test connection") {
                        testing = true; result = nil
                        Task {
                            do {
                                guard let song = await AdvancedYouTubeClient.search("Never Gonna Give You Up Rick Astley", limit: 5).first else {
                                    throw ResolveError.unavailable("YouTube Music search returned no songs")
                                }
                                _ = try await AdvancedYouTubeClient.stream(videoID: song.id)
                                result = "YouTube Music audio is available."
                            } catch { result = (error as? ResolveError)?.text ?? error.localizedDescription }
                            testing = false
                        }
                    }.disabled(testing)
                    Button("sign out", role: .destructive) { auth.disconnect(); result = nil }
                } else {
                    Button("sign in with Google") { signingIn = true }
                }
                if let error = auth.lastError { Text(error).font(.footnote).foregroundColor(.orange) }
                if let result { Text(result).font(.footnote).foregroundColor(.secondary) }
            }
        }
        .sheet(isPresented: $signingIn) { GoogleYouTubeSignInView() }
    }
}

struct PlayersSettingsView: View {
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("player", selection: $tab) {
                Text("spotify").tag(0)
                Text("youtube").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16).padding(.vertical, 10)
            if tab == 0 { SpotifyPlayerSettingsView() }
            else { YouTubePlayerSettingsView() }
        }
        .themed().navigationTitle("players").navigationBarTitleDisplayMode(.inline)
    }
}

struct SpicyLyricsSettingsView: View {
    @EnvironmentObject var settings: Settings
    @State private var key = ""
    @State private var reveal = false
    @State private var testing = false
    @State private var result: String?

    var body: some View {
        Form {
            Section(header: Text("api key"), footer: Text("create an application at developers.spicylyrics.org/dashboard/applications. keys are shown once, so copy yours before leaving. secret keys are simplest; publishable keys need ‘no origin header’ enabled for a native app.")) {
                Link("open spicy lyrics dashboard", destination: URL(string: "https://developers.spicylyrics.org/dashboard/applications")!)
                if reveal { TextField("sl_sk_ or sl_pk_", text: $key).autocapitalization(.none).disableAutocorrection(true) }
                else { SecureField("sl_sk_ or sl_pk_", text: $key).autocapitalization(.none).disableAutocorrection(true) }
                Toggle("show key", isOn: $reveal)
                Button("save key") {
                    let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard value.hasPrefix("sl_sk_") || value.hasPrefix("sl_pk_") else { result = "that doesn't look like a spicy lyrics key"; return }
                    SpicyLyrics.shared.savekey(value); key = ""; result = "saved"
                }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(testing ? "testing…" : "test key") {
                    testing = true; result = nil
                    Task { @MainActor in result = await SpicyLyrics.shared.testkey(); testing = false }
                }.disabled(testing || !SpicyLyrics.shared.haskey)
                if SpicyLyrics.shared.haskey { Button("remove key", role: .destructive) { SpicyLyrics.shared.removekey(); result = "removed" } }
                if let result { Text(result).font(.footnote).foregroundColor(.secondary) }
            }
            Section(header: Text("accept results from"), footer: Text("the api chooses the source. if its result is turned off here, furmuse tries the next lyrics provider.")) {
                Toggle("community syncs", isOn: $settings.spicycommunity)
                Toggle("apple music", isOn: $settings.spicyapple)
                Toggle("spotify", isOn: $settings.spicyspotify)
            }
        }
        .themed().navigationTitle("spicy lyrics").navigationBarTitleDisplayMode(.inline)
    }
}

struct AppearanceSettingsView: View {
    @EnvironmentObject var settings: Settings

    var body: some View {
        Form {
            Section(header: Text("theme")) {
                Picker("theme", selection: $settings.thememode) {
                    Text("system").tag("system"); Text("light").tag("light"); Text("dark").tag("dark"); Text("black").tag("amoled")
                }
            }
            Section(header: Text("lock screen"), footer: Text("needs ios 26. some phone settings turn animations off.")) {
                Toggle("animate lock screen covers", isOn: $settings.animatestatic)
                Toggle("show current lyric as artist", isOn: $settings.lockscreenlyrics)
            }
            if settings.legacyiconunlocked {
                Section(header: Text("secret icon"), footer: Text("unlocked by finding the hidden phrase in your library.")) {
                    Toggle("use the original wolf icon", isOn: Binding(
                        get: { UIApplication.shared.alternateIconName == "LegacyIcon" },
                        set: { enabled in
                            guard UIApplication.shared.supportsAlternateIcons else {
                                ToastCenter.shared.show("alternate icons aren't supported on this device")
                                return
                            }
                            UIApplication.shared.setAlternateIconName(enabled ? "LegacyIcon" : nil) { error in
                                if let error { DispatchQueue.main.async { ToastCenter.shared.show("couldn't change icon: \(error.localizedDescription)") } }
                            }
                        }
                    ))
                }
            }
        }
        .themed().navigationTitle("appearance").navigationBarTitleDisplayMode(.inline)
    }
}

struct EffectsSettingsView: View {
    @EnvironmentObject var settings: Settings
    private let eqlabels = ["deep", "bass", "mid", "treble", "high"]

    private func eqbinding(_ i: Int) -> Binding<Double> {
        Binding(get: { settings.eq[i] }, set: { v in var e = settings.eq; e[i] = v; settings.eq = e })
    }

    var body: some View {
        Form {
            Section(footer: Text("equalizer, bass and reverb switch spotify to \"with effects\" mode.")) {
                Stepper("pitch \(settings.pitchsemis > 0 ? "+" : "")\(settings.pitchsemis)", value: $settings.pitchsemis, in: -12...12)
                Toggle("equalizer", isOn: $settings.eqon)
                if settings.eqon {
                    ForEach(0..<5, id: \.self) { i in
                        HStack { Text(eqlabels[i]).frame(width: 60, alignment: .leading); Slider(value: eqbinding(i), in: -12...12, step: 1) }
                    }
                }
                HStack { Text("bass boost"); Slider(value: $settings.bass, in: 0...12, step: 1) }
                Toggle("reverb", isOn: $settings.reverbon)
                if settings.reverbon {
                    Picker("room", selection: $settings.reverbpreset) { ForEach(reverbnames.indices, id: \.self) { Text(reverbnames[$0]).tag($0) } }
                    HStack { Text("amount"); Slider(value: $settings.reverbmix, in: 0...100, step: 5) }
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: settings.eqon)
        .animation(.easeInOut(duration: 0.25), value: settings.reverbon)
        .onChange(of: settings.eqon) { if $0 { settings.backend = .librespot } }
        .onChange(of: settings.bass) { if $0 != 0 { settings.backend = .librespot } }
        .onChange(of: settings.reverbon) { if $0 { settings.backend = .librespot } }
        .themed().navigationTitle("sound effects").navigationBarTitleDisplayMode(.inline)
    }
}

struct SourceSettingsView: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var resolver: ResolverManager
    @EnvironmentObject var auth: SpotifyAuth
    // the first thing that stops spotify playback with the backend that is selected
    private var spotifyblocker: String? {
        settings.backend == .webplayback ? WebPlaybackSession.shared.blocker() : LibrespotSession.shared.blocker(auth: auth)
    }

    var body: some View {
        Form {
            Section(header: Text("play songs from"), footer: Text("downloads and files you attached always play first.")) {
                Picker("default", selection: $settings.defaultsource) {
                    Text("youtube").tag("youtube")
                    Text("spotify").tag("spotify")
                    Text("files & downloads").tag("local")
                }
                if settings.defaultsource == "spotify", let why = spotifyblocker {
                    Text("spotify isn't ready: \(why)").font(.footnote).foregroundColor(.orange)
                }
            }
            Section(footer: Text("pick the right youtube video yourself when you play from search.")) {
                Toggle("ask me to pick the video", isOn: $settings.askforsource)
            }
            Section(header: Text("youtube lookup")) {
                Picker("use", selection: $settings.sourceorder) {
                    Text("youtube").tag("youtube")
                    Text("my own server").tag("endpoint")
                    Text("my server, then youtube").tag("endpointfirst")
                }
                KeyValue(key: "youtube", value: settings.youtubebackend == .advanced ? (resolver.advancedyoutubeavailable ? "authenticated" : "sign in required") : (resolver.youtubeavailable ? "ready" : "unavailable"))
                KeyValue(key: "my server", value: EndpointResolver(base: settings.endpointurl).available ? "set" : "not set")
            }
            Section(header: Text("my own server"), footer: Text("optional. a web address on your own network.")) {
                TextField("http://192.168.1.10:8080/resolve", text: $settings.endpointurl)
                    .autocapitalization(.none).disableAutocorrection(true).keyboardType(.URL)
            }
            Section {
                Toggle("use downloads first", isOn: $settings.preferdownloads)
                Toggle("offline mode", isOn: $settings.offlineonly)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: settings.defaultsource)
        .themed().navigationTitle("where songs play from").navigationBarTitleDisplayMode(.inline)
    }
}

struct YouTubePlayerSettingsView: View {
    @EnvironmentObject var settings: Settings
    @ObservedObject private var auth = GoogleYouTubeAuth.shared

    var body: some View {
        Form {
            Section(header: Text("youtube player"), footer: Text("Advanced YouTube uses an authenticated YouTube Music player request and sends downloaded audio through furmuse's effects engine.")) {
                Picker("mode", selection: $settings.youtubebackendraw) {
                    Text("standard").tag(YouTubeBackend.standard.rawValue)
                    Text("advanced youtube").tag(YouTubeBackend.advanced.rawValue)
                }
            }
            if settings.youtubebackend == .advanced {
                Section(header: Text("playback")) {
                    Label(auth.connected ? "Google account connected" : "connect Google in accounts", systemImage: auth.connected ? "checkmark.circle.fill" : "person.crop.circle.badge.exclamationmark")
                        .foregroundColor(auth.connected ? .green : .orange)
                    Label("pitch, EQ and reverb enabled", systemImage: "slider.vertical.3")
                    Text("Advanced YouTube downloads the selected M4A before first playback so it can use the shared audio graph.").font(.footnote).foregroundColor(.secondary)
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: settings.youtubebackendraw)
        .themed().navigationTitle("youtube player").navigationBarTitleDisplayMode(.inline)
    }
}

struct SpotifyPlayerSettingsView: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var auth: SpotifyAuth
    @ObservedObject private var librespot = LibrespotSession.shared
    @ObservedObject private var lauth = LibrespotAuth.shared
    @State private var testing = false
    @State private var testresult: String?

    private func row(_ title: String, _ ok: Bool, _ fix: String) -> some View {
        HStack(alignment: .top) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundColor(ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if !ok { Text(fix).font(.footnote).foregroundColor(.secondary) }
            }
        }
    }

    private func runtest() {
        testing = true; testresult = nil
        Task { @MainActor in
            do { try await LibrespotSession.shared.ensure(auth: auth); testresult = "all good." }
            catch { testresult = (error as? SourceError)?.text ?? error.localizedDescription }
            testing = false
        }
    }

    var body: some View {
        Form {
            Section(header: Text("spotify player"), footer: Text("standard just works. \"with effects\" lets speed, pitch and effects work on spotify songs, but needs extra setup.")) {
                Picker("mode", selection: $settings.spotifybackendraw) {
                    Text("standard").tag(SpotifyBackend.webplayback.rawValue)
                    Text("with effects").tag(SpotifyBackend.librespot.rawValue)
                }
            }
            if settings.backend == .webplayback { WebPlayerStatusSection() }
            if settings.backend == .librespot {
            Section(header: Text("setup"), footer: Text("everything must be green for spotify songs to play.")) {
                row("included in this app", librespot.available, "not included in this build")
                row("spotify connected", auth.connected, "connect it in settings → spotify")
                row("signed in for effects", lauth.connected, "tap \"sign in\" below")
                if let e = lauth.lasterror { Text(e).font(.footnote).foregroundColor(.orange) }
                if lauth.connected {
                    Button("sign out", role: .destructive) { lauth.disconnect(); LibrespotSession.shared.shutdown() }
                } else {
                    Button(lauth.busy ? "signing in…" : "sign in") { lauth.connect() }.disabled(lauth.busy)
                }
                row("ready", librespot.status == "connected", "tap \"test\" below")
                if let e = librespot.lasterror { Text(e).font(.footnote).foregroundColor(.orange) }
                Button(testing ? "testing…" : "test") { runtest() }
                    .disabled(testing || LibrespotSession.shared.blocker(auth: auth) != nil)
                Button(testing ? "reconnecting…" : "reconnect") {
                    testing = true; testresult = nil
                    Task { @MainActor in
                        do { try await librespot.reconnect(auth: auth); testresult = "connected." }
                        catch { testresult = (error as? SourceError)?.text ?? error.localizedDescription }
                        testing = false
                    }
                }.disabled(testing || LibrespotSession.shared.blocker(auth: auth) != nil)
                if let r = testresult { Text(r).font(.footnote).foregroundColor(.secondary) }
            }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: settings.spotifybackendraw)
        .themed().navigationTitle("spotify player").navigationBarTitleDisplayMode(.inline)
    }
}

struct SpotifySettingsView: View {
    @EnvironmentObject var auth: SpotifyAuth
    @EnvironmentObject var store: SetupStore

    var body: some View {
        Form {
            ClientIDSection()
            Section(header: Text("account")) {
                KeyValue(key: "status", value: auth.connected ? (auth.verified ? "connected" : "not checked yet") : "not connected")
                if auth.connected, auth.scopesok == false {
                    Text("please disconnect and connect again once.")
                        .font(.footnote).foregroundColor(.orange)
                }
                if let n = auth.account { KeyValue(key: "account", value: n) }
                if auth.connected {
                    Button("check connection") { Task { await auth.verify() } }
                    Button("disconnect", role: .destructive) { auth.disconnect() }
                } else {
                    Button(auth.busy ? "waiting…" : "connect spotify") { auth.connect() }.disabled(auth.busy || !store.config.spotifyconfigured)
                }
                if let e = auth.lasterror { Text(e).font(.footnote).foregroundColor(.red) }
                if !store.config.spotifyconfigured { Text("add your client id above first").font(.footnote).foregroundColor(.orange) }
            }
            Section(footer: Text("needs spotify premium.")) {
                Link("open spotify", destination: URL(string: "https://open.spotify.com")!)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: auth.connected)
        .themed().navigationTitle("spotify").navigationBarTitleDisplayMode(.inline)
        .task { if auth.connected && !auth.verified { await auth.verify() } }
    }
}

struct LastfmSettingsView: View {
    @EnvironmentObject var lastfm: LastfmClient
    @EnvironmentObject var store: SetupStore
    @State private var warn = false
    @State private var apiKey = ""
    @State private var sharedSecret = ""

    private var statustext: String {
        switch lastfm.state {
        case .notconfigured: return "not set up"
        case .signedout: return "signed out"
        case .authenticated: return "signed in"
        case .expired: return "sign in again"
        }
    }

    var body: some View {
        Form {
            Section(header: Text("last.fm keys"), footer: Text("get them free at last.fm/api/account/create.")) {
                SecureField(lastfm.configured ? "key saved" : "api key", text: $apiKey)
                    .textInputAutocapitalization(.never).disableAutocorrection(true)
                SecureField(lastfm.configured ? "secret saved" : "shared secret", text: $sharedSecret)
                    .textInputAutocapitalization(.never).disableAutocorrection(true)
                Button("save") {
                    let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    let secret = sharedSecret.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !key.isEmpty, !secret.isEmpty else { ToastCenter.shared.show("fill in both boxes"); return }
                    AppConfig.saveLastfm(apiKey: key, secret: secret)
                    lastfm.configure(apikey: key, secret: secret); store.reloadconfig()
                    apiKey = ""; sharedSecret = ""
                    ToastCenter.shared.show("saved")
                }
            }
            Section(header: Text("account")) {
                KeyValue(key: "status", value: statustext)
                switch lastfm.state {
                case .notconfigured:
                    Text("add your keys above first").font(.footnote).foregroundColor(.orange)
                case .signedout:
                    Button(lastfm.busy ? "waiting…" : "sign in") { lastfm.authenticate() }.disabled(lastfm.busy)
                case .authenticated:
                    KeyValue(key: "signed in as", value: lastfm.username ?? "")
                    Button("check connection") { Task { await lastfm.validate() } }
                    Button("sign out", role: .destructive) { lastfm.logout() }
                case .expired:
                    Text("sign in again. plays are saved until then.").font(.footnote).foregroundColor(.orange)
                    Button(lastfm.busy ? "waiting…" : "sign in again") { lastfm.authenticate() }.disabled(lastfm.busy)
                    Button("sign out", role: .destructive) { lastfm.logout() }
                }
                if let e = lastfm.lasterror { Text(e).font(.footnote).foregroundColor(.red) }
            }
            Section(header: Text("send plays from"), footer: Text("last.fm gets the original song info, even if you renamed it.")) {
                Toggle("spotify", isOn: Binding(
                    get: { store.state.lastfmscrobblespotify },
                    set: { on in
                        if !on { store.setscrobble(.spotify, false) }
                        else if store.state.lastfmlinkedtospotify == false { store.setscrobble(.spotify, true) }
                        else { warn = true }
                    }))
                Toggle("local files", isOn: Binding(get: { store.state.lastfmscrobblelocal }, set: { store.setscrobble(.local, $0) }))
                Toggle("youtube", isOn: Binding(get: { store.state.lastfmscrobbleyoutube }, set: { store.setscrobble(.youtube, $0) }))
                Toggle("last.fm already tracks my spotify", isOn: Binding(get: { store.state.lastfmlinkedtospotify ?? true }, set: { store.setlastfmlinked($0) }))
            }
            if store.state.lastfmlinkedtospotify != false && store.state.lastfmscrobblespotify {
                Section(header: Text("double counting")) {
                    Text("last.fm may count your spotify plays twice.").font(.footnote).foregroundColor(.orange)
                    if store.doublescrobblepending {
                        Text("spotify plays aren't sent until you choose.").font(.footnote).foregroundColor(.secondary)
                        Button("keep both on") { store.confirmdoublescrobble() }
                        Button("turn off spotify plays here") { store.setscrobble(.spotify, false) }
                    } else {
                        Text("you chose to keep both on.").font(.footnote).foregroundColor(.secondary)
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: store.state.lastfmscrobblespotify)
        .themed().navigationTitle("last.fm").navigationBarTitleDisplayMode(.inline)
        .alert("might count twice", isPresented: $warn) {
            Button("turn on anyway") { store.setscrobble(.spotify, true); store.confirmdoublescrobble() }
            Button("cancel", role: .cancel) {}
        } message: {
            Text("if last.fm already tracks your spotify, these plays could be counted twice.")
        }
    }
}

struct DownloadsSettingsView: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var downloads: DownloadManager

    var body: some View {
        Form {
            Section {
                Toggle("wi-fi only", isOn: $settings.wifionly)
                Toggle("use downloads first", isOn: $settings.preferdownloads)
                Toggle("offline mode", isOn: $settings.offlineonly)
                KeyValue(key: "space used", value: ByteCountFormatter.string(fromByteCount: downloads.totalbytes, countStyle: .file))
            }
            Section(header: Text("downloaded songs")) {
                let ids = library.data.downloads.keys.sorted()
                if ids.isEmpty { Text("nothing yet").foregroundColor(.secondary) }
                ForEach(ids, id: \.self) { id in
                    let d = library.data.downloads[id]!
                    VStack(alignment: .leading) {
                        Text(library.data.tracks[id].map { library.shown($0).title } ?? d.title ?? id)
                        Text(ByteCountFormatter.string(fromByteCount: d.bytes, countStyle: .file)).font(.caption).foregroundColor(.secondary)
                    }
                }
                .onDelete { offsets in offsets.map { ids[$0] }.forEach { downloads.remove($0) } }
            }
        }
        .themed().navigationTitle("downloads").navigationBarTitleDisplayMode(.inline)
    }
}

struct LyricsSettingsView: View {
    @EnvironmentObject var settings: Settings
    var body: some View {
        Form {
            Section(footer: Text("lyrics are saved on your phone.")) {
                Toggle("show lyrics", isOn: $settings.lyricson)
                Toggle("find lyrics online", isOn: $settings.lyricsnet)
                Toggle("search more sites", isOn: $settings.lyricsmore).disabled(!settings.lyricsnet)
                NavigationLink("lyrics sources", destination: LyricsSourcesSettingsView()).disabled(!settings.lyricsnet)
                NavigationLink("spicy lyrics key", destination: SpicyLyricsSettingsView())
            }
            Section(header: Text("highlighting")) {
                Picker("style", selection: $settings.lyricsstyle) {
                    Text("classic").tag("classic")
                    Text("laser").tag("laser")
                }
                Toggle("highlight word by word", isOn: $settings.lyricswords)
                Toggle("guess when timing is missing", isOn: $settings.lyricsfake).disabled(!settings.lyricswords)
            }
            Section(header: Text("romanization"), footer: Text("you can override this for a single song from the ... menu in lyrics.")) {
                Toggle("romanization", isOn: $settings.lyricsromanize)
                Picker("show romanization as", selection: $settings.lyricsromanstyle) {
                    Text("romanized words").tag("replace")
                    Text("small text below").tag("below")
                    Text("current line only").tag("current")
                }.disabled(!settings.lyricsromanize)
            }
            Section(header: Text("text size")) { Slider(value: $settings.lyricssize, in: 14...34, step: 1) }
        }
        .onChange(of: settings.lyricsmore) { more in
            let extras = ["netease", "qq", "kugou"]
            if more { settings.lyricsdisabledproviders.removeAll { extras.contains($0) } }
            else { settings.lyricsdisabledproviders = Array(Set(settings.lyricsdisabledproviders + extras)) }
        }
        .themed().navigationTitle("lyrics").navigationBarTitleDisplayMode(.inline)
    }
}

struct LyricsSourcesSettingsView: View {
    @EnvironmentObject var settings: Settings

    var body: some View {
        List {
            Section(header: Text("online providers"), footer: Text("drag to choose the order. a timeout or error always falls through to the next enabled provider. your own saved lyrics always stay first.")) {
                ForEach(settings.lyricsproviderorder, id: \.self) { id in
                    Toggle(isOn: enabled(id)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(LyricsProviders.labels[id] ?? id)
                            if id == "spicy", !SpicyLyrics.shared.haskey { Text("add a key").font(.caption).foregroundColor(.secondary) }
                        }
                    }
                }
                .onMove { offsets, destination in settings.lyricsproviderorder.move(fromOffsets: offsets, toOffset: destination) }
            }
            Section { NavigationLink("spicy lyrics key and result types", destination: SpicyLyricsSettingsView()) }
        }
        .environment(\.editMode, .constant(.active))
        .themed().navigationTitle("lyrics sources").navigationBarTitleDisplayMode(.inline)
    }

    private func enabled(_ id: String) -> Binding<Bool> {
        Binding(get: { !settings.lyricsdisabledproviders.contains(id) }, set: { on in
            if on { settings.lyricsdisabledproviders.removeAll { $0 == id } }
            else if !settings.lyricsdisabledproviders.contains(id) { settings.lyricsdisabledproviders.append(id) }
        })
    }
}

struct LibrarySettingsView: View {
    @EnvironmentObject var library: LibraryStore
    @State private var exportdocument: LibraryBackupDocument?
    @State private var exporting = false
    @State private var importing = false
    @State private var kind = "artist"
    @State private var from = ""
    @State private var to = ""

    var body: some View {
        Form {
            Section(header: Text("backup"), footer: Text("restoring only adds things. nothing is replaced or deleted.")) {
                KeyValue(key: "songs", value: "\(library.data.tracks.count)")
                KeyValue(key: "playlists", value: "\(library.data.playlists.count)")
                KeyValue(key: "youtube matches", value: "\(library.data.mappings.count)")
                Button("save backup") {
                    guard let data = library.backupdata() else { ToastCenter.shared.show("couldn't make a backup"); return }
                    exportdocument = LibraryBackupDocument(data: data)
                    exporting = true
                }
                Button("restore backup") { importing = true }
            }
            Section(header: Text("renames"), footer: Text("change how a name looks in this app.")) {
                ForEach(library.data.artistmap.keys.sorted(), id: \.self) { k in KeyValue(key: "artist: \(k)", value: library.data.artistmap[k] ?? "") }
                    .onDelete { o in let ks = library.data.artistmap.keys.sorted(); library.mutate { d in o.forEach { d.artistmap[ks[$0]] = nil } } }
                ForEach(library.data.albummap.keys.sorted(), id: \.self) { k in KeyValue(key: "album: \(k)", value: library.data.albummap[k] ?? "") }
                    .onDelete { o in let ks = library.data.albummap.keys.sorted(); library.mutate { d in o.forEach { d.albummap[ks[$0]] = nil } } }
                Picker("kind", selection: $kind) { Text("artist").tag("artist"); Text("album").tag("album") }.pickerStyle(.segmented)
                TextField("original name", text: $from).autocapitalization(.none)
                TextField("show as", text: $to).autocapitalization(.none)
                Button("add") {
                    let f = from.trimmingCharacters(in: .whitespaces), t = to.trimmingCharacters(in: .whitespaces)
                    guard !f.isEmpty, !t.isEmpty else { return }
                    library.mutate { if kind == "artist" { $0.artistmap[f] = t } else { $0.albummap[f] = t } }
                    from = ""; to = ""
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: library.data.artistmap.count + library.data.albummap.count)
        .themed().navigationTitle("library").navigationBarTitleDisplayMode(.inline)
        .fileExporter(isPresented: $exporting, document: exportdocument, contentType: .json, defaultFilename: "furmuse-library") { result in
            switch result {
            case .success: Log.i(.local, "library backup exported"); ToastCenter.shared.show("backup saved")
            case .failure(let error): Log.e(.local, "library backup export failed: \(error.localizedDescription)"); ToastCenter.shared.show("couldn't save the backup")
            }
            exportdocument = nil
        }
        .copyPicker(isPresented: $importing, types: [.json, .plainText]) { urls in
            guard let u = urls.first else { return }
            let n = library.importdata(u)
            ToastCenter.shared.show(n < 0 ? "couldn't read that file" : "added \(n) new items")
        }
    }
}

struct LibraryBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct IdentifiedURL: Identifiable, Equatable { let url: URL; var id: String { url.absoluteString } }

struct AdvancedSettingsView: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var store: SetupStore
    @EnvironmentObject var lyrics: LyricsStore
    @EnvironmentObject var lastfm: LastfmClient
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var auth: SpotifyAuth
    @State private var confirm = ""
    @State private var checkingForUpdates = false
    @State private var updateMessage: String?
    @State private var updateURL: URL?
    private let displayedVersion = "v1.1"

    private struct GitHubRelease: Decodable {
        let tag_name: String
        let html_url: String
        let name: String?
    }

    private func versionParts(_ value: String) -> [Int] {
        value.split { !$0.isNumber }.compactMap { Int($0) }
    }

    private func isNewer(_ remote: String, than local: String) -> Bool {
        let a = versionParts(remote), b = versionParts(local)
        for i in 0..<max(a.count, b.count) {
            let av = i < a.count ? a[i] : 0
            let bv = i < b.count ? b[i] : 0
            if av != bv { return av > bv }
        }
        return false
    }

    @MainActor
    private func checkForUpdates() async {
        checkingForUpdates = true
        updateMessage = nil
        updateURL = nil
        defer { checkingForUpdates = false }
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/mrwolfstip/furmuse/releases/latest")!)
            request.timeoutInterval = 15
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("furmuse/1.1", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if http.statusCode == 404 {
                updateMessage = "No published GitHub release was found yet."
                return
            }
            guard (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            if isNewer(release.tag_name, than: displayedVersion) {
                updateMessage = "\(release.name ?? release.tag_name) is available."
                updateURL = URL(string: release.html_url)
            } else {
                updateMessage = "Furmuse is up to date."
            }
        } catch {
            updateMessage = "Couldn’t check for updates. Try again later."
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle("show error messages", isOn: $settings.toastson)
                Button("clear saved lyrics") { lyrics.clearcache() }
                NavigationLink("problem report", destination: DiagnosticsView())
            }
            Section(header: Text("keys")) {
                KeyValue(key: "spotify client id", value: store.config.spotifyclientidentered ? "set" : "missing")
                KeyValue(key: "last.fm key", value: store.config.lastfmapikey.isEmpty ? "missing" : "set")
                KeyValue(key: "last.fm secret", value: store.config.lastfmsharedsecret.isEmpty ? "missing" : "set")
            }
            Section {
                Button("reset settings", role: .destructive) { confirm = "settings" }
                Button("redo setup", role: .destructive) { confirm = "setup" }
                Button("erase everything", role: .destructive) { confirm = "everything" }
            }
            Section {
                KeyValue(key: "app version", value: displayedVersion)
                Button(checkingForUpdates ? "checking for updates…" : "check for updates") {
                    Task { await checkForUpdates() }
                }
                .disabled(checkingForUpdates)
                if let updateMessage {
                    Text(updateMessage).font(.footnote).foregroundColor(.secondary)
                }
                if let updateURL {
                    Link("open new release", destination: updateURL)
                }
            }
        }
        .themed().navigationTitle("more").navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("are you sure?", isPresented: Binding(get: { !confirm.isEmpty }, set: { if !$0 { confirm = "" } }), titleVisibility: .visible) {
            Button(confirm == "everything" ? "erase everything" : (confirm == "setup" ? "redo setup" : "reset settings"), role: .destructive) {
                if confirm == "settings" { settings.resetall() }
                else if confirm == "setup" { store.resetlocalsetup() }
                else {
                    auth.disconnect(); LibrespotAuth.shared.disconnect(); lastfm.logout(); ClientIDStore.clear(); AppConfig.clearLastfm(); lyrics.clearall()
                    library.eraseall(); settings.resetall(); store.resetlocalsetup()
                }
                confirm = ""
            }
            Button("cancel", role: .cancel) { confirm = "" }
        } message: { Text(confirm == "everything" ? "removes your accounts, downloads, playlists and settings from this phone." : (confirm == "setup" ? "shows the setup screens again. accounts stay connected." : "puts every setting back how it started.")) }
    }
}


struct AppleCoversSettingsView: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var engine: PlaybackEngine
    @ObservedObject private var apple = AppleCovers.shared

    private var tracks: [Track] { Array(library.data.tracks.values) }

    var body: some View {
        Form {
            Section(header: Text("priority"), footer: Text("when both services find a match, furmuse uses this one first and falls back to the other.")) {
                Picker("use first", selection: $settings.animatedcoverorder) {
                    Text("spotify canvas").tag("canvas")
                    Text("apple music animated").tag("apple")
                }
                .pickerStyle(.segmented)
            }
            Section(
                header: Text("apple music covers"),
                footer: Text("on by default. artist and album names are sent to the server below to find moving covers.")
            ) {
                Toggle("use apple covers", isOn: $settings.applecovers)
                if settings.applecovers {
                    TextField("server", text: $settings.applecoversurl).textInputAutocapitalization(.never).disableAutocorrection(true).keyboardType(.URL)
                }
            }
            Section(
                header: Text("spotify canvas"),
                footer: Text("the short looping videos from spotify. furmuse uses a public community service by default; you can replace its address here. canvas is unofficial and may break if spotify changes it.")
            ) {
                Toggle("use spotify canvas", isOn: $settings.spotifycanvas)
                if settings.spotifycanvas {
                    TextField("service address", text: $settings.spotifycanvasurl).textInputAutocapitalization(.never).disableAutocorrection(true).keyboardType(.URL)
                    if settings.spotifycanvasurl.trimmingCharacters(in: .whitespaces).isEmpty {
                        Button("restore default service") { settings.spotifycanvasurl = Settings.defaultcanvasurl }
                    }
                }
                KeyValue(key: "saved", value: "\(SpotifyCanvas.shared.cachecount)")
                if !SpotifyCanvas.shared.status.isEmpty {
                    Text(SpotifyCanvas.shared.status).font(.footnote).foregroundColor(.secondary)
                }
                Button("test with current song") {
                    guard let track = engine.current, track.isspotify else {
                        ToastCenter.shared.show("play a spotify song first")
                        return
                    }
                    Task {
                        if await SpotifyCanvas.shared.cover(trackid: track.id) != nil { ToastCenter.shared.show("canvas is working") }
                        else if SpotifyCanvas.shared.status.isEmpty { ToastCenter.shared.show("this song has no canvas") }
                    }
                }
                .disabled(!settings.spotifycanvas || settings.spotifycanvasurl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("clear canvas videos", role: .destructive) { SpotifyCanvas.shared.clear() }
            }
            Section(header: Text("get covers ready"), footer: Text("looks up covers for your whole library, so they're ready before you play.")) {
                if apple.running {
                    ProgressView(value: Double(apple.done), total: Double(max(apple.total, 1)))
                    Text("\(apple.done) of \(apple.total) · \(apple.found) found").font(.footnote).foregroundColor(.secondary)
                    Button("stop", role: .destructive) { apple.stop() }
                } else {
                    Button("get covers for my library (\(tracks.count) songs)") {
                        let list = tracks, use = settings.applecovers, lib = library
                        Task { await apple.precache(tracks: list, useapple: use, library: lib) }
                    }.disabled(tracks.isEmpty)
                    if !apple.status.isEmpty { Text(apple.status).font(.footnote).foregroundColor(.secondary) }
                }
                KeyValue(key: "saved", value: "\(apple.cachecount)")
                Button("clear apple covers", role: .destructive) { apple.clear() }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: settings.applecovers)
        .animation(.easeInOut(duration: 0.25), value: settings.spotifycanvas)
        .animation(.easeInOut(duration: 0.25), value: apple.running)
        .themed().navigationTitle("animated covers").navigationBarTitleDisplayMode(.inline)
    }
}


// status and controls for the standard spotify player
struct WebPlayerStatusSection: View {
    @ObservedObject private var web = WebPlaybackSession.shared
    @EnvironmentObject var auth: SpotifyAuth
    @State private var note: String?

    private func row(_ title: String, _ ok: Bool, _ fix: String) -> some View {
        HStack(alignment: .top) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundColor(ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if !ok { Text(fix).font(.footnote).foregroundColor(.secondary) }
            }
        }
    }

    var body: some View {
        Section(header: Text("status"),
                footer: Text("needs spotify premium. \"\(WebPlaybackSession.devicename)\" then shows up in your spotify speaker list.")) {
            row("client id added", !auth.clientid.isEmpty, "add it in settings → spotify")
            row("spotify connected", auth.connected && auth.scopesok != false, web.blocker() ?? "connect it in settings → spotify")
            row("player ready", web.phase == .ready, web.lasterror ?? "starts by itself")
            if web.phase == .ready { KeyValue(key: "speaker name", value: WebPlaybackSession.devicename) }
            if web.activationneeded {
                Text("tap the bar at the top of the screen once to start.").font(.footnote).foregroundColor(.orange)
            }
            if web.volumecontrol == false {
                Text("use your phone's volume buttons for spotify songs.").font(.footnote).foregroundColor(.secondary)
            }
            Button("restart player") { web.restart(); note = nil }
            Button("use \(WebPlaybackSession.devicename) as my speaker") {
                Task { @MainActor in
                    do { try await web.transferhere(play: false); note = "done." }
                    catch { note = (error as? SourceError)?.text ?? error.localizedDescription }
                }
            }.disabled(web.phase != .ready)
            if let n = note { Text(n).font(.footnote).foregroundColor(.secondary) }
        }
    }
}
