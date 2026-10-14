import Foundation

struct LyricWord { var time: Double; var end: Double; var text: String }
struct LyricLine { var time: Double; var end: Double; var text: String; var words: [LyricWord]; var estimated = false }
struct LyricsDoc { var lines: [LyricLine]; var synced: Bool; var source: String }

enum LyricsParser {
    static func clock(_ s: String) -> Double? {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasSuffix("s") { t.removeLast(); return Double(t) }
        let parts = t.split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, !parts.contains(where: { $0 == nil }) else { return nil }
        return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
    }

    static func lrc(_ text: String, source: String) -> LyricsDoc? {
        guard let tag = try? NSRegularExpression(pattern: "\\[(\\d+:\\d+(?:[.:]\\d+)?)\\]"),
              let wtag = try? NSRegularExpression(pattern: "<(\\d+:\\d+(?:[.:]\\d+)?)>") else { return nil }
        var lines: [LyricLine] = []
        var plain: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let ns = raw as NSString
            let tags = tag.matches(in: raw, range: NSRange(location: 0, length: ns.length))
            guard !tags.isEmpty else {
                let t = raw.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty, !t.hasPrefix("[") { plain.append(t) }
                continue
            }
            let body = ns.substring(from: tags.last!.range.location + tags.last!.range.length)
            for m in tags {
                guard let t = clock(ns.substring(with: m.range(at: 1)).replacingOccurrences(of: ":", with: ":")) else { continue }
                var words: [LyricWord] = []
                let bs = body as NSString
                let wm = wtag.matches(in: body, range: NSRange(location: 0, length: bs.length))
                for (i, w) in wm.enumerated() {
                    let start = clock(bs.substring(with: w.range(at: 1))) ?? t
                    let from = w.range.location + w.range.length
                    let to = i + 1 < wm.count ? wm[i + 1].range.location : bs.length
                    let word = bs.substring(with: NSRange(location: from, length: max(0, to - from)))
                    let end = i + 1 < wm.count ? (clock(bs.substring(with: wm[i + 1].range(at: 1))) ?? start) : start + 0.5
                    if !word.trimmingCharacters(in: .whitespaces).isEmpty { words.append(LyricWord(time: start, end: end, text: word)) }
                }
                let clean = wtag.stringByReplacingMatches(in: body, range: NSRange(location: 0, length: bs.length), withTemplate: "").trimmingCharacters(in: .whitespaces)
                lines.append(LyricLine(time: t, end: t, text: clean, words: words))
            }
        }
        if lines.isEmpty {
            guard !plain.isEmpty else { return nil }
            return LyricsDoc(lines: plain.map { LyricLine(time: -1, end: -1, text: $0, words: []) }, synced: false, source: source)
        }
        lines.sort { $0.time < $1.time }
        for i in lines.indices { lines[i].end = i + 1 < lines.count ? lines[i + 1].time : lines[i].time + 4 }
        return LyricsDoc(lines: lines, synced: true, source: source)
    }

    // fake word timing for lines that only have a start time: the words share the time the line is sung, weighted by length
    static func estimatedwords(_ line: LyricLine) -> [LyricWord] {
        let parts = line.text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty, line.time >= 0 else { return [] }
        let chars = Double(parts.reduce(0) { $0 + $1.count })
        let available = max(0.4, line.end - line.time - 0.08)
        let sung = min(available, max(0.8, chars * 0.075))      // ~13 characters a second, never longer than the gap to the next line
        let weights = parts.map { Double($0.count) + 1.5 }
        let total = weights.reduce(0, +)
        var t = line.time
        var out: [LyricWord] = []
        for (i, w) in parts.enumerated() {
            let d = sung * weights[i] / total
            out.append(LyricWord(time: t, end: t + d, text: i + 1 < parts.count ? w + " " : w))
            t += d
        }
        return out
    }

    static func ttml(_ data: Data, source: String) -> LyricsDoc? {
        let p = XMLParser(data: data)
        let d = TTMLDelegate()
        p.delegate = d
        guard p.parse(), !d.lines.isEmpty else { return nil }
        var lines = d.lines.sorted { $0.time < $1.time }
        for i in lines.indices where lines[i].end <= lines[i].time { lines[i].end = i + 1 < lines.count ? lines[i + 1].time : lines[i].time + 4 }
        return LyricsDoc(lines: lines, synced: true, source: source)
    }

    private final class TTMLDelegate: NSObject, XMLParserDelegate {
        var lines: [LyricLine] = []
        private var cur: LyricLine?
        private var spanstart: Double?
        private var spanend = 0.0
        private var buf = ""
        private var inspan = false

        private func local(_ n: String) -> String { n.components(separatedBy: ":").last ?? n }

        func parser(_ parser: XMLParser, didStartElement rawname: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
            let name = local(rawname)
            if name == "p" {
                let t = a["begin"].flatMap { LyricsParser.clock($0) } ?? 0
                let e = a["end"].flatMap { LyricsParser.clock($0) } ?? t
                cur = LyricLine(time: t, end: e, text: "", words: [])
            } else if name == "span", cur != nil {
                inspan = true
                buf = ""
                spanstart = a["begin"].flatMap { LyricsParser.clock($0) }
                spanend = a["end"].flatMap { LyricsParser.clock($0) } ?? 0
            } else if name == "br" { cur?.text += " " }
        }

        func parser(_ parser: XMLParser, foundCharacters s: String) {
            if inspan { buf += s }
            else if cur != nil {
                cur?.text += s
                // apple ttml puts the space between words outside the spans; keep it on the previous word so words join correctly
                if s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !s.isEmpty, let n = cur?.words.count, n > 0,
                   cur?.words[n - 1].text.last?.isWhitespace == false { cur?.words[n - 1].text += " " }
            }
        }

        func parser(_ parser: XMLParser, didEndElement rawname: String, namespaceURI: String?, qualifiedName: String?) {
            let name = local(rawname)
            if name == "span", inspan {
                inspan = false
                cur?.text += buf
                if let s = spanstart { cur?.words.append(LyricWord(time: s, end: max(spanend, s), text: buf)) }
            } else if name == "p", var l = cur {
                l.text = l.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !l.text.isEmpty { lines.append(l) }
                cur = nil
            }
        }
    }
}

