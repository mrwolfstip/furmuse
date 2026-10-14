import Foundation
import CryptoKit
import Combine
import AuthenticationServices
import UIKit

struct PendingScrobble: Codable {
    var artist: String
    var title: String
    var album: String
    var duration: Int
    var timestamp: Int
    var tracknumber: Int? = nil
    var albumartist: String? = nil
    var musicbrainzid: String? = nil
}

enum LastfmState: Equatable { case notconfigured, signedout, authenticated, expired }

final class LastfmClient: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published private(set) var username: String?
    @Published private(set) var state: LastfmState = .signedout
    @Published var busy = false
    @Published var lasterror: String?
    private(set) var apikey: String
    private(set) var secret: String
    private let base = URL(string: "https://ws.audioscrobbler.com/2.0/")!
    private var websession: ASWebAuthenticationSession?
    private let userkey = "wolfified.lastfm.user"
    private let expiredkey = "wolfified.lastfm.expired"

    init(apikey: String, secret: String) {
        self.apikey = apikey
        self.secret = secret
        super.init()
        username = UserDefaults.standard.string(forKey: userkey)
        refreshstate()
    }

    var configured: Bool { !apikey.isEmpty && !secret.isEmpty }
    // credentials in the config never mean "logged in"; only a stored, not-expired session does
    var loggedin: Bool { state == .authenticated }

    func configure(apikey: String, secret: String) {
        self.apikey = apikey; self.secret = secret
        lasterror = nil; refreshstate(); objectWillChange.send()
    }

    private func refreshstate() {
        if !configured { state = .notconfigured; return }
        if Keychain.get("lastfm.session") == nil { username = nil; state = .signedout; return }
        state = UserDefaults.standard.bool(forKey: expiredkey) ? .expired : .authenticated
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap { $0.windows }.first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }

    private func sign(_ p: [String: String]) -> String {
        let s = p.keys.sorted().map { $0 + p[$0]! }.joined() + secret
        return Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func call(_ method: String, _ extra: [String: String], session: Bool) async throws -> [String: Any] {
        var p = extra
        p["method"] = method
        p["api_key"] = apikey
        if session { guard let sk = Keychain.get("lastfm.session") else { throw SpotifyError.notconnected }; p["sk"] = sk }
        p["api_sig"] = sign(p)
        p["format"] = "json"
        var req = URLRequest(url: base)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        req.httpBody = p.map { "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "lastfm.transport", code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                          userInfo: [NSLocalizedDescriptionKey: "last.fm request failed"])
        }
        let j = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if let code = j["error"] as? Int {
            if session && code == 9 { markexpired() }
            throw NSError(domain: "lastfm", code: code, userInfo: [NSLocalizedDescriptionKey: j["message"] as? String ?? "last.fm error \(code)"])
        }
        return j
    }

    private func markexpired() {
        DispatchQueue.main.async {
            guard self.state == .authenticated else { return }
            UserDefaults.standard.set(true, forKey: self.expiredkey)
            self.state = .expired
            ToastCenter.shared.show("last.fm session expired, sign in again", route: .lastfm)
        }
    }

    // web auth: send the user to last.fm, receive ?token= on wolfified://lastfm, exchange it for a session
    func authenticate() {
        guard configured else { lasterror = "add your last.fm API key and shared secret in settings first"; return }
        var c = URLComponents(string: "https://www.last.fm/api/auth/")!
        c.queryItems = [.init(name: "api_key", value: apikey), .init(name: "cb", value: "wolfified://lastfm")]
        guard let url = c.url else { return }
        busy = true
        lasterror = nil
        let s = ASWebAuthenticationSession(url: url, callbackURLScheme: AppConfig.spotifyredirectscheme) { [weak self] cb, error in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if let error = error {
                    self.busy = false
                    if (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin { self.fail("last.fm sign-in failed: \(error.localizedDescription)") }
                    return
                }
                let items = cb.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
                guard let token = items.first(where: { $0.name == "token" })?.value, !token.isEmpty else {
                    self.busy = false
                    self.fail("last.fm didn't return a token")
                    return
                }
                Task { @MainActor in await self.exchange(token) }
            }
        }
        s.presentationContextProvider = self
        s.prefersEphemeralWebBrowserSession = false
        websession = s
        if !s.start() { busy = false; fail("could not open last.fm sign-in") }
    }

    private func fail(_ text: String) {
        DispatchQueue.main.async {
            self.lasterror = text
            ToastCenter.shared.show(text, route: .lastfm)
        }
    }

    @MainActor
    private func exchange(_ token: String) async {
        defer { busy = false }
        do {
            let j = try await call("auth.getSession", ["token": token], session: false)
            guard let s = j["session"] as? [String: Any], let key = s["key"] as? String, let name = s["name"] as? String else { fail("unexpected last.fm response"); return }
            Keychain.set(key, "lastfm.session")
            UserDefaults.standard.set(name, forKey: userkey)
            UserDefaults.standard.set(false, forKey: expiredkey)
            username = name
            state = .authenticated
        } catch { fail("last.fm: \(error.localizedDescription)") }
    }

    // asks last.fm whether the stored session still works
    @MainActor
    func validate() async {
        guard state == .authenticated else { return }
        do {
            let j = try await call("user.getInfo", [:], session: true)
            if let u = j["user"] as? [String: Any], let n = u["name"] as? String { username = n; UserDefaults.standard.set(n, forKey: userkey) }
        } catch {
            // network trouble isn't proof of an expired session; code 9 is handled in call()
        }
    }

    func logout() {
        Keychain.remove("lastfm.session")
        UserDefaults.standard.removeObject(forKey: userkey)
        UserDefaults.standard.set(false, forKey: expiredkey)
        DispatchQueue.main.async { self.username = nil; self.lasterror = nil; self.refreshstate() }
    }

    func nowplaying(_ t: Track) async throws {
        var p = ["artist": t.firstartist, "track": t.title]   // first credited artist only
        if !t.album.isEmpty { p["album"] = t.album }
        if t.duration > 0 { p["duration"] = String(Int(t.duration)) }
        if let n = t.tracknumber, n > 0 { p["trackNumber"] = String(n) }
        if let a = t.firstalbumartist { p["albumArtist"] = a }
        if let m = t.musicbrainzid, !m.isEmpty { p["mbid"] = m }
        _ = try await call("track.updateNowPlaying", p, session: true)
    }

    func scrobble(_ items: [PendingScrobble]) async throws {
        var p: [String: String] = [:]
        for (i, s) in items.prefix(50).enumerated() {
            p["artist[\(i)]"] = Track.firstname(s.artist); p["track[\(i)]"] = s.title; p["timestamp[\(i)]"] = String(s.timestamp)
            if !s.album.isEmpty { p["album[\(i)]"] = s.album }
            if s.duration > 0 { p["duration[\(i)]"] = String(s.duration) }
            if let n = s.tracknumber, n > 0 { p["trackNumber[\(i)]"] = String(n) }
            if let a = s.albumartist, !a.isEmpty { p["albumArtist[\(i)]"] = Track.firstname(a) }
            if let m = s.musicbrainzid, !m.isEmpty { p["mbid[\(i)]"] = m }
        }
        _ = try await call("track.scrobble", p, session: true)
    }
}

