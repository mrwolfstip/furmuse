import Foundation
import AVFoundation
import UIKit
import Network

// owns the single librespot session for the app and routes its events to whichever source is active.
// it is also what the settings screen reads to explain, in plain words, why spotify playback can't start.
final class LibrespotSession: ObservableObject, @unchecked Sendable {
    static let shared = LibrespotSession()
    let bridge: LibrespotBridge = makelibrespotbridge()
    var handler: ((BridgeEvent) -> Void)?
    // spotify connect: the engine listens here for tracks / volume / activity that spotify clients cause
    var connectsink: ((BridgeEvent) -> Void)?
    var volumeprovider: () -> Double = { 1 }
    private(set) var connectisactive = false     // a spotify client currently controls this device (main thread)
    private weak var lastauth: SpotifyAuth?
    private var restarting = false
    private(set) var starting = false
    @Published private(set) var status = "not started"
    @Published private(set) var lasterror: String?
    @Published private(set) var launchingPlayback = false
    private var detail: String?       // last error text from the rust side (login failures arrive as an event first)

    var available: Bool { bridge.available }

    // false while the web playback sdk is the active backend: librespot then neither connects nor restarts, so only one
    // "furmuse" connect device exists. it stays installed and is switched back on from settings → audio source.
    private(set) var enabled = true
    func setenabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if !on {
            connectisactive = false
            let b = bridge
            DispatchQueue.global(qos: .utility).async { b.shutdown() }   // blocks ~0.4 s inside rust
            setstatus("off (web playback sdk is the active backend)", nil)
            Log.i(.librespot, "librespot switched off (web playback sdk backend)")
        } else {
            setstatus("not started", nil)
            Log.i(.librespot, "librespot switched on")
        }
    }

    // what spotify's device picker shows
    static let devicename = "Furmuse"
    // spotify tells devices apart by id: random once per install (never hardcoded), so reinstalling doesn't leave a ghost
    // entry per launch and the same install is always the same device.
    static var deviceid: String {
        let k = "wolfified.connect.deviceid"
        if let v = UserDefaults.standard.string(forKey: k), !v.isEmpty { return v }
        let v = UUID().uuidString.lowercased()
        UserDefaults.standard.set(v, forKey: k)
        return v
    }
    static var devicetype: Int { UIDevice.current.userInterfaceIdiom == .pad ? 2 : 3 }   // tablet / smartphone

    func clearconnectactive() { connectisactive = false }

    func setLaunchingPlayback(_ value: Bool) { launchingPlayback = value }

    // the first thing that stops spotify playback, in words the user can act on. nil = nothing known to be wrong.
    @MainActor
    func blocker(auth: SpotifyAuth) -> String? {
        if !bridge.available { return "the librespot library isn't built into this app yet. run ./rust/build.sh sim in terminal, then build again in xcode (see rust/README.md)" }
        if !auth.connected { return "spotify isn't connected. settings → spotify → connect" }
        if !LibrespotAuth.shared.connected { return "spotify playback needs its own one-time sign-in. settings → audio source → sign in for playback" }
        return nil
    }

    // connects once; later calls return immediately while the session is alive.
    @MainActor
    func ensure(auth: SpotifyAuth) async throws {
        if let why = blocker(auth: auth) { setstatus("blocked", why); throw SourceError.unavailable(why) }
        lastauth = auth
        if bridge.connected { return }
        guard !starting else { throw SourceError.unavailable("spotify session is still starting") }
        starting = true
        defer { starting = false }
        detail = nil
        setstatus("connecting…", nil)
        let token: String
        do { token = try await LibrespotAuth.shared.token() } catch {
            setstatus("failed", "couldn't get a playback token, sign in for playback again")
            throw SourceError.unavailable("couldn't get a playback token, sign in for playback again")
        }
        Log.i(.librespot, "starting librespot session")
        Log.i(.librespot, "authentication method: access token, token present: yes, length: \(token.count), client id: librespot default (keymaster)")
        let b = bridge
        // at most 2 attempts, and only when the failure looks like a transient network problem.
        // librespot itself already tries up to 6 access points inside one attempt.
        var attempt = 0
        while true {
            attempt += 1
            do {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            let vol = Int((LibrespotSession.shared.volumeprovider() * 65535).rounded())
                            try b.start(token: token, clientid: "", devicename: LibrespotSession.devicename, deviceid: LibrespotSession.deviceid,
                                        devicetype: LibrespotSession.devicetype, volume: vol) { e in LibrespotSession.shared.route(e) }
                            c.resume()
                        } catch { c.resume(throwing: error) }
                    }
                }
                break
            } catch {
                let f = (error as? LibrespotStartError)?.failure ?? .other
                let raw = detail ?? error.localizedDescription
                Log.e(.librespot, "librespot start failed (attempt \(attempt), class: \(f.rawValue)): \(raw)")
                if f == .network && attempt < 2 {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    continue
                }
                let user = LibrespotSession.usermessage(f)
                setstatus("failed", user)
                throw SourceError.failed(user)
            }
        }
        Log.i(.librespot, "librespot session connected")
        setstatus("connected", nil)
    }

    // plain-language text for the ui; the exact librespot error stays in diagnostics only
    static func usermessage(_ f: LibrespotFailure) -> String {
        let tail = "view diagnostics for details."
        switch f {
        case .network: return "spotify connection failed: networking. librespot couldn't reach spotify. check your connection and try again. \(tail)"
        case .rejected, .noToken: return "spotify connection failed: authentication. try signing in to spotify again (settings → spotify → disconnect, then connect). \(tail)"
        case .apRejected: return "spotify connection failed: spotify's servers refused this client. this is not a sign-in problem you can fix by retrying. \(tail)"
        case .runtime, .other: return "spotify connection failed: librespot couldn't establish a session. try reconnecting or signing in again. \(tail)"
        }
    }

    private func setstatus(_ s: String, _ err: String?) {
        let apply = { self.status = s; self.lasterror = err }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }

    func route(_ e: BridgeEvent) {
        switch e {
        case .sink(let s): Log.i(.pcm, "sink \(s)")
        case .disconnected(let s):
            Log.w(.librespot, "session disconnected: \(s)"); setstatus("disconnected", s)
            connectisactive = false
            scheduleRestart()
        case .connectactive(let on): connectisactive = on; Log.i(.connect, on ? "a spotify client is controlling this device" : "spotify released this device")
        case .controller(let n): Log.i(.connect, "controlled by \(n)")
        case .error(let s): Log.e(.librespot, s); detail = s
        case .log(let level, let t):
            if level == 1 { Log.e(.librespot, t) } else if level == 2 { Log.w(.librespot, t) } else { Log.i(.librespot, t) }
            return   // diagnostics only; never forwarded to the playback source
        default: break
        }
        connectsink?(e)
        handler?(e)
    }

    // the session dropped (network change, token expiry, spotify closed it): bring it back with a fresh token so the
    // device reappears in spotify's device picker. one attempt per loss; a failure is visible in status/diagnostics.
    private func scheduleRestart() {
        guard enabled, let auth = lastauth, !restarting else { return }
        restarting = true
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self = self else { return }
            self.bridge.shutdown()   // blocks ~0.4 s inside rust: keep it off the main thread
            Task { @MainActor in
                defer { self.restarting = false }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                do { try await self.ensure(auth: auth); Log.i(.connect, "connect session restored") }
                catch { Log.e(.connect, "couldn't restore the connect session: \((error as? SourceError)?.text ?? error.localizedDescription)") }
            }
        }
    }

    // ---- keep the connect device alive ------------------------------------------------------------------------------
    // started once at launch. it (1) brings the session up as soon as the playback sign-in exists, with no other Spotify
    // device involved, and (2) keeps retrying whenever the session is gone: network comes back, app returns to the
    // foreground, or a 20 s watchdog finds no session. rust reports a dropped connect task as a disconnect event, which
    // goes through scheduleRestart above; this is the safety net for failed restarts and for launches without network.
    private var supervising = false
    private var monitor: NWPathMonitor?
    private var watchdog: Timer?
    private var failures = 0
    private var nextattempt = Date.distantPast

    @MainActor
    func supervise(auth: SpotifyAuth) {
        lastauth = auth
        guard !supervising else { kick(); return }
        supervising = true
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in self?.nextattempt = .distantPast; self?.kick() }
        }
        m.start(queue: DispatchQueue(label: "furmuse.connect.path"))
        monitor = m
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.nextattempt = .distantPast; self?.kick() }
        }
        watchdog = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in Task { @MainActor in self?.kick() } }
        kick()
    }

    // one attempt if nothing is connected, nothing is starting and the backoff has elapsed
    @MainActor
    func kick() {
        guard enabled, supervising, let auth = lastauth, available, !bridge.connected, !starting, !restarting, Date() >= nextattempt else { return }
        // not signed in for playback yet: nothing to retry until that changes (Services calls supervise again on sign-in)
        if blocker(auth: auth) != nil { return }
        Task { @MainActor in
            do {
                try await self.ensure(auth: auth)
                self.failures = 0
                Log.i(.connect, "connect device is up (visible in the spotify device picker as \"\(LibrespotSession.devicename)\")")
            } catch {
                self.failures += 1
                let wait = min(60.0, 3.0 * pow(2.0, Double(min(self.failures, 5))))   // 6 s, 12 s ... capped at 60 s
                self.nextattempt = Date().addingTimeInterval(wait)
                Log.w(.connect, "connect start failed (attempt \(self.failures)), retrying in \(Int(wait)) s")
            }
        }
    }

    // User-requested recovery ignores the supervisor backoff and tears down the possibly wedged
    // Rust session before establishing a fresh, newly-tokened one.
    @MainActor
    func reconnect(auth: SpotifyAuth) async throws {
        lastauth = auth
        nextattempt = .distantPast
        failures = 0
        restarting = false
        let b = bridge
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { b.shutdown(); continuation.resume() }
        }
        setstatus("reconnecting…", nil)
        try await ensure(auth: auth)
        Log.i(.connect, "manual librespot reconnect succeeded")
    }

    func shutdown() { bridge.shutdown(); setstatus("not started", nil); Log.i(.librespot, "librespot shut down") }
}