final class LyricsStore: ObservableObject {
    @Published private(set) var doc: LyricsDoc?
    @Published private(set) var status = ""
    @Published private(set) var loadingid = ""
    private let settings: Settings
    private let dir: URL
    private var forid = ""

    init(settings: Settings) {
        self.settings = settings
        dir = LibraryStore.supportdir.appendingPathComponent("lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func currentline(for trackid: String, at position: Double) -> String? {
        guard forid == trackid, let doc, doc.synced else { return nil }
        guard let text = doc.lines.last(where: { $0.time <= position && position < $0.end })?.text,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    private func path(_ id: String, _ ext: String) -> URL { dir.appendingPathComponent("\(id).\(ext)") }

    func hasuser(_ id: String) -> Bool { ["lrc", "ttml"].contains { FileManager.default.fileExists(atPath: path(id, $0).path) } }

    @MainActor
    func load(_ t: Track, refetch: Bool = false) async {
        guard forid != t.id || refetch else { return }
        forid = t.id
        doc = nil
        status = ""
        guard settings.lyricson else { status = "lyrics are off"; return }
        if let d = try? Data(contentsOf: path(t.id, "ttml")), let x = LyricsParser.ttml(d, source: "your ttml") { doc = x; return }
        if let s = try? String(contentsOf: path(t.id, "lrc"), encoding: .utf8), let x = LyricsParser.lrc(s, source: "your lrc") { doc = x; return }
        // spotify has no official lyrics api, so there is no spotify step here
        if !refetch, let s = try? String(contentsOf: path(t.id, "cache"), encoding: .utf8), let x = LyricsParser.lrc(s, source: (try? String(contentsOf: path(t.id, "src"), encoding: .utf8)) ?? "lyrics cache") { doc = x; return }
        guard settings.lyricsnet, !settings.offlineonly else { status = "no lyrics stored for this track"; return }
        loadingid = t.id
        defer { loadingid = "" }
        var plainfallback: (String, String)?
        for p in LyricsProviders.chain(more: settings.lyricsmore) {
            guard forid == t.id else { return }
            guard let text = await p.fetch(t), !text.isEmpty else { continue }
            guard let x = LyricsParser.lrc(text, source: p.name) else { continue }
            if x.synced {
                guard forid == t.id else { return }
                try? text.write(to: path(t.id, "cache"), atomically: true, encoding: .utf8)
                try? p.name.write(to: path(t.id, "src"), atomically: true, encoding: .utf8)
                doc = x
                return
            }
            if plainfallback == nil { plainfallback = (text, p.name) }   // keep looking for a synced version on the next source
        }
        guard forid == t.id else { return }
        if let (text, name) = plainfallback, let x = LyricsParser.lrc(text, source: name) {
            try? text.write(to: path(t.id, "cache"), atomically: true, encoding: .utf8)
            try? name.write(to: path(t.id, "src"), atomically: true, encoding: .utf8)
            doc = x
        } else { status = "no lyrics found" }
    }

    @MainActor
    func save(_ text: String, ext: String, for t: Track) async {
        try? FileManager.default.removeItem(at: path(t.id, "lrc"))
        try? FileManager.default.removeItem(at: path(t.id, "ttml"))
        try? text.write(to: path(t.id, ext), atomically: true, encoding: .utf8)
        forid = ""
        await load(t)
        if doc == nil { status = "couldn't read that lyrics file" }
    }

    @MainActor
    func removeuser(for t: Track) async {
        try? FileManager.default.removeItem(at: path(t.id, "lrc"))
        try? FileManager.default.removeItem(at: path(t.id, "ttml"))
        forid = ""
        await load(t)
    }

    func clearcache() {
        let fm = FileManager.default
        for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "cache" || f.pathExtension == "src" { try? fm.removeItem(at: f) }
    }

    func clearall() {
        let fm = FileManager.default
        for file in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: file)
        }
        doc = nil; status = ""; loadingid = ""; forid = ""
    }
}

