import Foundation

// what the engine needs from a spotify source that can also be driven by another spotify client (connect):
// next / previous / release go back through that backend's own connect path. both backends implement this.
protocol ConnectDrivenSource: PlaybackSource {
    var driven: Bool { get }
    func connectnext()
    func connectprevious()
    func connectrelease()
}

// the spotify source when the backend is the Web Playback SDK.
//
// the audio is rendered by the SDK inside its web view, so unlike youtube / local / librespot it does NOT pass through
// SharedAudioGraph: speed, pitch, eq, bass and reverb cannot be applied to it. position, pause, seek and track state are
// real and come from the SDK's player_state_changed events (extrapolated between events from the local clock).
//
// non-driven: furmuse's own queue chose the track (it is started through the Web API on the SDK device).
// driven: another spotify client chose it (transferred playback / started on this device), furmuse follows.
final class WebPlaybackSource: PlaybackSource, ConnectDrivenSource {
    let kind: SourceKind = .spotify
    private(set) var info = "spotify · web playback sdk (speed, eq and reverb don't apply)"
    var onEnd: (() -> Void)?
    var onFail: ((String) -> Void)?

    let driven: Bool
    private(set) var track: Track
    private let auth: SpotifyAuth
    private let session = WebPlaybackSession.shared

    // callbacks used for playback that spotify (not furmuse) changed
    var onremoteplaying: ((Bool) -> Void)?                  // true playing, false paused
    var onretarget: ((Track, Track, Bool) -> Void)?         // old, new, natural end-of-track hand-over
    var ondrivenstopped: (() -> Void)?

    private var state: WebPlayerState?       // latest state for THIS track
    private var startposition = 0.0
    private(set) var wantsplay = false
    private var seen = false                 // the SDK has reported this track playing at least once
    private var ended = false
    private var lastposms = 0
    private var held = 0.0
    private var lastcommand = Date.distantPast
    private var starting: Task<Void, Never>?
    private var warnedeffects = false

    var wantsplaying: Bool { wantsplay }
    var duration: Double {
        if let s = state, s.durationms > 0 { return Double(s.durationms) / 1000 }
        return track.duration
    }

    init(track: Track, auth: SpotifyAuth, driven: Bool = false) {
        self.track = track
        self.auth = auth
        self.driven = driven
    }

    @MainActor
    func prepare() async throws {
        _ = try await session.ensureready()
        session.statehandler = { [weak self] s in self?.handle(s) }
        session.errorhandler = { [weak self] why in self?.playbackerror(why) }
    }

    var position: Double {
        guard let s = state else { return wantsplay || startposition > 0 ? startposition : held }
        let p = Double(s.liveposition()) / 1000
        return min(max(p, 0), duration > 0 ? duration : p)
    }

    private func local() { lastcommand = Date() }

