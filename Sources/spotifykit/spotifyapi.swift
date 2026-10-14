import Foundation

struct SpImage: Decodable { let url: String }
struct SpArtist: Decodable { let id: String?; let name: String }
struct SpAlbum: Decodable { let id: String?; let name: String; let images: [SpImage]?; let artists: [SpArtist]? }
struct SpTrack: Decodable {
    let id: String?
    let name: String
    let duration_ms: Int
    let artists: [SpArtist]
    let album: SpAlbum
    let track_number: Int?

    var track: Track? {
        guard let id = id else { return nil }
        let albumartist = album.artists?.map { $0.name }.joined(separator: ", ")
        return Track(id: id, title: name, artist: artists.map { $0.name }.joined(separator: ", "), album: album.name,
                     artwork: album.images?.first?.url, duration: Double(duration_ms) / 1000,
                     tracknumber: track_number, albumartist: albumartist,
                     artists: artists.map { $0.name }, albumid: album.id, artistids: artists.compactMap { $0.id })
    }
}
struct SpArtistSearch: Decodable {
    struct A: Decodable { let name: String; let images: [SpImage]? }
    struct R: Decodable { let items: [A?] }
    let artists: R
}
struct SpAlbumTrack: Decodable {
    let id: String?; let name: String; let duration_ms: Int; let artists: [SpArtist]; let track_number: Int?
}
struct SpAlbumTrackPage: Decodable { let items: [SpAlbumTrack?]; let next: String? }
struct SpAlbumFull: Decodable {
    let id: String?; let name: String; let images: [SpImage]?; let artists: [SpArtist]?; let tracks: SpAlbumTrackPage
}
// an album as the album page shows it: every track as a normal Track, with the album's own metadata
struct SpotifyAlbum {
    let id: String
    let name: String
    let artist: String
    let artwork: String?
    let tracks: [Track]
}
struct SpSearch: Decodable { struct T: Decodable { let items: [SpTrack?] }; let tracks: T }
struct SpSaved: Decodable { struct I: Decodable { let track: SpTrack? }; let items: [I]; let next: String? }
struct SpPlaylist: Decodable, Identifiable {
    let id: String
    let name: String
    let images: [SpImage]?
}
struct SpPlaylists: Decodable { let items: [SpPlaylist?]; let next: String? }
struct SpPlaylistItems: Decodable {
    struct I: Decodable {
        let track: SpTrack?
        enum K: String, CodingKey { case item, track }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: K.self)
            track = (try? c.decodeIfPresent(SpTrack.self, forKey: .item)) ?? (try? c.decodeIfPresent(SpTrack.self, forKey: .track)) ?? nil
        }
    }
    let items: [I]
    let next: String?
}
struct SpTrackPage {
    let tracks: [Track]
    let nextOffset: Int?
}
struct SpDevice: Decodable, Identifiable, Equatable {
    let id: String?
    let is_active: Bool
    let is_restricted: Bool?
    let name: String
    let type: String
    let volume_percent: Int?
    let supports_volume: Bool?
}
struct SpDevices: Decodable { let devices: [SpDevice] }
struct SpPlayerState: Decodable {
    let device: SpDevice?
    let is_playing: Bool
    let progress_ms: Int?
    let item: SpTrack?
}

final class SpotifyAPI {
    let auth: SpotifyAuth
    private let requests = SpotifyRequestCoordinator()
    init(auth: SpotifyAuth) { self.auth = auth }

    func request(_ method: String, _ path: String, query: [String: String] = [:], body: [String: Any]? = nil, retried: Bool = false) async throws -> Data {
        let key = SpotifyRequestCoordinator.key(method: method, path: path, query: query)
        if method == "GET" {
            return try await requests.get(key: key, cacheFor: SpotifyRequestCoordinator.cacheTTL(path: path)) { [weak self] in
                guard let self = self else { throw SpotifyError.network }
                return try await self.perform(method, path, query: query, body: body, retried: retried)
            }
        }
        try await requests.checkBackoff()
        return try await perform(method, path, query: query, body: body, retried: retried)
    }