final class Scrobbler {
    private let client: LastfmClient
    private let library: LibraryStore
    private let allowed: (SourceKind?) -> Bool
    private let sourcekind: () -> SourceKind?
    private var session: SourceKind?      // source of the session in progress, captured when it started
    private var track: Track?
    private var started = Date()
    private var segstart: Double?
    private var played = 0.0
    private var pending: [PendingScrobble]
    private var flushing = false
    private var retry: Task<Void, Never>?
    private var retrydelay: UInt64 = 30
    private var nowplayinggeneration = 0
    private var bag = Set<AnyCancellable>()
    private let key = "wolfified.lastfm.pending"

    init(client: LastfmClient, library: LibraryStore, sourcekind: @escaping () -> SourceKind?, allowed: @escaping (SourceKind?) -> Bool) {
        self.client = client
        self.library = library
        self.sourcekind = sourcekind
        self.allowed = allowed
        pending = (UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([PendingScrobble].self, from: $0) }) ?? []
        EventBus.shared.subject.sink { [weak self] in self?.handle($0) }.store(in: &bag)
    }

    private func active() -> Bool { client.loggedin && allowed(session) }

    // The library's stored Track is the immutable/default identity. LibraryStore.shown(_:) applies
    // user display edits and must never be used for Last.fm submissions.
    private func canonical(_ t: Track) -> Track {
        guard var stored = library.data.tracks[t.id] else { return t }
        // Older library records predate these fields. Enrich only missing service metadata
        // from the current canonical event; never replace the stored title/artist/album.
        if stored.tracknumber == nil { stored.tracknumber = t.tracknumber }
        if stored.albumartist == nil { stored.albumartist = t.albumartist }
        if stored.artists == nil { stored.artists = t.artists }
        if stored.musicbrainzid == nil { stored.musicbrainzid = t.musicbrainzid }
        return stored
    }

    private func close(at pos: Double) {
        if let s = segstart { played += max(0, pos - s) }
        segstart = nil
    }

    private func finish(_ t: Track) {
        guard active(), t.duration > 30, played >= min(t.duration / 2, 240) else {
            Log.i(.lastfm, "no scrobble for \(t.id): source \(session?.rawValue ?? "?"), listened \(Int(played))s of \(Int(t.duration))s, active \(active())")
            return
        }
        Log.i(.lastfm, "queued scrobble for \(t.id) from \(session?.rawValue ?? "?") after \(Int(played))s of track time")
        let t = canonical(t)
        pending.append(PendingScrobble(artist: t.firstartist, title: t.title, album: t.album, duration: Int(t.duration), timestamp: Int(started.timeIntervalSince1970),
                                        tracknumber: t.tracknumber, albumartist: t.firstalbumartist, musicbrainzid: t.musicbrainzid))
        flush()
    }

    private func begin(_ t: Track) {
        let t = canonical(t)
        track = t; started = Date(); played = 0; segstart = 0
        session = sourcekind()
        nowplayinggeneration += 1
        let generation = nowplayinggeneration
        // Now Playing describes playback and is independent of whether scrobbling is enabled
        // for this source. It is safe from Spotify duplicate-scrobble behaviour.
        if client.loggedin { sendnowplaying(t, generation: generation) }
        if client.loggedin, !pending.isEmpty { flush() }
    }

    private func sendnowplaying(_ t: Track, generation: Int, attempt: Int = 0) {
        Task { @MainActor in
            do {
                try await self.client.nowplaying(t)
                Log.i(.lastfm, "updated now playing for \(t.id)")
            } catch {
                Log.w(.lastfm, "now playing update failed: \(error.localizedDescription)")
                guard generation == self.nowplayinggeneration, self.track?.id == t.id, self.client.loggedin, attempt < 3 else { return }
                let ns = error as NSError
                guard ns.domain != "lastfm" || [11, 16].contains(ns.code) else { self.report(error); return }
                let delay = UInt64(2 << attempt)
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                guard generation == self.nowplayinggeneration, self.track?.id == t.id else { return }
                self.sendnowplaying(t, generation: generation, attempt: attempt + 1)
            }
        }
    }

    private func flush() {
        persist()
        let batch = Array(pending.prefix(50))
        guard client.loggedin, !flushing, !batch.isEmpty else { return }
        flushing = true
        retry?.cancel(); retry = nil
        Task { @MainActor in
            do {
                try await self.client.scrobble(batch)
                self.pending.removeFirst(min(batch.count, self.pending.count))
                self.persist()
                self.flushing = false
                self.retrydelay = 30
                Log.i(.lastfm, "scrobbled \(batch.count)")
                if !self.pending.isEmpty { self.flush() }
            } catch {
                self.flushing = false
                Log.w(.lastfm, "scrobble failed (kept for retry unless permanent): \(error.localizedDescription)")
                let ns = error as NSError
                let retryable = ns.domain != "lastfm" || [4, 9, 11, 16, 26].contains(ns.code)
                if !retryable { self.pending.removeFirst(min(batch.count, self.pending.count)); self.persist() }
                else if self.client.loggedin { self.scheduleretry() }
                self.report(error)
            }
        }
    }

    private func scheduleretry() {
        guard retry == nil else { return }
        let delay = retrydelay
        retrydelay = min(retrydelay * 2, 900)
        retry = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self.retry = nil
            self.flush()
        }
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(pending) { UserDefaults.standard.set(d, forKey: key) }
    }

    private func report(_ e: Error) { ToastCenter.shared.show("last.fm: \(e.localizedDescription)", route: .lastfm) }

    private func handle(_ e: PlaybackEvent) {
        switch e {
        case .started(let t), .repeated(let t): begin(t)
        case .paused(_, let p): close(at: p)
        case .resumed(_, let p): segstart = p
        case .seeked(_, let from, let to): if segstart != nil { close(at: from); segstart = to }
        case .skipped(let t, let p), .ended(let t, let p), .stopped(let t, let p):
            if track?.id == t.id { close(at: p); finish(t); track = nil }
        case .failed: track = nil; segstart = nil; nowplayinggeneration += 1
        }
    }
}