    func play(from t: Double) {
        wantsplay = true; ended = false; seen = false
        startposition = t; state = nil; lastposms = 0
        session.statehandler = { [weak self] s in self?.handle(s) }
        local()
        starting?.cancel()
        let uri = track.uri
        starting = Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                try await self.session.start(uri: uri, positionms: Int(t * 1000))
            } catch {
                if Task.isCancelled { return }
                self.wantsplay = false
                self.onFail?((error as? SourceError)?.text ?? error.localizedDescription)
            }
        }
        Log.i(.webplayback, "play \(track.id) at \(String(format: "%.1f", t))s via the sdk device")
    }

    func resume() {
        wantsplay = true
        local()
        // the device lost its player state (another device took over, or the sdk reconnected): start the track again
        if session.state == nil || state == nil {
            let at = held
            Log.i(.webplayback, "resume with no sdk state, restarting the track at \(String(format: "%.1f", at))s")
            play(from: at)
            return
        }
        Task { @MainActor in session.resumeFromUserGesture() }
    }

    func pause() {
        held = position
        wantsplay = false
        local()
        session.send("pause")
    }

    func seek(to t: Double) {
        let target = min(max(0, t), duration > 0 ? duration : t)
        local()
        // reflect the seek immediately; the next sdk state confirms it
        if var s = state { s.positionms = Int(target * 1000); s.received = Date(); state = s } else { startposition = target }
        held = target
        session.send("seek", Double(Int(target * 1000)))
        Log.i(.webplayback, "seek to \(String(format: "%.1f", target))s")
    }

    func stop() {
        starting?.cancel(); starting = nil
        session.statehandler = nil
        session.errorhandler = nil
        // furmuse is done with this track: don't leave spotify playing it on the device in the background
        if wantsplay || (session.state.map { !$0.paused } ?? false) { session.send("pause") }
        wantsplay = false
    }

    func apply(_ s: Settings, playing: Bool) {
        // honest about what this backend can't do instead of silently ignoring the sliders
        let touched = s.speed != 1 || s.pitchsemis != 0 || s.eqon || s.bass != 0 || s.reverbon
        if touched && !warnedeffects {
            warnedeffects = true
            Log.w(.effects, "speed / pitch / eq / reverb are set, but the web playback sdk's audio doesn't pass through furmuse's audio graph, so they don't apply to this track. librespot does support them.")
        }
    }

    // ---- connect-driven control -------------------------------------------------------------------------------------
    func connectnext() { local(); session.send("next") }
    func connectprevious() { local(); session.send("prev") }
    // there is no "leave the session" call in the SDK: pausing is what lets furmuse play something else cleanly,
    // and the device stays registered so spotify clients can still pick it
    func connectrelease() { session.send("pause") }

    // playback started by another spotify client: begin tracking it
    func adopt(with s: WebPlayerState) {
        wantsplay = !s.paused; ended = false; seen = !s.paused
        state = s; lastposms = s.positionms
        Log.i(.connect, "adopted \(track.id) from spotify connect (web playback sdk)")
    }

    private func playbackerror(_ why: String) {
        guard wantsplay || driven else { return }
        Log.e(.webplayback, "playback error: \(why)")
        onFail?(why)
    }

    // ---- state from the sdk -----------------------------------------------------------------------------------------
    private func handle(_ s: WebPlayerState?) {
        guard let s = s else {
            // null state: this device is no longer the active player (another device took over, or the session dropped)
            if driven { ondrivenstopped?() }
            else if wantsplay && seen && Date().timeIntervalSince(lastcommand) > 2 {
                wantsplay = false
                onFail?("spotify moved playback to another device")
            }
            return
        }
        guard let cur = s.track else { return }

        if cur.uri != track.uri {
            if driven {
                guard cur.istrack else { return }
                let old = track
                let natural = !s.paused && s.previous.contains(old.uri)
                track = cur.track
                state = s; lastposms = s.positionms; ended = false; seen = !s.paused
                wantsplay = !s.paused
                onretarget?(old, track, natural)
            }
            // not driven: a stale state from before our track loaded, or something spotify started on its own. ignored.
            return
        }

        // end of track: paused at 0 with the track already in its own "previous" list (the SDK's way of saying it finished),
        // or paused at 0 after having been within a few seconds of the end
        let nearend = s.durationms > 0 && lastposms >= s.durationms - 3000
        if s.paused && s.positionms == 0 && seen && !ended && wantsplay && (s.previous.contains(track.uri) || nearend) {
            ended = true
            held = duration
            state = s
            session.send("pause")
            Log.i(.playback, "spotify track finished: \(track.id)")
            if driven { ondrivenstopped?() } else { onEnd?() }
            return
        }

        state = s
        lastposms = s.positionms
        if !s.paused { seen = true }

        // someone else (the spotify app, a speaker's controls) paused or resumed this device: follow it.
        // changes right after furmuse's own command are echoes of that command, not remote changes.
        let playing = !s.paused
        if playing != wantsplay && Date().timeIntervalSince(lastcommand) > 4 && !s.loading {
            wantsplay = playing
            if !playing { held = Double(s.positionms) / 1000 }
            onremoteplaying?(playing)
        }
    }
}