// MARK: online sources. each one returns lrc text (synced when it can) or nil. all of them are unofficial public endpoints, so
// every call is short-timeout and failure just moves on to the next source.
struct LyricsProvider {
    let name: String
    let fetch: (Track) async -> String?
}

enum LyricsProviders {
    static func chain(more: Bool) -> [LyricsProvider] {
        var list = [LyricsProvider(name: "lrclib", fetch: lrclibget), LyricsProvider(name: "lrclib", fetch: lrclibsearch)]
        if more {
            list += [LyricsProvider(name: "netease", fetch: netease), LyricsProvider(name: "qq music", fetch: qqmusic), LyricsProvider(name: "kugou", fetch: kugou)]
        }
        return list
    }

    // MARK: helpers
    private static func json(_ url: URL?, headers: [String: String] = [:]) async -> Any? {
        guard let url = url else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func url(_ base: String, _ items: [String: String]) -> URL? {
        guard var c = URLComponents(string: base) else { return nil }
        c.queryItems = items.map { URLQueryItem(name: $0.key, value: $0.value) }
        return c.url
    }

    private static func firstartist(_ t: Track) -> String { t.artist.components(separatedBy: ", ").first ?? t.artist }

    // "Song - Remastered 2011", "Song (feat. X)", "Song [Deluxe]" -> "Song"
    private static func cleantitle(_ s: String) -> String {
        var r = s
        for pattern in ["\\s*[\\(\\[][^\\)\\]]*[\\)\\]]", "\\s+-\\s+.*$"] {
            r = r.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        let t = r.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? s : t
    }

    private static func sameartist(_ a: String, _ b: String) -> Bool {
        let x = a.lowercased(), y = b.lowercased()
        return !x.isEmpty && !y.isEmpty && (x.contains(y) || y.contains(x))
    }

    private static func closeenough(_ a: Double, _ b: Double, tolerance: Double = 6) -> Bool { a <= 0 || b <= 0 || abs(a - b) <= tolerance }

    private static func decodeentities(_ s: String) -> String {
        var r = s
        if let re = try? NSRegularExpression(pattern: "&#(\\d+);") {
            let ns = r as NSString
            for m in re.matches(in: r, range: NSRange(location: 0, length: ns.length)).reversed() {
                if let code = UInt32(ns.substring(with: m.range(at: 1))), let u = Unicode.Scalar(code) {
                    r = (r as NSString).replacingCharacters(in: m.range, with: String(Character(u)))
                }
            }
        }
        return r.replacingOccurrences(of: "&apos;", with: "'").replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
    }

    // MARK: lrclib
    static func lrclibget(_ t: Track) async -> String? {
        let items = ["track_name": t.title, "artist_name": firstartist(t), "album_name": t.album, "duration": String(Int(t.duration))]
        guard let j = await json(url("https://lrclib.net/api/get", items), headers: ["User-Agent": "furmuse"]) as? [String: Any] else { return nil }
        return pick(j)
    }

    static func lrclibsearch(_ t: Track) async -> String? {
        let items = ["track_name": cleantitle(t.title), "artist_name": firstartist(t)]
        guard let list = await json(url("https://lrclib.net/api/search", items), headers: ["User-Agent": "furmuse"]) as? [[String: Any]] else { return nil }
        let close = list.filter { closeenough(($0["duration"] as? Double) ?? 0, t.duration, tolerance: 5) }
        let ranked = close.sorted { abs((($0["duration"] as? Double) ?? 0) - t.duration) < abs((($1["duration"] as? Double) ?? 0) - t.duration) }
        for item in ranked { if let s = (item["syncedLyrics"] as? String), !s.isEmpty { return s } }
        for item in ranked { if let s = pick(item) { return s } }
        return nil
    }

    private static func pick(_ j: [String: Any]) -> String? {
        if let s = j["syncedLyrics"] as? String, !s.isEmpty { return s }
        if let s = j["plainLyrics"] as? String, !s.isEmpty { return s }
        return nil
    }

    // MARK: netease cloud music
    static func netease(_ t: Track) async -> String? {
        let h = ["Referer": "https://music.163.com/"]
        let q = "\(cleantitle(t.title)) \(firstartist(t))"
        guard let r = await json(url("https://music.163.com/api/search/get/web", ["s": q, "type": "1", "limit": "10", "offset": "0", "total": "true"]), headers: h) as? [String: Any],
              let songs = (r["result"] as? [String: Any])?["songs"] as? [[String: Any]] else { return nil }
        let match = songs.first { song in
            let artists = (song["artists"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            let ms = (song["duration"] as? Double) ?? 0
            return artists.contains { sameartist($0, firstartist(t)) } && closeenough(ms / 1000, t.duration)
        }
        guard let id = match?["id"] as? Int,
              let l = await json(url("https://music.163.com/api/song/lyric", ["id": String(id), "lv": "1", "kv": "1", "tv": "-1"]), headers: h) as? [String: Any],
              let text = (l["lrc"] as? [String: Any])?["lyric"] as? String, !text.isEmpty else { return nil }
        return text
    }

    // MARK: qq music
    static func qqmusic(_ t: Track) async -> String? {
        let h = ["Referer": "https://y.qq.com/"]
        let q = "\(cleantitle(t.title)) \(firstartist(t))"
        guard let r = await json(url("https://c.y.qq.com/soso/fcgi-bin/client_search_cp", ["w": q, "format": "json", "p": "1", "n": "10", "cr": "1", "new_json": "1"]), headers: h) as? [String: Any],
              let list = ((r["data"] as? [String: Any])?["song"] as? [String: Any])?["list"] as? [[String: Any]] else { return nil }
        let match = list.first { song in
            let singers = (song["singer"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            let secs = (song["interval"] as? Double) ?? 0
            return singers.contains { sameartist($0, firstartist(t)) } && closeenough(secs, t.duration)
        }
        guard let mid = match?["mid"] as? String,
              let l = await json(url("https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg", ["songmid": mid, "format": "json", "nobase64": "1"]), headers: h) as? [String: Any],
              let text = l["lyric"] as? String, !text.isEmpty else { return nil }
        return decodeentities(text)
    }

    // MARK: kugou
    static func kugou(_ t: Track) async -> String? {
        let q = "\(cleantitle(t.title)) \(firstartist(t))"
        guard let r = await json(url("https://mobileservice.kugou.com/api/v3/search/song", ["format": "json", "keyword": q, "page": "1", "pagesize": "10"])) as? [String: Any],
              let infos = (r["data"] as? [String: Any])?["info"] as? [[String: Any]] else { return nil }
        let match = infos.first { i in
            let artist = (i["singername"] as? String) ?? ""
            let secs = (i["duration"] as? Double) ?? 0
            return sameartist(artist, firstartist(t)) && closeenough(secs, t.duration)
        }
        guard let hash = match?["hash"] as? String,
              let c = await json(url("https://lyrics.kugou.com/search", ["ver": "1", "man": "yes", "client": "pc", "keyword": q, "duration": String(Int(t.duration * 1000)), "hash": hash])) as? [String: Any],
              let cand = (c["candidates"] as? [[String: Any]])?.first,
              let id = (cand["id"] as? String) ?? (cand["id"] as? Int).map(String.init), let key = cand["accesskey"] as? String,
              let d = await json(url("https://lyrics.kugou.com/download", ["ver": "1", "client": "pc", "id": id, "accesskey": key, "fmt": "lrc", "charset": "utf8"])) as? [String: Any],
              let b64 = d["content"] as? String, let data = Data(base64Encoded: b64),
              let text = String(data: data, encoding: .utf8)?.replacingOccurrences(of: "\u{FEFF}", with: ""), !text.isEmpty else { return nil }
        return text
    }
}