// librespot's side of the shared connect-driven interface (the engine never needs to know which backend it is talking to)
extension SpotifyPlaybackSource: ConnectDrivenSource {
    func connectnext() { LibrespotSession.shared.bridge.connect(.next, arg: 0) }
    func connectprevious() { LibrespotSession.shared.bridge.connect(.previous, arg: 0) }
    func connectrelease() { LibrespotSession.shared.bridge.connect(.disconnect, arg: 1) }
}

// state shared with the realtime render callback. plain fields only: no locks, no allocation, no logging there.
private final class PCMRenderContext {
    let bridge: LibrespotBridge
    let scratch: UnsafeMutablePointer<Float>
    let cap = 4096
    var silent = true          // true: output silence and consume nothing (paused, prebuffering)
    var consumed: Int64 = 0    // frames actually taken from the buffer = track time at the sample rate
    var underruns: UInt64 = 0
    init(bridge: LibrespotBridge) {
        self.bridge = bridge
        scratch = UnsafeMutablePointer<Float>.allocate(capacity: 4096 * 2)
        scratch.initialize(repeating: 0, count: 4096 * 2)
    }
    deinit { scratch.deallocate() }
}

// spotify audio decoded by librespot, kept in memory only, rendered through the shared graph.
// pcm never touches disk: it lives in the rust ring buffer and in this render callback's scratch buffer.
final class SpotifyPlaybackSource: PlaybackSource {
    let kind: SourceKind = .spotify
    private(set) var info = "spotify · librespot pcm"
    var duration: Double { track.duration }
    var onEnd: (() -> Void)?
    var onFail: ((String) -> Void)?

