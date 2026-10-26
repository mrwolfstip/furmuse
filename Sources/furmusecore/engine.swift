import Foundation
import AVFoundation
import Combine

// the one player state. ui, now playing and last.fm all read this.
// it talks to a PlaybackSource and never to spotify, youtube or file details directly.
final class PlaybackEngine: ObservableObject {
    @Published private(set) var current: Track?
    @Published private(set) var queue: [Track] = []
    @Published private(set) var index = 0
    @Published private(set) var isplaying = false
    @Published private(set) var loading = false
    @Published private(set) var position = 0.0      // track time
    @Published private(set) var duration = 0.0
    @Published private(set) var sourceinfo = ""
    @Published private(set) var sourcekind: SourceKind?

    private let settings: Settings
    private let library: LibraryStore
    private let resolver: ResolverManager
    private let auth: SpotifyAuth
    private let toasts = ToastCenter.shared
    private let bus = EventBus.shared
    let graph = SharedAudioGraph()
    private var source: PlaybackSource?
    private var token = UUID()
    private var loadtask: Task<Void, Never>?
    private var retried = false
    private var tick: Timer?
    private var bag = Set<AnyCancellable>()
    private var lastspeed = 0.0
    private var lastpushedvolume = 1.0
    var onstatechange: (() -> Void)?

    init(settings: Settings, library: LibraryStore, resolver: ResolverManager, auth: SpotifyAuth) {
        self.settings = settings
        self.library = library
        self.resolver = resolver
        self.auth = auth
        graph.apply(settings)
        settings.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.applysettings() }.store(in: &bag)
        let nc = NotificationCenter.default
        nc.publisher(for: AVAudioSession.interruptionNotification).receive(on: DispatchQueue.main).sink { [weak self] n in
            guard let self = self, let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .began { if self.isplaying { Log.i(.playback, "interruption began"); self.pause() } } else {
                let opts = AVAudioSession.InterruptionOptions(rawValue: n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
                if self.settings.backend == .librespot { Task { @MainActor in LibrespotSession.shared.kick() } }
                if opts.contains(.shouldResume), self.current != nil, !self.isplaying { self.resume() }
            }
        }.store(in: &bag)
        nc.publisher(for: AVAudioSession.routeChangeNotification).receive(on: DispatchQueue.main).sink { [weak self] n in
            guard let self = self, let raw = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable, self.isplaying else { return }
            Log.i(.playback, "output device removed, pausing")
            self.pause()
        }.store(in: &bag)
        Log.i(.lifecycle, "playback engine ready")
    }

    // spotify connect: a spotify client chose what plays; next/previous/seek/pause go back through connect
    var driven: Bool { (source as? ConnectDrivenSource)?.driven == true }
    var hasnext: Bool { driven || index + 1 < queue.count }

    // track time, straight from the source
    func livepos() -> Double { source?.position ?? position }

    func play(_ tracks: [Track], at i: Int = 0) {
        guard tracks.indices.contains(i) else { return }
        library.remember(tracks)
        leave(.skipped)
        queue = tracks
        index = i
        load(tracks[i])
    }

    func enqueue(_ t: Track, next: Bool = false) {
        library.remember([t])
        if current == nil { play([t]); return }
        if next { queue.insert(t, at: min(index + 1, queue.count)) } else { queue.append(t) }
    }

    func jump(to i: Int) {
        guard queue.indices.contains(i) else { return }
        leave(.skipped)
        index = i
        load(queue[i])
    }

    func remove(at offsets: IndexSet) {
        let cur = current
        queue.remove(atOffsets: offsets)
        if let c = cur, let ni = queue.firstIndex(of: c) { index = ni } else { index = min(index, max(queue.count - 1, 0)) }
    }

    func move(from: IndexSet, to: Int) {
        let cur = current
        queue.move(fromOffsets: from, toOffset: to)
        if let c = cur, let ni = queue.firstIndex(of: c) { index = ni }
    }

