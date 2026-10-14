import Foundation

struct YouTubeVideo: Identifiable, Hashable {
    let id: String
    var title: String
    var channel: String
    var duration: Double?
    var candidate: YouTubeCandidate { YouTubeCandidate(id: id, title: title, channel: channel, duration: duration) }
}

enum YouTubePlaylistError: Error {
    case badlink, notfound, empty
    var text: String {
        switch self {
        case .badlink: return "that isn't a youtube playlist link"
        case .notfound: return "couldn't open that playlist (it may be private, or youtube didn't answer)"
        case .empty: return "that playlist has no playable videos"
        }
    }
}

// reads a public youtube playlist through the same web endpoints the youtube site uses, page by page.
enum YouTubePlaylist {
    static func playlistid(from text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let c = URLComponents(string: t), let l = c.queryItems?.first(where: { $0.name == "list" })?.value, l.count >= 10 { return l }
        if t.range(of: "^(PL|OLAK5uy_|UU|FL|RD)[A-Za-z0-9_-]{8,}$", options: .regularExpression) != nil { return t }
        return nil
    }

    private static let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    private struct WebClient {
        let key: String
        let version: String
        let initial: [String: Any]
    }

    private static func text(_ any: Any?) -> String {
        guard let d = any as? [String: Any] else { return "" }
        if let s = d["simpleText"] as? String { return s }
        return (d["runs"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined() ?? ""
    }

    private static func quoted(_ key: String, in text: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: key)
        guard let re = try? NSRegularExpression(pattern: "\\\"\(escaped)\\\"\\s*:\\s*\\\"([^\\\"]+)\\\"") else { return nil }
        let full = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: full), let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    // ytInitialData is a JSON object embedded in script. A brace scanner is more robust than a
    // regex because titles and descriptions can contain nested objects and escaped quotes.
    private static func initialJSON(in html: String) -> [String: Any]? {
        let markers = ["var ytInitialData = ", "window[\"ytInitialData\"] = "]
        guard let marker = markers.compactMap({ html.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) else { return nil }
        let bytes = Array(html[marker.upperBound...].utf8)
        if let first = bytes.firstIndex(where: { ![9, 10, 13, 32].contains($0) }), bytes[first] == 39 || bytes[first] == 34,
           let data = decodedJavaScriptString(Array(bytes[first...])),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { return object }
        var start: Int?, depth = 0, quoted = false, escaped = false
        for (i, b) in bytes.enumerated() {
            if quoted {
                if escaped { escaped = false }
                else if b == 92 { escaped = true }
                else if b == 34 { quoted = false }
                continue
            }
            if b == 34 { quoted = true; continue }
            if b == 123 {
                if start == nil { start = i }
                depth += 1
            } else if b == 125, start != nil {
                depth -= 1
                if depth == 0, let s = start {
                    let data = Data(bytes[s...i])
                    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                }
            }
        }
        return nil
    }

    private static func decodedJavaScriptString(_ bytes: [UInt8]) -> Data? {
        guard let delimiter = bytes.first else { return nil }
        var out: [UInt8] = [], i = 1
        func hex(_ b: UInt8) -> UInt8? {
            switch b {
            case 48...57: return b - 48
            case 65...70: return b - 55
            case 97...102: return b - 87
            default: return nil
            }
        }
        while i < bytes.count {
            let b = bytes[i]
            if b == delimiter { return Data(out) }
            guard b == 92 else { out.append(b); i += 1; continue }
            i += 1
            guard i < bytes.count else { return nil }
            let e = bytes[i]
            if e == 120, i + 2 < bytes.count, let a = hex(bytes[i + 1]), let z = hex(bytes[i + 2]) {
                out.append(a * 16 + z); i += 3
            } else if e == 117, i + 4 < bytes.count {
                var value: UInt32 = 0
                for j in 1...4 { guard let h = hex(bytes[i + j]) else { return nil }; value = value * 16 + UInt32(h) }
                guard let scalar = UnicodeScalar(value) else { return nil }
                out.append(contentsOf: String(scalar).utf8); i += 5
            } else {
                switch e {
                case 110: out.append(10)
                case 114: out.append(13)
                case 116: out.append(9)
                case 98: out.append(8)
                case 102: out.append(12)
                default: out.append(e)
                }
                i += 1
            }
        }
        return nil
    }

    private static func bootstrap(_ id: String) async -> WebClient? {
        var c = URLComponents(string: "https://www.youtube.com/playlist")!
        c.queryItems = [.init(name: "list", value: id), .init(name: "hl", value: "en"), .init(name: "gl", value: "US")]
        guard let url = c.url else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("CONSENT=YES+1; SOCS=CAI", forHTTPHeaderField: "Cookie")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let h = response as? HTTPURLResponse, h.statusCode == 200,
              let html = String(data: data, encoding: .utf8),
              let key = quoted("INNERTUBE_API_KEY", in: html),
              let version = quoted("INNERTUBE_CLIENT_VERSION", in: html),
              let initial = initialJSON(in: html) else { return nil }
        return WebClient(key: key, version: version, initial: initial)
    }

    private static func browse(_ body: [String: Any], client: WebClient) async -> [String: Any]? {
        var c = URLComponents(string: "https://www.youtube.com/youtubei/v1/browse")!
        c.queryItems = [.init(name: "prettyPrint", value: "false"), .init(name: "key", value: client.key)]
        guard let url = c.url else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        req.setValue("CONSENT=YES+1", forHTTPHeaderField: "Cookie")
        var b = body
        b["context"] = ["client": ["clientName": "WEB", "clientVersion": client.version, "hl": "en", "gl": "US"]]
        req.httpBody = try? JSONSerialization.data(withJSONObject: b)
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let h = response as? HTTPURLResponse, h.statusCode == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func walk(_ any: Any, videos: inout [YouTubeVideo], token: inout String?, title: inout String?) {
        if let d = any as? [String: Any] {
            if let v = d["playlistVideoRenderer"] as? [String: Any], let id = v["videoId"] as? String, id.count == 11 {
                let playable = (v["isPlayable"] as? Bool) ?? true
                let len = (v["lengthSeconds"] as? String).flatMap { Double($0) }
                if playable { videos.append(YouTubeVideo(id: id, title: text(v["title"]), channel: text(v["shortBylineText"]), duration: len)) }
            }
            if let c = d["continuationItemRenderer"] as? [String: Any],
               let t = ((c["continuationEndpoint"] as? [String: Any])?["continuationCommand"] as? [String: Any])?["token"] as? String { token = t }
            if title == nil, let m = d["playlistMetadataRenderer"] as? [String: Any], let t = m["title"] as? String { title = t }
            for (_, val) in d { walk(val, videos: &videos, token: &token, title: &title) }
        } else if let a = any as? [Any] {
            for x in a { walk(x, videos: &videos, token: &token, title: &title) }
        }
    }

    static func fetch(_ id: String, progress: @escaping (Int) -> Void) async throws -> (title: String, videos: [YouTubeVideo]) {
        guard let client = await bootstrap(id) else { throw YouTubePlaylistError.notfound }
        var videos: [YouTubeVideo] = []
        var token: String?
        var title: String?
        walk(client.initial, videos: &videos, token: &token, title: &title)
        if videos.isEmpty && token == nil { throw YouTubePlaylistError.notfound }
        progress(videos.count)
        var pages = 0
        while let t = token, pages < 80 {
            pages += 1
            token = nil
            guard let next = await browse(["continuation": t], client: client) else { break }
            walk(next, videos: &videos, token: &token, title: &title)
            progress(videos.count)
        }
        guard !videos.isEmpty else { throw YouTubePlaylistError.empty }
        // A playlist is an ordered sequence, not a set. Repeated videos are valid entries and
        // must survive import exactly where the owner placed them.
        return (title ?? "youtube playlist", videos)
    }
}

// turns a youtube playlist into import proposals: spotify track (canonical) + the most likely youtube source, for every video.
final class YouTubeImportPlanner: ObservableObject, @unchecked Sendable {
    enum Confidence { case good, review, nospotify }

    struct Item: Identifiable {
        let id = UUID()
        var video: YouTubeVideo
        var track: Track
        var spotifymatched: Bool
        var source: YouTubeCandidate
        var sourcescore: Double?
        var verified: SourceVerdict?        // set when the user picked a source by hand and it was verified
        var alternatives: [YouTubeCandidate]
        var confidence: Confidence
        var notes: [String]
        var include = true
    }

    enum Phase { case idle, fetching, matching, ready, failed(String) }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var playlisttitle = ""
    @Published private(set) var playlistid = ""
    @Published private(set) var found = 0
    @Published private(set) var done = 0
    @Published private(set) var total = 0
    @Published var items: [Item] = []
    private var cancelled = false

    func cancel() { cancelled = true }

    // ---- title parsing -----------------------------------------------------------------------------------------------
    private static let noise = "official|video|audio|lyrics?|lyric video|visuali[sz]er|hd|4k|m/v|mv|remaster(ed)?|explicit|music video"

    static func parse(_ v: YouTubeVideo) -> (artist: String?, title: String) {
        var t = v.title
        t = t.replacingOccurrences(of: "\\s*[\\(\\[][^\\)\\]]*(\(noise))[^\\)\\]]*[\\)\\]]", with: "", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: "\\s*\\|.*$", with: "", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespaces)
        var ch = v.channel
        for pat in ["\\s*-\\s*Topic$", "(?i)vevo$", "(?i)\\s*official$"] { ch = ch.replacingOccurrences(of: pat, with: "", options: .regularExpression) }
        ch = ch.trimmingCharacters(in: .whitespaces)
        if let r = t.range(of: " - ") {
            let a = String(t[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            let b = String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !a.isEmpty, !b.isEmpty { return (a, b) }
        }
        return (ch.isEmpty ? nil : ch, t.isEmpty ? v.title : t)
    }

    private static func yttrack(_ v: YouTubeVideo) -> Track {
        let p = parse(v)
        return Track(id: Track.ytprefix + v.id, title: p.title, artist: p.artist ?? v.channel, album: "", artwork: YouTubeSearch.thumbnail(v.id)?.absoluteString, duration: v.duration ?? 0)
    }

    // ---- matching ------------------------------------------------------------------------------------------------------
    private func plan(_ v: YouTubeVideo, api: SpotifyAPI) async -> Item {
        let p = Self.parse(v)
        var queries: [String] = []
        if let a = p.artist { queries.append("\(a) \(p.title)") }
        queries.append(p.title)
        var best: (track: Track, score: Double)?
        var seen = Set<String>()
        for q in queries where seen.insert(q.lowercased()).inserted {
            if let results = try? await api.search(q) {
                for t in results {
                    if let s = YouTubeMatcher.score(v.candidate, for: t).score, s >= YouTubeMatcher.threshold, s > (best?.score ?? 0) { best = (t, s) }
                }
            }
            if let b = best, b.score >= 0.85 { break }
        }
        guard let match = best else {
            var it = Item(video: v, track: Self.yttrack(v), spotifymatched: false, source: v.candidate, sourcescore: nil, alternatives: [], confidence: .nospotify,
                          notes: ["no matching spotify track; will be added as a youtube-only track"])
            it.include = true
            return it
        }
        var chosen = v.candidate, chosenscore = match.score
        var notes: [String] = []
        var alts: [YouTubeCandidate] = []
        if match.score < 0.8 {
            // the playlist's own video is only an okay match for the spotify track: look for a better audio source
            let cands = await YouTubeSearch.candidates(for: match.track, limit: 12)
            let ranked = YouTubeMatcher.rank(cands, for: match.track).ok
            alts = ranked.prefix(4).map { $0.0 }.filter { $0.id != v.id }
            if let top = ranked.first, top.1 > match.score + 0.05 {
                chosen = top.0; chosenscore = top.1
                notes.append("chose a better audio source than the playlist's video")
            }
        } else {
            let cands = Array(await YouTubeSearch.candidates(for: match.track, limit: 8).prefix(8))
            alts = YouTubeMatcher.rank(cands, for: match.track).ok.prefix(3).map { $0.0 }.filter { $0.id != v.id }
        }
        if chosen.id != v.id { alts.insert(v.candidate, at: 0) }
        var conf: Confidence = chosenscore >= 0.85 ? .good : .review
        if chosenscore < 0.85 { notes.append("moderate match (\(Int(chosenscore * 100))%)") }
        if let d = chosen.duration, match.track.duration > 0, abs(d - match.track.duration) > YouTubeMatcher.tolerance(match.track.duration).tight {
            notes.append("length differs by \(Int(abs(d - match.track.duration)))s")
            if conf == .good { conf = .review }
        }
        return Item(video: v, track: match.track, spotifymatched: true, source: chosen, sourcescore: chosenscore, alternatives: alts, confidence: conf, notes: notes)
    }

    @MainActor
    func run(link: String, api: SpotifyAPI) async {
        cancelled = false
        guard let id = YouTubePlaylist.playlistid(from: link) else { phase = .failed(YouTubePlaylistError.badlink.text); return }
        playlistid = id
        phase = .fetching; found = 0; items = []
        let fetched: (title: String, videos: [YouTubeVideo])
        do { fetched = try await YouTubePlaylist.fetch(id) { n in Task { @MainActor in self.found = n } } }
        catch { phase = .failed((error as? YouTubePlaylistError)?.text ?? "couldn't read the playlist"); return }
        playlisttitle = fetched.title
        phase = .matching; done = 0; total = fetched.videos.count
        // a few at a time: fast enough for big playlists, gentle enough for spotify's rate limit
        var results: [Int: Item] = [:]
        let videos = fetched.videos
        await withTaskGroup(of: (Int, Item).self) { g in
            var next = 0
            while next < min(3, videos.count) {
                let i = next, v = videos[i]
                g.addTask { (i, await self.plan(v, api: api)) }
                next += 1
            }
            while let (i, it) = await g.next() {
                results[i] = it
                done += 1
                if next < videos.count, !cancelled {
                    let j = next, v = videos[j]
                    g.addTask { (j, await self.plan(v, api: api)) }
                    next += 1
                }
            }
        }
        if cancelled { phase = .idle; return }
        items = fetched.videos.indices.compactMap { results[$0] }
        phase = .ready
    }

    var reviewcount: Int { items.filter { $0.confidence != .good }.count }
    var includedcount: Int { items.filter { $0.include }.count }
}