    private(set) var track: Track
    private let graph: SharedAudioGraph
    private let auth: SpotifyAuth
    private let session = LibrespotSession.shared
    private let rate = 44100.0
    private let ctx: PCMRenderContext
    private var node: AVAudioSourceNode?
    private var base = 0.0
    private var consumedatbase: Int64 = 0
    private var timer: Timer?
    private var lastunderruns: UInt64 = 0
    private var endpending = false
    private var ended = false
    private var prebuffering = false
    private var prebufferstart = Date()
    private var held = 0.0
    private var wantsplay = false

    // ---- spotify connect ----
    // driven = a spotify client (not furmuse's own queue) chose the track. the player is controlled by Spirc, so
    // transport goes through connect commands and position comes from the pcm that was actually rendered.
    let driven: Bool
    // Furmuse-started playback is still launched through Spotify Connect. It remains false for `driven` so Furmuse's
    // own queue stays authoritative, but transport/state use Spirc after the Web API activates this registered device.
    let connectmanaged: Bool
    var ondrivenstate: ((Bool) -> Void)?                   // true playing, false paused
    var onretarget: ((Track, Track, Bool) -> Void)?        // old, new, natural end-of-track hand-over
    var ondrivenstopped: (() -> Void)?
    private var boundary: Int64?          // rendered-frame count at which the previous track's buffered tail ends
    private var pendingtrack: Track?
    private var stoppending = false
    private var correctedpause = false

    init(track: Track, graph: SharedAudioGraph, auth: SpotifyAuth, driven: Bool = false) {
        self.driven = driven
        self.connectmanaged = !driven
        self.track = track; self.graph = graph; self.auth = auth
        ctx = PCMRenderContext(bridge: LibrespotSession.shared.bridge)
    }