    func toggle() { isplaying ? pause() : resume() }

    func pause() {
        guard let t = current, isplaying else { return }
        let p = livepos()
        source?.pause()
        isplaying = false
        position = p
        stoptick()
        Log.i(.playback, "pause at \(fmttime(p))")
        bus.send(.paused(t, p))
        onstatechange?()
    }

    func resume() {
        guard let t = current, !isplaying, !loading else { return }
        // A failed load and a naturally-finished queue both keep `current` for the UI but tear the
        // source down. Rebuild it instead of entering a fake "playing" state with no audio source.
        guard source != nil else { load(t); return }
        activatesession()
        source?.resume()
        isplaying = true
        starttick()
        Log.i(.playback, "resume at \(fmttime(livepos()))")
        bus.send(.resumed(t, livepos()))
        onstatechange?()
    }

    func next() {
        if driven { (source as? ConnectDrivenSource)?.connectnext(); return }
        if !hasnext, settings.repeatmode == "all", !queue.isEmpty { leave(.skipped); index = 0; load(queue[0]); return }
        guard hasnext else { if current != nil { leave(.skipped); finishqueue() }; return }
        leave(.skipped)
        index += 1
        load(queue[index])
    }

    func previous() {
        if driven {
            if livepos() > 3 { seek(0) } else { (source as? ConnectDrivenSource)?.connectprevious() }
            return
        }
        if livepos() > 3 { seek(0); return }
        if index == 0 {
            if settings.repeatmode == "all", queue.count > 1 { leave(.skipped); index = queue.count - 1; load(queue[index]) } else { seek(0) }
            return
        }
        leave(.skipped)
        index -= 1
        load(queue[index])
    }

    func seek(_ s: Double) {
        guard let t = current, let src = source else { return }
        let from = livepos()
        let target = min(max(0, s), duration > 0 ? duration : s)
        src.seek(to: target)
        position = target
        Log.i(.playback, "seek \(fmttime(from)) -> \(fmttime(target))")
        bus.send(.seeked(t, from, target))
        onstatechange?()
    }

    // speed, pitch, eq, bass, reverb and volume apply to whatever is playing, immediately, without restarting it
    func applysettings() {
        toasts.enabled = settings.toastson
        graph.apply(settings)
        source?.apply(settings, playing: isplaying)
        // furmuse's volume is also the connect device volume: tell spotify when the user changes it here
        if abs(settings.volume - lastpushedvolume) > 0.004 {
            lastpushedvolume = settings.volume
            if settings.backend == .webplayback { WebPlaybackSession.shared.setvolume(settings.volume) }
            else { LibrespotSession.shared.bridge.connect(.volume, arg: Int((settings.volume * 65535).rounded())) }
        }
        if settings.speed != lastspeed {
            lastspeed = settings.speed
            Log.i(.speed, String(format: "speed %.2fx", settings.speed))
        }
        onstatechange?()
    }

    private enum Leave { case skipped, ended }

    private func leave(_ why: Leave) {
        guard let t = current else { return }
        let p = livepos()
        let wasloaded = source != nil
        // furmuse is about to play something of its own: step out of the connect session so spotify's clients stop
        // showing this device as playing the old track
        if driven && !adopting { (source as? ConnectDrivenSource)?.connectrelease() }
        teardown()
        if wasloaded { bus.send(why == .skipped ? .skipped(t, p) : .ended(t, p)) }
    }

    private func teardown() {
        token = UUID()
        loadtask?.cancel()
        loadtask = nil
        if let id = current?.id { resolver.cancel(id) }
        stoptick()
        source?.onEnd = nil
        source?.onFail = nil
        source?.stop()
        source = nil
        isplaying = false
    }

    private func finishqueue() {
        guard let t = current else { return }
        teardown()
        position = 0
        bus.send(.stopped(t, 0))
        onstatechange?()
    }

