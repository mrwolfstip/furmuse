import SwiftUI

struct SetupView: View {
    @EnvironmentObject var store: SetupStore
    @EnvironmentObject var auth: SpotifyAuth
    @EnvironmentObject var lastfm: LastfmClient
    @EnvironmentObject var settings: Settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var direction = 1
    @State private var premiumPrompt = false
    @State private var clientID = ""
    @State private var clientMessage: String?
    @State private var checkingClient = false
    @State private var showingGoogleSignIn = false
    @State private var lastfmKey = ""
    @State private var lastfmSecret = ""

    private enum Page: String { case welcome, service, spotifyAccount, spotifyPlayer, youtubePlayer, youtubeNotice, lastfm, finish }
    private var pages: [Page] {
        if store.state.mainservice == "spotify" { return [.welcome, .service, .spotifyAccount, .spotifyPlayer, .lastfm, .finish] }
        if store.state.mainservice == "youtube" { return [.welcome, .service, .youtubePlayer, .youtubeNotice, .lastfm, .finish] }
        return [.welcome, .service]
    }
    private var index: Int { min(max(store.state.setupstep, 0), pages.count - 1) }
    private var page: Page { pages[index] }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if page != .welcome {
                    ProgressView(value: Double(index + 1), total: Double(pages.count)).padding(.horizontal, 28).padding(.top, 18)
                    Text("step \(index + 1) of \(pages.count)").font(.caption).foregroundColor(.secondary).padding(.top, 6)
                }
                ZStack { screen(page).id(page.rawValue).transition(transition) }
            }
            .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.48, dampingFraction: 0.84), value: page)
            .themed().navigationBarHidden(true)
            .alert("do you have spotify premium?", isPresented: $premiumPrompt) {
                Button("yes") { chooseSpotify() }
                Button("no") { chooseYouTube() }
                Button("cancel", role: .cancel) {}
            } message: { Text("spotify playback needs premium. if you don't have it, furmuse will use youtube. you can still connect spotify later for search and imports.") }
        }.navigationViewStyle(.stack)
    }

    private var transition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: direction > 0 ? .trailing : .leading).combined(with: .opacity), removal: .move(edge: direction > 0 ? .leading : .trailing).combined(with: .opacity))
    }

    @ViewBuilder private func screen(_ p: Page) -> some View {
        switch p {
        case .welcome: centered { VStack(spacing: 18) { Image(systemName: "waveform").font(.system(size: 54, weight: .semibold)); Text("welcome to furmuse").font(.largeTitle.bold()); Text("let's get your music ready.").foregroundColor(.secondary); primary("get started") { go(1) }; skipButton } }
        case .service: servicePage
        case .spotifyAccount: spotifyAccountPage
        case .spotifyPlayer: spotifyPlayerPage
        case .youtubePlayer: youtubePlayerPage
        case .youtubeNotice: youtubePage
        case .lastfm: lastfmPage
        case .finish: centered { VStack(spacing: 18) { Image(systemName: "checkmark.circle.fill").font(.system(size: 54)).foregroundColor(.green); Text("you're all set").font(.largeTitle.bold()); Text("you can change everything later in settings.").foregroundColor(.secondary); primary("start listening") { store.completesetup() }; backButton } }
        }
    }

    private var servicePage: some View {
        centered {
            VStack(spacing: 18) {
                Text("where do you listen?").font(.largeTitle.bold())
                Text("this chooses search and the default place songs play from.").foregroundColor(.secondary)
                primary("spotify", icon: "dot.radiowaves.left.and.right") { premiumPrompt = true }
                primary("youtube", icon: "play.rectangle.fill") { chooseYouTube() }
                backButton; skipButton
            }
        }
    }

    private var spotifyAccountPage: some View {
        centered {
            VStack(spacing: 14) {
                Text("connect spotify").font(.largeTitle.bold())
                Text("create an app, enable web playback sdk and web api, then add this redirect address.").foregroundColor(.secondary)
                Link("open spotify developer dashboard", destination: URL(string: "https://developer.spotify.com/dashboard")!)
                HStack { Text(AppConfig.spotifyredirecturi).textSelection(.enabled); Button("copy") { UIPasteboard.general.string = AppConfig.spotifyredirecturi } }.font(.subheadline)
                TextField("paste client id", text: $clientID).textInputAutocapitalization(.never).disableAutocorrection(true).textFieldStyle(.roundedBorder)
                Button(checkingClient ? "checking…" : "save client id") { saveClientID() }.buttonStyle(.bordered).disabled(checkingClient || clientID.isEmpty)
                if let clientMessage { Text(clientMessage).font(.footnote).foregroundColor(.secondary) }
                if !auth.connected { primary(auth.busy ? "waiting…" : "sign in to spotify") { auth.connect() }.disabled(auth.busy || !store.config.spotifyconfigured) }
                else { Label(auth.account ?? "connected", systemImage: "checkmark.circle.fill").foregroundColor(.green); primary("continue") { next() } }
                backButton; skipButton
            }
        }
    }

    private var spotifyPlayerPage: some View {
        centered {
            VStack(spacing: 18) {
                Text("choose a spotify player").font(.largeTitle.bold())
                choice("standard", "can be extremely unreliable. speed, pitch and effects don't apply.") { settings.backend = .webplayback; next() }
                choice("with effects", "more reliable, with speed, pitch, eq and reverb.") { settings.backend = .librespot }
                if settings.backend == .librespot {
                    if LibrespotAuth.shared.connected { Label("ready", systemImage: "checkmark.circle.fill").foregroundColor(.green); primary("continue") { next() } }
                    else { primary(LibrespotAuth.shared.busy ? "signing in…" : "sign in for effects") { LibrespotAuth.shared.connect() }.disabled(LibrespotAuth.shared.busy) }
                }
                backButton; skipButton
            }
        }
    }

    private var youtubePage: some View {
        centered { VStack(spacing: 18) { Image(systemName: "exclamationmark.bubble").font(.system(size: 46)); Text("a quick note").font(.largeTitle.bold()); Text("youtube metadata can be wrong when scrobbling to last.fm. you can edit a song's details later.").foregroundColor(.secondary); primary("i understand") { next() }; backButton; skipButton } }
    }

    private var youtubePlayerPage: some View {
        centered {
            VStack(spacing: 18) {
                Text("choose a youtube player").font(.largeTitle.bold())
                choice("standard", "plays instantly. effects apply after the audio has been cached.") {
                    settings.youtubebackend = .standard
                    next()
                }
                choice("advanced youtube", "uses your Google YouTube Music session and downloads audio into the effects engine before playing.") {
                    settings.youtubebackend = .advanced
                }
                if settings.youtubebackend == .advanced {
                    if GoogleYouTubeAuth.shared.connected {
                        Label("Google connected", systemImage: "checkmark.circle.fill").foregroundColor(.green)
                        primary("continue") { next() }
                    } else {
                        primary("sign in with Google") { showingGoogleSignIn = true }
                    }
                    if let error = GoogleYouTubeAuth.shared.lastError { Text(error).font(.footnote).foregroundColor(.orange) }
                }
                Text("experimental: this uses YouTube's internal player service, not an official public audio API.").font(.footnote).foregroundColor(.secondary)
                backButton; skipButton
            }
        }
        .sheet(isPresented: $showingGoogleSignIn) { GoogleYouTubeSignInView() }
    }

    private var lastfmPage: some View {
        centered {
            VStack(spacing: 14) {
                Text("use last.fm?").font(.largeTitle.bold())
                Text("optional. furmuse never asks for your username or password; sign-in happens in your browser.").foregroundColor(.secondary)
                Link("create an api key and secret", destination: URL(string: "https://www.last.fm/api/account/create")!)
                SecureField("api key", text: $lastfmKey).textInputAutocapitalization(.never).disableAutocorrection(true).textFieldStyle(.roundedBorder)
                SecureField("shared secret", text: $lastfmSecret).textInputAutocapitalization(.never).disableAutocorrection(true).textFieldStyle(.roundedBorder)
                Button("save keys") { saveLastfm() }.buttonStyle(.bordered).disabled(lastfmKey.isEmpty || lastfmSecret.isEmpty)
                if lastfm.configured && !lastfm.loggedin { primary(lastfm.busy ? "waiting…" : "sign in through last.fm") { lastfm.authenticate() }.disabled(lastfm.busy) }
                if lastfm.loggedin { Label("connected", systemImage: "checkmark.circle.fill").foregroundColor(.green); primary("continue") { next() } }
                Button("skip") { next() }.foregroundColor(.secondary); backButton; skipButton
            }
        }
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView { content().multilineTextAlignment(.center).frame(maxWidth: 440).padding(.horizontal, 28).padding(.vertical, 36).frame(maxWidth: .infinity, minHeight: 620, alignment: .center) }
    }
    private func primary(_ title: String, icon: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) { Group { if let icon { Label(title, systemImage: icon) } else { Text(title) } }.font(.headline).frame(maxWidth: .infinity).padding(.vertical, 7) }.buttonStyle(.borderedProminent)
    }
    private func choice(_ title: String, _ note: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { VStack(spacing: 4) { Text(title).font(.headline); Text(note).font(.caption).foregroundColor(.secondary) }.frame(maxWidth: .infinity).padding(12) }.buttonStyle(.bordered)
    }
    private var backButton: some View { Button("back") { back() }.foregroundColor(.secondary) }
    private var skipButton: some View { Button("skip setup for now") { store.completesetup() }.font(.footnote).foregroundColor(.secondary) }
    private func go(_ step: Int) { direction = 1; store.update { $0.setupstep = step } }
    private func chooseSpotify() { direction = 1; settings.defaultsource = "spotify"; store.update { $0.mainservice = "spotify"; $0.spotifypremium = true; $0.setupstep = 2 } }
    private func chooseYouTube() { direction = 1; settings.defaultsource = "youtube"; store.update { $0.mainservice = "youtube"; $0.spotifypremium = false; $0.setupstep = 2 } }
    private func next() { go(min(index + 1, pages.count - 1)) }
    private func back() { direction = -1; store.update { $0.setupstep = max(0, index - 1) } }
    private func saveClientID() {
        let id = ClientIDStore.normalize(clientID)
        guard ClientIDStore.valid(id) else { clientMessage = "that doesn't look like a spotify client id"; return }
        if let error = auth.setclientid(id) { clientMessage = error; return }
        store.reloadconfig(); clientID = ""; checkingClient = true; clientMessage = "saved. checking with spotify…"
        Task { @MainActor in clientMessage = await ClientIDStore.check(id) == .rejected ? "spotify rejected it. check the id and redirect address." : "saved"; checkingClient = false }
    }
    private func saveLastfm() { let key = lastfmKey.trimmingCharacters(in: .whitespacesAndNewlines), secret = lastfmSecret.trimmingCharacters(in: .whitespacesAndNewlines); AppConfig.saveLastfm(apiKey: key, secret: secret); lastfm.configure(apikey: key, secret: secret); store.reloadconfig(); lastfmKey = ""; lastfmSecret = "" }
}