    @MainActor
    func prepare() async throws {
        try await session.ensure(auth: auth)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let c = ctx
        let n = AVAudioSourceNode(format: fmt) { _, _, frameCount, abl -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(abl)
            let want = Int(frameCount)
            guard list.count >= 2, let l = list[0].mData?.assumingMemoryBound(to: Float.self), let r = list[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            var got = 0
            if !c.silent {
                while got < want {
                    let chunk = min(want - got, c.cap)
                    let k = c.bridge.read(c.scratch, frames: chunk)
                    var i = 0
                    while i < k { l[got + i] = c.scratch[2 * i]; r[got + i] = c.scratch[2 * i + 1]; i += 1 }
                    got += k
                    if k < chunk { break }
                }
                c.consumed &+= Int64(got)
                if got < want { c.underruns &+= 1 }
            }
            var j = got
            while j < want { l[j] = 0; r[j] = 0; j += 1 }
            return noErr
        }
        node = n
        graph.attach(n, format: fmt)
        graph.onreset = { }
        try graph.start()
        session.handler = { [weak self] e in self?.handle(e) }
        Log.i(.pcm, "pcm source node created for \(track.id)")
    }

    var position: Double {
        let p = base + Double(ctx.consumed - consumedatbase) / rate
        return wantsplay || !ended ? min(max(p, 0), duration > 0 ? duration : p) : held
    }

    private func resetbase(_ t: Double) {
        base = t
        consumedatbase = ctx.consumed
    }

    // spotify already told the player what to load; just start tracking time and open the render gate
    func adopt() {
        ended = false; endpending = false; wantsplay = true
        boundary = nil; pendingtrack = nil; stoppending = false
        ctx.silent = true
        resetbase(0)
        try? graph.start()
        prebuffering = true
        prebufferstart = Date()
        starttimer()
        Log.i(.connect, "adopted \(track.id) from spotify connect")
    }

    // audible position of the pcm head given the decoder position spotify reports (the ring holds `buffered` frames
    // the decoder already passed)
    private func audible(_ ms: Int) -> Double { max(0, Double(ms) / 1000 - Double(session.bridge.buffered) / rate) }

    func retarget(_ t: Track, immediate: Bool = false) {
        guard driven || connectmanaged, t.id != track.id || boundary != nil || pendingtrack != nil else { return }
        if boundary != nil, !immediate { pendingtrack = t; return }   // natural change: the old track's tail is still playing
        let old = track
        if immediate {
            // A user picked another track in a Spotify client. Its TrackChanged event is
            // authoritative and must not sit behind an EndOfTrack boundary left by the old item.
            boundary = nil
            pendingtrack = nil
            endpending = false
            stoppending = false
        }
        track = t
        ended = false; endpending = false; stoppending = false
        ctx.silent = true
        resetbase(0)
        prebuffering = true; prebufferstart = Date()
        Log.i(.connect, "retargeting immediately from \(old.id) to \(t.id)\(immediate ? " (external selection)" : "")")
        onretarget?(old, t, false)
    }

    func play(from t: Double) {
        ended = false; endpending = false; wantsplay = true
        ctx.silent = true
        session.bridge.flush()
        resetbase(t)
        try? graph.start()
        prebuffering = true
        prebufferstart = Date()
        if connectmanaged {
            session.setLaunchingPlayback(true)
            let ok = session.bridge.connectload(trackid: track.id, positionms: Int(t * 1000))
            session.setLaunchingPlayback(false)
            if !ok {
                wantsplay = false
                onFail?("librespot couldn't activate its Spotify Connect session")
            } else {
                Log.i(.connect, "started \(track.id) through Spirc as the active Spotify Connect device")
            }
        } else {
            session.bridge.load(trackid: track.id, play: true, positionms: Int(t * 1000))
        }
        starttimer()
        Log.i(.playback, "spotify load \(track.id) at \(String(format: "%.1f", t))s")
    }

    func resume() {
        wantsplay = true
        try? graph.start()
        if driven || connectmanaged {
            correctedpause = false
            session.bridge.connect(.play, arg: 0)
            prebuffering = true; prebufferstart = Date()
            return
        }
        session.bridge.play()
        ctx.silent = false
    }

    func pause() {
        held = position
        wantsplay = false
        ctx.silent = true
        if driven || connectmanaged { session.bridge.connect(.pause, arg: 0) } else { session.bridge.pause() }
    }

    func seek(to t: Double) {
        let target = min(max(0, t), duration > 0 ? duration : t)
        ctx.silent = true
        session.bridge.flush()
        resetbase(target)
        endpending = false
        boundary = nil
        if driven || connectmanaged { session.bridge.connect(.seek, arg: Int(target * 1000)) } else { session.bridge.seek(ms: Int(target * 1000)) }
        // a few packets decoded before the seek landed may still arrive; prebuffer gate lets the new data lead
        prebuffering = true
        prebufferstart = Date()
        Log.i(.playback, "spotify seek to \(String(format: "%.1f", target))s")
    }

    func stop() {
        timer?.invalidate(); timer = nil
        ctx.silent = true
        session.handler = nil
        if connectmanaged { session.bridge.connect(.disconnect, arg: 1) }
        else if !driven { session.bridge.pause() }
        session.bridge.flush()
        graph.detach()
        node = nil
    }

    private func starttimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func poll() {
        let u = ctx.underruns
        if u != lastunderruns {
            Log.w(.pcm, "underrun x\(u - lastunderruns), buffered \(session.bridge.buffered) frames, rust-side \(session.bridge.underruns)")
            lastunderruns = u
        }
        if prebuffering && wantsplay {
            let buffered = session.bridge.buffered
            // 180 ms is enough to absorb normal decoder jitter without imposing a clearly audible
            // half-second delay on every play/resume/seek. The existing underrun recovery remains.
            if buffered >= Int(rate * 0.18) || endpending || Date().timeIntervalSince(prebufferstart) > 1.5 {
                prebuffering = false
                ctx.silent = false
                Log.i(.pcm, "prebuffer released at \(buffered) frames")
            }
        }
        if driven || connectmanaged {
            polldriven()
            return
        }
        if endpending, !ended, session.bridge.buffered == 0 {
            ended = true
            held = duration
            timer?.invalidate(); timer = nil
            Log.i(.playback, "spotify track drained: \(track.id)")
            onEnd?()
        }
    }

    private func polldriven() {
        if let b = boundary, ctx.consumed >= b {
            boundary = nil
            endpending = false
            if let p = pendingtrack {
                pendingtrack = nil
                let old = track
                track = p
                resetbase(0)    // seamless: the next track's audio is already behind the old tail in the buffer
                onretarget?(old, p, true)
            }
        }
        if stoppending, boundary == nil {
            stoppending = false
            ctx.silent = true
            wantsplay = false
            if connectmanaged { onEnd?() } else { ondrivenstopped?() }
        }
    }

    private func handledriven(_ e: BridgeEvent) {
        switch e {
        case .playing(let ms):
            resetbase(audible(ms))
            wantsplay = true
            stoppending = false
            correctedpause = false
            if ctx.silent && !prebuffering { prebuffering = true; prebufferstart = Date() }
            ondrivenstate?(true)
        case .paused(let ms):
            ctx.silent = true
            wantsplay = false
            held = audible(ms)
            ondrivenstate?(false)
            // the decoder is up to 0.75 s ahead of what was heard. tell spotify the heard position so a resume, and the
            // position other clients show, agree with the audio
            let lead = session.bridge.buffered
            if lead > 4410, !correctedpause {
                correctedpause = true
                session.bridge.connect(.seek, arg: Int(held * 1000))
            }
        case .remoteseek(let ms), .seeked(let ms):
            ctx.silent = true
            resetbase(Double(ms) / 1000)
            boundary = nil; endpending = false
            prebuffering = wantsplay; prebufferstart = Date()
        case .endoftrack:
            endpending = true
            boundary = ctx.consumed + Int64(session.bridge.buffered)
        case .stopped:
            stoppending = true       // lets a buffered tail play out; a takeover by another device has no tail (boundary nil)
        case .unavailable:
            Log.e(.spotify, "spotify can't play \(track.id)")
        case .disconnected(let why):
            onFail?("spotify session lost: \(why)")
        case .error(let why):
            Log.e(.librespot, why)
        default: break
        }
    }

    private func handle(_ e: BridgeEvent) {
        if driven || connectmanaged { handledriven(e); return }
        switch e {
        case .endoftrack: endpending = true
        case .unavailable:
            Log.e(.spotify, "spotify can't play \(track.id)")
            onFail?("spotify couldn't play this track")
        case .disconnected(let why):
            onFail?("spotify session lost: \(why)")
        case .error(let why):
            Log.e(.librespot, why)
        case .playing(let ms):
            let drift = abs(Double(ms) / 1000 - position)
            if drift > 1.5 { Log.w(.pcm, "librespot says \(ms)ms, we are at \(String(format: "%.1f", position * 1000))ms (buffer lead expected)") }
        default: break
        }
    }
}
