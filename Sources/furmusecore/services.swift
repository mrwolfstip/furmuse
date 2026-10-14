import Foundation
import Combine
import SwiftUI

final class Services {
    static let shared = Services()
    let settings: Settings
    let toasts = ToastCenter.shared
    let store: SetupStore
    let library: LibraryStore
    let auth: SpotifyAuth
    let api: SpotifyAPI
    let devices: DeviceManager
    let resolver: ResolverManager
    let downloads: DownloadManager
    let engine: PlaybackEngine
    let nowplaying: NowPlayingCenter
    let lastfm: LastfmClient
    let scrobbler: Scrobbler
    let lyrics: LyricsStore
    private var bag = Set<AnyCancellable>()

    private init() {
        Settings.styleuikit()
        let settings = Settings()
        let st = SetupStore()
        let library = LibraryStore()
        let cfg = st.config
        let auth = SpotifyAuth(clientid: cfg.spotifyclientid)
        let api = SpotifyAPI(auth: auth)
        let devices = DeviceManager(api: api, library: library) { id in st.update { $0.selecteddeviceid = id } }
        let resolver = ResolverManager(settings: settings, library: library)
        let engine = PlaybackEngine(settings: settings, library: library, resolver: resolver, auth: auth)
        let lastfm = LastfmClient(apikey: cfg.lastfmapikey, secret: cfg.lastfmsharedsecret)
        let lyrics = LyricsStore(settings: settings)
        let np = NowPlayingCenter(engine: engine, settings: settings, library: library, lyrics: lyrics)
        engine.onstatechange = { np.refresh() }
        self.settings = settings
        self.store = st
        self.library = library
        self.auth = auth
        self.api = api
        self.devices = devices
        self.resolver = resolver
        self.downloads = DownloadManager(settings: settings, library: library, resolver: resolver)
        self.engine = engine
        self.nowplaying = np
        self.lastfm = lastfm
        self.scrobbler = Scrobbler(client: lastfm, library: library, sourcekind: { [unowned engine] in engine.sourcekind }) { kind in st.scrobbleallowed(kind) }
        self.lyrics = lyrics
        auth.$connected.receive(on: DispatchQueue.main).sink { v in st.update { $0.spotifyauthenticated = v } }.store(in: &bag)
        // switching the default audio source applies to everything: per-track spotify / youtube choices follow it, and the
        // song that is playing moves over at the same position
        settings.$defaultsource.removeDuplicates().dropFirst().receive(on: DispatchQueue.main)
            .sink { _ in
                library.followglobalsource()
                Task { @MainActor in engine.followsourcechange() }
            }.store(in: &bag)
        toasts.enabled = settings.toastson
        AppleCovers.shared.serverurl = { [unowned settings] in settings.applecoversurl }
        SpotifyCanvas.shared.serverurl = { [unowned settings] in settings.spotifycanvasurl }
        library.$data.dropFirst().receive(on: DispatchQueue.main).sink { _ in np.refresh() }.store(in: &bag)
        Log.i(.lifecycle, "furmuse \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") launched")
        Task { await lastfm.validate(); await auth.verify() }
        // spotify connect: register "Furmuse" as a connect device on its own at launch (no cast / transfer from another
        // spotify device) and keep it alive. exactly one backend does this: the web playback sdk (default) or librespot.
        engine.startconnect()
        Task { @MainActor in WebPlaybackSession.shared.configure(auth: auth, api: api, devices: devices) }
        let applybackend: () -> Void = {
            Task { @MainActor in
                let web = settings.backend == .webplayback
                LibrespotSession.shared.setenabled(!web)
                if web {
                    WebPlaybackSession.shared.supervise(enabled: st.state.spotifyintegrationenabled)
                } else {
                    WebPlaybackSession.shared.supervise(enabled: false)
                    if st.state.spotifyintegrationenabled { LibrespotSession.shared.supervise(auth: auth) }
                }
            }
        }
        applybackend()
        settings.$spotifybackendraw.removeDuplicates().dropFirst().receive(on: DispatchQueue.main)
            .sink { _ in
                applybackend()
                Task { @MainActor in engine.followspotifybackendchange() }
            }.store(in: &bag)
        st.$state.map { $0.spotifyintegrationenabled }.removeDuplicates().dropFirst().receive(on: DispatchQueue.main)
            .sink { _ in applybackend() }.store(in: &bag)
        auth.$connected.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { _ in applybackend() }.store(in: &bag)
        // a new or changed client id / refreshed scopes can unblock the web player
        auth.$grantedscopes.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { _ in Task { @MainActor in WebPlaybackSession.shared.kick(force: true) } }.store(in: &bag)
        LibrespotAuth.shared.$connected.removeDuplicates().filter { $0 }.receive(on: DispatchQueue.main)
            .sink { _ in if settings.backend == .librespot { Task { @MainActor in LibrespotSession.shared.supervise(auth: auth) } } }.store(in: &bag)
    }
}

extension View {
    func inject(_ s: Services) -> some View {
        self.environmentObject(s.settings).environmentObject(s.store).environmentObject(s.toasts)
            .environmentObject(s.library).environmentObject(s.auth).environmentObject(s.devices)
            .environmentObject(s.engine).environmentObject(s.downloads).environmentObject(s.lastfm)
            .environmentObject(s.lyrics).environmentObject(s.resolver)
    }
}