    private func perform(_ method: String, _ path: String, query: [String: String], body: [String: Any]?, retried: Bool) async throws -> Data {
        let isconnected = await MainActor.run { auth.connected }
        guard isconnected else { throw SpotifyError.notconnected }
        var c = URLComponents(string: "https://api.spotify.com/v1" + path)!
        if !query.isEmpty { c.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: c.url!)
        req.httpMethod = method
        req.timeoutInterval = 20
        req.setValue("Bearer " + (try await auth.token()), forHTTPHeaderField: "Authorization")
        if let b = body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: b)
        }
        await requests.record(method: method, path: path)
        let pair: (Data, URLResponse)
        do { pair = try await URLSession.shared.data(for: req) } catch { throw SpotifyError.network }
        let data = pair.0, resp = pair.1
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(data: data, encoding: .utf8) ?? ""
        switch code {
        case 200..<300: return data
        case 401 where !retried:
            _ = try await auth.token(force: true)
            return try await perform(method, path, query: query, body: body, retried: true)
        case 429:
            let wait = Int((resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 5
            await requests.backoff(seconds: wait, quota: text.uppercased().contains("QUOTA_EXCEEDED"))
            if text.uppercased().contains("QUOTA_EXCEEDED") { throw SpotifyError.quota }
            throw SpotifyError.rate(wait)
        case 403 where text.uppercased().contains("PREMIUM_REQUIRED"): throw SpotifyError.premiumrequired
        case 404 where text.uppercased().contains("NO_ACTIVE_DEVICE") || path.hasPrefix("/me/player"): throw SpotifyError.nodevice
        default: throw SpotifyError.http(code, text)
        }
    }

    func decode<T: Decodable>(_ t: T.Type, _ method: String, _ path: String, query: [String: String] = [:]) async throws -> T {
        let d = try await request(method, path, query: query)
        do { return try JSONDecoder().decode(T.self, from: d) } catch { throw SpotifyError.badresponse }
    }

    func search(_ q: String) async throws -> [Track] {
        let r = try await decode(SpSearch.self, "GET", "/search", query: ["q": q, "type": "track", "limit": "10"])
        return r.tracks.items.compactMap { $0?.track }
    }

    // the artist's photo url (spotify lists images largest first). only an exact name match counts, so a different artist's
    // photo is never shown by mistake. nil = no such artist or no image.
    func artistimage(_ name: String) async throws -> String? {
        let r = try await decode(SpArtistSearch.self, "GET", "/search", query: ["q": name, "type": "artist", "limit": "5"])
        func norm(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).trimmingCharacters(in: .whitespaces) }
        let want = norm(name)
        return r.artists.items.compactMap { $0 }.first { norm($0.name) == want }?.images?.first?.url
    }

    // the album a track belongs to, for tracks that arrived without an album id (connect events, older library files)
    func albumid(of trackid: String) async throws -> String? {
        try await decode(SpTrack.self, "GET", "/tracks/\(trackid)").album.id
    }

    // the whole album, every page of it
    func album(_ id: String) async throws -> SpotifyAlbum {
        let a = try await decode(SpAlbumFull.self, "GET", "/albums/\(id)")
        var items = a.tracks.items.compactMap { $0 }
        var next = a.tracks.next
        var offset = items.count
        while next != nil, offset < 500 {
            let p = try await decode(SpAlbumTrackPage.self, "GET", "/albums/\(id)/tracks", query: ["limit": "50", "offset": String(offset)])
            let more = p.items.compactMap { $0 }
            if more.isEmpty { break }
            items += more
            offset += more.count
            next = p.next
        }
        let albumartist = a.artists?.map { $0.name }.joined(separator: ", ")
        let cover = a.images?.first?.url
        let tracks: [Track] = items.compactMap { t in
            guard let tid = t.id else { return nil }
            return Track(id: tid, title: t.name, artist: t.artists.map { $0.name }.joined(separator: ", "), album: a.name, artwork: cover,
                         duration: Double(t.duration_ms) / 1000, tracknumber: t.track_number, albumartist: albumartist,
                         artists: t.artists.map { $0.name }, albumid: a.id ?? id, artistids: t.artists.compactMap { $0.id })
        }
        return SpotifyAlbum(id: a.id ?? id, name: a.name, artist: a.artists?.first?.name ?? "", artwork: cover, tracks: tracks)
    }

    // songs by an artist on spotify (search, so it works for any artist name). only tracks that really credit them are kept.
    func artisttracks(_ name: String) async throws -> [Track] {
        let r = try await decode(SpSearch.self, "GET", "/search", query: ["q": "artist:\"\(name)\"", "type": "track", "limit": "10"])
        func norm(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).trimmingCharacters(in: .whitespaces) }
        let want = norm(name)
        return r.tracks.items.compactMap { $0?.track }.filter { t in (t.artists ?? []).contains { norm($0) == want } }
    }

    func saved(offset: Int) async throws -> SpTrackPage {
        let r = try await decode(SpSaved.self, "GET", "/me/tracks", query: ["limit": "50", "offset": String(offset)])
        let next = r.next == nil || r.items.isEmpty ? nil : offset + r.items.count
        return SpTrackPage(tracks: r.items.compactMap { $0.track?.track }, nextOffset: next)
    }

    func playlists(offset: Int) async throws -> (items: [SpPlaylist], more: Bool) {
        let r = try await decode(SpPlaylists.self, "GET", "/me/playlists", query: ["limit": "50", "offset": String(offset)])
        return (r.items.compactMap { $0 }, r.next != nil)
    }

    func playlisttracks(_ id: String, offset: Int) async throws -> SpTrackPage {
        let r = try await decode(SpPlaylistItems.self, "GET", "/playlists/\(id)/items", query: ["limit": "50", "offset": String(offset)])
        // Advance by raw playlist items, not decoded songs. Episodes, removed tracks and local
        // items can decode to nil; using tracks.count repeats pages or can loop forever.
        let next = r.next == nil || r.items.isEmpty ? nil : offset + r.items.count
        return SpTrackPage(tracks: r.items.compactMap { $0.track?.track }, nextOffset: next)
    }

    func playlist(_ id: String) async throws -> SpPlaylist {
        try await decode(SpPlaylist.self, "GET", "/playlists/\(id)", query: ["fields": "id,name,images"])
    }

    // spotify:playlist:ID or https://open.spotify.com/playlist/ID?si=...
    static func playlistid(from text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("spotify:playlist:") { return String(t.dropFirst("spotify:playlist:".count)) }
        guard let u = URLComponents(string: t), u.host?.contains("spotify.com") == true else { return nil }
        let parts = u.path.split(separator: "/").map(String.init)
        if let i = parts.firstIndex(of: "playlist"), parts.count > i + 1 { return parts[i + 1] }
        return nil
    }

    func devices() async throws -> [SpDevice] { try await decode(SpDevices.self, "GET", "/me/player/devices").devices }

    func state() async throws -> SpPlayerState? {
        let d = try await request("GET", "/me/player")
        if d.isEmpty { return nil }
        return try? JSONDecoder().decode(SpPlayerState.self, from: d)
    }

    static func message(_ e: Error) -> (String, Route) {
        switch e as? SpotifyError {
        case .notconnected: return ("spotify isn't connected", .spotify)
        case .premiumrequired: return ("spotify premium is required for this", .spotify)
        case .nodevice: return ("no active spotify connect device", .devices)
        case .quota: return ("spotify quota exceeded for this app", .spotify)
        case .rate(let s): return ("spotify rate limit, retry in \(s)s", .spotify)
        case .network: return ("couldn't reach spotify", .spotify)
        case .http(let c, _): return ("spotify error \(c)", .spotify)
        default: return ("spotify returned something unexpected", .spotify)
        }
    }

    static func report(_ e: Error) {
        let m = message(e)
        ToastCenter.shared.show(m.0, route: m.1)
    }
}