    private func load(_ t: Track) {
        // A load is a new request even when there is no live source (for example retrying after a
        // failed prepare). This makes every play/skip generation unique and cancels any older work.
        loadtask?.cancel()
        if let old = current?.id { resolver.cancel(old) }
        token = UUID()
        current = t
        position = 0
        duration = t.duration
        loading = true
        sourceinfo = ""
        sourcekind = nil
        retried = false
        onstatechange?()
        let gen = token
        loadtask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                let src = try await self.makesource(t, fresh: false)
                try Task.checkCancellation()
                guard gen == self.token else { src.stop(); return }
                self.start(src, t, generation: gen)
            } catch {
                if error is CancellationError { return }
                guard gen == self.token else { return }
                self.fail(t, error)
            }
        }
    }

    private func fail(_ t: Track, _ error: Error) {
        loading = false
        isplaying = false
        let text = (error as? ResolveError)?.text ?? (error as? SourceError)?.text ?? "couldn't start playback"
        Log.e(.playback, "couldn't start \(t.id): \(text)")
        let viaspotify = library.preferred(t.id) == .spotify || (library.preferred(t.id) == nil && settings.defaultsource == "spotify")
        toasts.show("\(library.shown(t).title): \(text)", route: viaspotify ? .source : .mapping)
        bus.send(.failed(t))
        onstatechange?()
    }

    // ---- source selection -------------------------------------------------------------------------------
    // order: the track's own choice, offline rules, attached local audio, downloads, then the global default.
    // local and youtube never send anything to spotify; only the spotify source is actual spotify playback.
    @MainActor
    private func makesource(_ t: Track, fresh: Bool) async throws -> PlaybackSource {
        await activatesessionasync()
        let pref: SourceKind? = t.isspotify ? library.preferred(t.id) : (t.islocal ? .local : .youtube)   // youtube-only imports play from their video, added songs from their file

        func local() -> PlaybackSource? {
            guard let u = library.localurl(t.id) else { return nil }
            return LocalFileSource(kind: .local, url: u, graph: graph, info: "local file · \(library.data.sources[t.id]?.localname ?? u.lastPathComponent)")
        }
        func download() -> PlaybackSource? {
            guard let d = library.data.downloads[t.id] else { return nil }
            let u = DownloadManager.root.appendingPathComponent(d.path)
            guard FileManager.default.fileExists(atPath: u.path), YouTubeSource.decodable.contains(d.container) else { return nil }
            return LocalFileSource(kind: .youtube, url: u, graph: graph, info: [d.container, d.codec, d.bitrate.map { "\($0 / 1000)kbps" }, "download"].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "), endlimit: d.trimend)
        }
        func youtube() -> PlaybackSource { YouTubeSource(track: t, resolver: resolver, graph: graph, settings: settings, fresh: fresh) }
        // one spotify source, two interchangeable backends: the web playback sdk (default) or librespot
        func spotify() -> PlaybackSource {
            settings.backend == .webplayback ? WebPlaybackSource(track: t, auth: auth) : SpotifyPlaybackSource(track: t, graph: graph, auth: auth)
        }

        var plan: [(String, () -> PlaybackSource?)] = []
        if settings.offlineonly {
            plan = [("local", local), ("download", download)]
        } else {
            switch pref {
            case .some(.local): plan = [("local", local)]
            case .some(.spotify): plan = [("spotify", spotify)]
            case .some(.youtube): plan = [("download", download), ("youtube", youtube)]
            case .none:
                plan = [("local", local)]
                if settings.preferdownloads { plan.append(("download", download)) }
                if settings.defaultsource == "spotify" { plan += [("spotify", spotify), ("download", download), ("youtube", youtube)] }
                else if settings.defaultsource == "local" { plan += [("download", download), ("youtube", youtube)] }
                else { plan += [("download", download), ("youtube", youtube)] }
            }
        }
        var lasterr: Error = SourceError.unavailable(settings.offlineonly ? "offline mode: no local file or download for this track" : "no audio source for this track")
        for (name, make) in plan {
            guard let src = make() else { continue }
            do {
                try await src.prepare()
                Log.i(.source, "\(t.id) -> \(name) (\(src.kind.rawValue))")
                return src
            } catch {
                src.stop()
                lasterr = error
                Log.w(.source, "\(name) unavailable for \(t.id): \((error as? SourceError)?.text ?? (error as? ResolveError)?.text ?? error.localizedDescription)")
                if name == "spotify" && pref == nil {
                    // the default source is spotify but it can't run: say so instead of quietly playing something else
                    let why = (error as? SourceError)?.text ?? error.localizedDescription
                    toasts.show("spotify playback unavailable: \(why). playing from another source instead.", route: .source)
                }
                if pref != nil { break }   // an explicit per-track choice is never silently replaced
            }
        }
        throw lasterr
    }

    // AVAudioSession.setCategory/setActive can block for a long time; never call them on the main thread.
    private static let sessionqueue = DispatchQueue(label: "furmuse.audiosession", qos: .userInitiated)
    private var sessionready = false

    // fire and forget: used from sync paths (resume) where the category was already set at load time
    private func activatesession() {
        PlaybackEngine.sessionqueue.async {
            let s = AVAudioSession.sharedInstance()
            do {
                try s.setCategory(.playback, mode: .default, options: [])
                try s.setActive(true)
            } catch { Log.w(.playback, "audio session: \(error.localizedDescription)") }
        }
    }

    // awaitable: the engine must not start before the session is active on first load
    private func activatesessionasync() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            PlaybackEngine.sessionqueue.async {
                let s = AVAudioSession.sharedInstance()
                do {
                    try s.setCategory(.playback, mode: .default, options: [])
                    try s.setActive(true)
                } catch { Log.w(.playback, "audio session: \(error.localizedDescription)") }
                c.resume()
            }
        }
    }

    private func start(_ src: PlaybackSource, _ t: Track, generation gen: UUID) {
        guard gen == token else { src.stop(); return }
        loadtask = nil
        source = src
        sourcekind = src.kind
        sourceinfo = src.info
        duration = src.duration > 0 ? src.duration : t.duration
        src.onEnd = { [weak self, weak src] in
            guard let self, let src, self.token == gen, self.source === src else { return }
            self.itemended(source: src, generation: gen)
        }
        src.onFail = { [weak self, weak src] why in
            guard let self, let src, self.token == gen, self.source === src else { return }
            self.sourcefailed(t, why, source: src, generation: gen)
        }
        if let w = src as? WebPlaybackSource { wirewebremote(w, generation: gen) }
        if let s = src as? SpotifyPlaybackSource, s.connectmanaged {
            wirelibrespotremote(s, generation: gen)
        }
        src.apply(settings, playing: false)
        graph.apply(settings)
        let swap = swapping
        swapping = nil
        src.play(from: swap?.position ?? 0)
        loading = false
        isplaying = true
        starttick()
        Log.i(.playback, "started \(t.id) via \(src.kind.rawValue), \(String(format: "%.2fx", settings.speed))")
        if let s = swap {
            // same song, other audio source: no new start event (last.fm keeps counting the listen), and the pause state is kept
            position = s.position
            if !s.playing { pause() }
            onstatechange?()
            return
        }
        bus.send(.started(t))
        library.addtolibrary(t, via: "played", played: true)   // whatever is listened to through furmuse becomes part of the library
        onstatechange?()
    }

    // ---- switching the audio source while a song is playing --------------------------------------------------------------
    // the default source changed (settings → audio sources): the song that is playing moves to the new source at the same spot
    // and keeps playing or staying paused. only spotify <-> youtube; local files, downloads-only mode and connect-driven
    // playback are left alone.
    private var swapping: (position: Double, playing: Bool)?

    @MainActor
    func followsourcechange() {
        guard let t = current, t.isspotify, source != nil, !loading, !driven, !settings.offlineonly else { return }
        guard let k = sourcekind, k == .spotify || k == .youtube else { return }
        guard library.localurl(t.id) == nil, library.preferred(t.id) == nil else { return }
        let want: SourceKind
        switch settings.defaultsource {
        case "spotify": want = .spotify
        case "youtube": want = .youtube
        default: return
        }
        guard want != k else { return }
        let pos = livepos(), was = isplaying
        Log.i(.playback, "default source changed to \(want.rawValue): moving \(t.id) at \(fmttime(pos))")
        teardown()
        loading = true
        sourceinfo = ""
        sourcekind = nil
        retried = false
        swapping = (pos, was)
        onstatechange?()
        let gen = token
        loadtask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                let s = try await self.makesource(t, fresh: false)
                guard gen == self.token else { s.stop(); return }
                self.start(s, t, generation: gen)
            } catch {
                if error is CancellationError { return }
                guard gen == self.token else { return }
                self.swapping = nil
                self.fail(t, error)
            }
        }
    }

    // The Spotify renderer changed between Web Playback and librespot. Rebuild only an actively
    // playing Spotify source, preserving its position and pause state just like an audio-source swap.
    @MainActor
    func followspotifybackendchange() {
        guard let t = current, t.isspotify, sourcekind == .spotify, source != nil, !loading, !driven else { return }
        let isWeb = source is WebPlaybackSource
        guard isWeb != (settings.backend == .webplayback) else { return }
        let pos = livepos(), was = isplaying
        teardown()
        loading = true; sourceinfo = ""; sourcekind = nil; retried = false
        swapping = (pos, was)
        onstatechange?()
        let gen = token
        loadtask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let next = try await self.makesource(t, fresh: false)
                guard gen == self.token else { next.stop(); return }
                self.start(next, t, generation: gen)
            } catch {
                if error is CancellationError { return }
                guard gen == self.token else { return }
                self.swapping = nil
                self.fail(t, error)
            }
        }
    }

    private func sourcefailed(_ t: Track, _ why: String, source failedSource: PlaybackSource, generation gen: UUID) {
        guard token == gen, current == t, source === failedSource else {
            Log.i(.playback, "ignored stale failure for \(t.id)")
            return
        }
        Log.e(.playback, "source failed for \(t.id): \(why)")
        let kind = source?.kind
        if !retried, kind == .youtube {
            retried = true
            resolver.forget(t.id)
            let gen = token
            teardown()
            token = gen
            loading = true
            loadtask = Task { @MainActor [weak self] in
                guard let self = self else { return }
                do {
                    let s = try await self.makesource(t, fresh: true)
                    guard gen == self.token else { s.stop(); return }
                    self.start(s, t, generation: gen)
                } catch {
                    if error is CancellationError { return }
                    guard gen == self.token else { return }
                    self.fail(t, error)
                }
            }
        } else {
            teardown()
            fail(t, SourceError.failed(why))
        }
    }

    private func itemended(source endedSource: PlaybackSource, generation gen: UUID) {
        guard token == gen, source === endedSource, let t = current, isplaying else {
            Log.i(.playback, "ignored stale end callback")
            return
        }
        let dur = duration
        let at = source?.position ?? dur
        if dur - at > 5 { Log.w(.playback, "track ended early: source reported the end at \(fmttime(at)) of \(fmttime(dur)) (\(source?.info ?? "?"))") }
        Log.i(.playback, "track ended: \(t.id)")
        if settings.repeatmode == "one" {
            bus.send(.ended(t, dur))
            bus.send(.repeated(t))
            source?.play(from: 0)
            position = 0
            onstatechange?()
        } else if hasnext {
            teardown()
            bus.send(.ended(t, dur))
            index += 1
            load(queue[index])
        } else if settings.repeatmode == "all", !queue.isEmpty {
            teardown()
            bus.send(.ended(t, dur))
            index = 0
            load(queue[0])
        } else {
            teardown()
            bus.send(.ended(t, dur))
            position = 0
            bus.send(.stopped(t, 0))
            onstatechange?()
        }
    }

    // ---- spotify connect -----------------------------------------------------------------------------------------
    private var adopting = false
    private var adoptiontoken = UUID()
    private lazy var spotifyapi = SpotifyAPI(auth: auth)

    // call once at launch. the connect session itself is started by LibrespotSession.ensure (needs the playback sign-in).
    func startconnect() {
        lastpushedvolume = settings.volume
        LibrespotSession.shared.volumeprovider = { [weak self] in self?.settings.volume ?? 1 }
        LibrespotSession.shared.connectsink = { [weak self] e in self?.connectevent(e) }
        // web playback sdk: the same two hooks (volume, and playback another spotify client starts on this device)
        WebPlaybackSession.shared.volumeprovider = { [weak self] in self?.settings.volume ?? 1 }
        WebPlaybackSession.shared.adoptsink = { [weak self] s in self?.webstate(s) }
    }

    // ---- web playback sdk: connect-driven playback ---------------------------------------------------------------
    // every sdk state passes through here. a track that spotify (not furmuse) put on the sdk device and is playing is
    // adopted like a librespot connect session: it becomes the current track, queue and now playing.
    private func webstate(_ s: WebPlayerState?) {
        guard settings.backend == .webplayback, let s = s, !s.paused, let info = s.track, info.istrack else { return }
        guard !loading, !adopting else { return }
        // furmuse started something on this device a moment ago: its own source handles those states
        guard Date().timeIntervalSince(WebPlaybackSession.shared.lastcommandedplay) > 10 else { return }
        if let src = source as? WebPlaybackSource {
            if src.driven { return }                                  // already following spotify; the source retargets itself
            if src.wantsplaying || src.track.uri == info.uri { return }   // furmuse is playing this device itself
        }
        let request = UUID(); adoptiontoken = request
        Task { @MainActor [weak self] in
            guard let self else { return }
            let fallback = info.track
            let track: Track
            do { track = try await self.spotifyapi.track(info.id) }
            catch { track = fallback; Log.w(.connect, "spotify metadata lookup failed for \(info.id), using player state: \(error.localizedDescription)") }
            guard request == self.adoptiontoken else { return }
            self.adoptweb(track, s)
        }
    }

    private func adoptweb(_ t: Track, _ s: WebPlayerState) {
        library.remember([t])
        adopting = true
        leave(.skipped)
        adopting = false
        queue = [t]; index = 0
        current = t; position = Double(s.positionms) / 1000; duration = t.duration
        loading = true; sourceinfo = ""; sourcekind = nil
        onstatechange?()
        let gen = token
        loadtask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            await self.activatesessionasync()
            guard !Task.isCancelled, gen == self.token else { return }
            let src = WebPlaybackSource(track: t, auth: self.auth, driven: true)
            do { try await src.prepare() } catch {
                if error is CancellationError { return }
                guard gen == self.token else { return }
                self.fail(t, error); return
            }
            guard gen == self.token else { src.stop(); return }
            self.startwebdriven(src, t, s, generation: gen)
        }
    }

    private func startwebdriven(_ src: WebPlaybackSource, _ t: Track, _ s: WebPlayerState, generation gen: UUID) {
        guard gen == token else { src.stop(); return }
        loadtask = nil
        source = src
        sourcekind = .spotify
        sourceinfo = "spotify connect · web playback sdk (speed, eq and reverb don't apply)"
        duration = src.duration > 0 ? src.duration : t.duration
        src.onFail = { [weak self, weak src] why in
            guard let self, let src, self.token == gen, self.source === src else { return }
            self.sourcefailed(t, why, source: src, generation: gen)
        }
        wirewebremote(src, generation: gen)
        src.onretarget = { [weak self, weak src] old, new, natural in
            guard let self, let src, self.token == gen, self.source === src else { return }
            self.drivenretarget(old, new, natural)
        }
        src.ondrivenstopped = { [weak self, weak src] in
            guard let self, let src, self.token == gen, self.source === src else { return }
            self.drivenstopped()
        }
        src.adopt(with: s)
        loading = false
        isplaying = !s.paused
        if isplaying { starttick() }
        Log.i(.playback, "started \(t.id) via spotify connect (web playback sdk)")
        library.addtolibrary(t, via: "played", played: true)
        bus.send(.started(t))
        onstatechange?()
    }

    // spotify (the app, a speaker) paused or resumed this device: keep furmuse's play state and now playing in step
    private func wirewebremote(_ src: WebPlaybackSource, generation gen: UUID) {
        src.onremoteplaying = { [weak self, weak src] playing in
            guard let self, let src, self.token == gen, self.source === src else { return }
            self.remoteplaying(playing)
        }
    }

    private func remoteplaying(_ playing: Bool) {
        guard let t = current, playing != isplaying else { return }
        isplaying = playing
        if playing { starttick(); bus.send(.resumed(t, livepos())) }
        else { position = livepos(); stoptick(); bus.send(.paused(t, position)) }
        Log.i(.connect, playing ? "resumed from spotify" : "paused from spotify")
        onstatechange?()
    }

    // A librespot source launched from Furmuse's own queue becomes Connect-managed as soon as
    // Spotify activates this device. From then on another Spotify client can replace the track or
    // pause/resume it, so forward the source's state into the engine just like driven playback.
    private func wirelibrespotremote(_ src: SpotifyPlaybackSource, generation gen: UUID) {
        src.ondrivenstate = { [weak self, weak src] playing in
            guard let self, let src, self.token == gen, self.source === src else { return }
            self.remoteplaying(playing)
        }
        src.onretarget = { [weak self, weak src] old, new, natural in
            guard let self, let src, self.token == gen, self.source === src else { return }
            self.drivenretarget(old, new, natural)
        }
    }

    private func connectevent(_ e: BridgeEvent) {
        let session = LibrespotSession.shared
        switch e {
        case .connectactive(let on):
            if on {
                // a client picked this device: report our volume so its slider matches
                lastpushedvolume = settings.volume
                session.bridge.connect(.volume, arg: Int((settings.volume * 65535).rounded()))
            } else if driven {
                Log.i(.connect, "released by spotify, stopping connect playback")
                leaveconnect()
            }
        case .volume(let v):
            let x = Double(v) / 65535
            if abs(x - settings.volume) > 0.004 {
                lastpushedvolume = x      // came from spotify: don't echo it back
                settings.volume = x
                Log.i(.connect, String(format: "volume %.0f%% (from spotify)", x * 100))
            }
        case .trackchanged(let t):
            guard session.connectisactive else { return }   // a furmuse-initiated load also emits this; ignore it
            let fallback = t.track
            let request = UUID(); adoptiontoken = request
            // Audio has already changed inside librespot. Never hold the visible player on the old
            // song while a Web API metadata request is in flight: adopt the bridge metadata now,
            // then enrich the same identity when/if Spotify answers.
            library.remember([fallback])
            if let src = source as? SpotifyPlaybackSource, src.driven || src.connectmanaged { src.retarget(fallback, immediate: true) }
            else { adoptconnect(fallback) }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let track: Track
                do { track = try await self.spotifyapi.track(fallback.id) }
                catch { Log.w(.connect, "spotify metadata lookup failed for \(fallback.id), keeping librespot event: \(error.localizedDescription)"); return }
                guard request == self.adoptiontoken, session.connectisactive else { return }
                guard self.current?.id == track.id else { return }
                self.library.remember([track])
                self.current = track
                if self.queue.indices.contains(self.index) { self.queue[self.index] = track }
                self.duration = track.duration
                Log.i(.connect, "enriched spotify connect metadata for \(track.id)")
                self.onstatechange?()
            }
        default: break
        }
    }

    // spotify put a track on this device while furmuse was idle or playing something else
    private func adoptconnect(_ t: Track) {
        adopting = true
        leave(.skipped)
        adopting = false
        queue = [t]; index = 0
        current = t; position = 0; duration = t.duration
        loading = true; sourceinfo = ""; sourcekind = nil
        onstatechange?()
        let gen = token
        loadtask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            await self.activatesessionasync()
            guard !Task.isCancelled, gen == self.token else { return }
            let src = SpotifyPlaybackSource(track: t, graph: self.graph, auth: self.auth, driven: true)
            do { try await src.prepare() } catch {
                if error is CancellationError { return }
                guard gen == self.token else { return }
                self.fail(t, error); return
            }
            guard gen == self.token else { src.stop(); return }
            self.startdriven(src, t, generation: gen)
        }
    }

    private func startdriven(_ src: SpotifyPlaybackSource, _ t: Track, generation gen: UUID) {
        guard gen == token else { src.stop(); return }
        loadtask = nil
        source = src
        sourcekind = .spotify
        sourceinfo = "spotify connect · librespot pcm"
        duration = t.duration
        src.onFail = { [weak self, weak src] why in
            guard let self, let src, self.token == gen, self.source === src else { return }
            self.sourcefailed(t, why, source: src, generation: gen)
        }
        src.ondrivenstate = { [weak self, weak src] playing in
            guard let self, let src, self.token == gen, self.source === src else { return }
            self.drivenstate(playing)
        }
        src.onretarget = { [weak self, weak src] old, new, natural in
            guard let self, let src, self.token == gen, self.source === src else { return }
            self.drivenretarget(old, new, natural)
        }
        src.ondrivenstopped = { [weak self, weak src] in
            guard let self, let src, self.token == gen, self.source === src else { return }
            self.drivenstopped()
        }
        src.apply(settings, playing: false)
        graph.apply(settings)
        src.adopt()
        loading = false
        isplaying = true
        starttick()
        Log.i(.playback, "started \(t.id) via spotify connect")
        library.addtolibrary(t, via: "played", played: true)
        bus.send(.started(t))
        onstatechange?()
    }

    private func drivenstate(_ playing: Bool) {
        guard let t = current, driven, playing != isplaying else { if playing { starttick() }; return }
        isplaying = playing
        if playing { starttick(); bus.send(.resumed(t, livepos())) }
        else { position = livepos(); stoptick(); bus.send(.paused(t, position)) }
        onstatechange?()
    }

    private func drivenretarget(_ old: Track, _ new: Track, _ natural: Bool) {
        bus.send(natural ? .ended(old, old.duration) : .skipped(old, position))
        library.remember([new])
        queue = [new]; index = 0
        current = new; position = 0; duration = new.duration
        Log.i(.playback, "spotify connect moved to \(new.id)")
        library.addtolibrary(new, via: "played", played: true)
        bus.send(.started(new))
        onstatechange?()
    }

    private func drivenstopped() {
        guard let t = current, driven else { return }
        isplaying = false
        stoptick()
        position = 0
        bus.send(.stopped(t, 0))
        onstatechange?()
    }

    // spotify moved playback to another device (or released us): stop rendering, keep showing the last track
    private func leaveconnect() {
        guard current != nil else { return }
        let p = livepos()
        guard let t = current else { return }
        adopting = true
        teardown()
        adopting = false
        position = p
        bus.send(.skipped(t, p))
        onstatechange?()
    }

    private func starttick() {
        stoptick()
        tick = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self, let s = self.source else { return }
            self.position = s.position
            if s.duration > 0, abs(s.duration - self.duration) > 1 { self.duration = s.duration; self.onstatechange?() }
        }
    }

    private func stoptick() { tick?.invalidate(); tick = nil }
}

typealias PlayerController = PlaybackEngine