// One coordinator is shared by every caller of this SpotifyAPI instance. It coalesces identical GETs, keeps the few
// naturally repetitive reads briefly cached, and applies a global Retry-After gate after any 429. A screen refresh can
// no longer race the SDK/device lifecycle into sending the same request several times.
private actor SpotifyRequestCoordinator {
    private var inflight: [String: Task<Data, Error>] = [:]
    private var cache: [String: (data: Data, expires: Date)] = [:]
    private var blockedUntil = Date.distantPast
    private var quotaBlocked = false
    private var counts: [String: Int] = [:]

    static func key(method: String, path: String, query: [String: String]) -> String {
        let q = query.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        return "\(method) \(path)?\(q)"
    }

    static func cacheTTL(path: String) -> TimeInterval {
        if path == "/me/player/devices" { return 5 }
        if path == "/me" { return 60 }
        return 0
    }

    func checkBackoff() throws {
        guard blockedUntil > Date() else { quotaBlocked = false; return }
        if quotaBlocked { throw SpotifyError.quota }
        throw SpotifyError.rate(max(1, Int(blockedUntil.timeIntervalSinceNow.rounded(.up))))
    }

    func get(key: String, cacheFor ttl: TimeInterval, operation: @escaping () async throws -> Data) async throws -> Data {
        try checkBackoff()
        if let c = cache[key], c.expires > Date() { return c.data }
        if let task = inflight[key] { return try await task.value }
        let task = Task { try await operation() }
        inflight[key] = task
        do {
            let data = try await task.value
            inflight[key] = nil
            if ttl > 0 { cache[key] = (data, Date().addingTimeInterval(ttl)) }
            return data
        } catch {
            inflight[key] = nil
            throw error
        }
    }

    func backoff(seconds: Int, quota: Bool) {
        let wait = max(1, seconds)
        blockedUntil = max(blockedUntil, Date().addingTimeInterval(TimeInterval(wait)))
        quotaBlocked = quotaBlocked || quota
        Log.w(.spotify, "spotify 429 on web api; global backoff \(wait)s\(quota ? " (quota exceeded)" : "")")
        if quota {
            Task { @MainActor in SpotifyQuotaNotice.shared.present(retryAfter: wait) }
        }
    }

    func record(method: String, path: String) {
        let endpoint = "\(method) \(path)"
        counts[endpoint, default: 0] += 1
        Log.i(.spotify, "request \(endpoint) (#\(counts[endpoint] ?? 0) this launch)")
    }
}

@MainActor
final class SpotifyQuotaNotice: ObservableObject {
    static let shared = SpotifyQuotaNotice()
    @Published var visible = false
    @Published private(set) var retryAfter = 0

    func present(retryAfter: Int) {
        self.retryAfter = max(1, retryAfter)
        visible = true
    }
}
