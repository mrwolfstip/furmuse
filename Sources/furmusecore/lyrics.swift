import Foundation

struct LyricWord: Codable { var time: Double; var end: Double; var text: String; var roman: String? = nil }
struct LyricLine: Codable {
    var time: Double; var end: Double; var text: String; var words: [LyricWord]; var estimated = false
    var roman: String? = nil               // cached romanization of text (nil when the line is latin already)
    var background: String? = nil          // ad-lib / background vocal line (ttml x-bg spans)
    var backgroundroman: String? = nil
    var backgroundwords: [LyricWord]? = nil
    var opposite = false
    var translation: String? = nil
}
struct LyricsCredit: Codable, Equatable {
    var name: String
    var url: String
}
struct LyricsDoc: Codable {
    var lines: [LyricLine]
    var synced: Bool
    var source: String
    var uploader: LyricsCredit? = nil
    var maker: LyricsCredit? = nil
}

enum LyricsParser {
    static func clock(_ s: String) -> Double? {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasSuffix("s") { t.removeLast(); return Double(t) }
        let parts = t.split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, !parts.contains(where: { $0 == nil }) else { return nil }
        return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
    }

    // lrc time tags: [mm:ss], [mm:ss.xx] and the odd [mm:ss:xx] (the last part is hundredths, not seconds)
    static func lrcclock(_ s: String) -> Double? {
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 || parts.count == 3, let m = Double(parts[0]) else { return nil }
        if parts.count == 2 { return Double(parts[1]).map { m * 60 + $0 } }
        guard let sec = Double(parts[1]), let frac = Double("0." + parts[2]) else { return nil }
        return m * 60 + sec + frac
    }

    static func lrc(_ text: String, source: String) -> LyricsDoc? {
        guard let tag = try? NSRegularExpression(pattern: "\\[(\\d+:\\d+(?:[.:]\\d+)?)\\]"),
              let wtag = try? NSRegularExpression(pattern: "<(\\d+:\\d+(?:[.:]\\d+)?)>"),
              let offsettag = try? NSRegularExpression(pattern: "^\\s*\\[offset:\\s*([+-]?\\d+)\\s*\\]", options: [.caseInsensitive]) else { return nil }
        var offset = 0.0                      // [offset:ms]: positive values make the lyrics appear earlier
        var lines: [LyricLine] = []
        var plain: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let ns = raw as NSString
            if let m = offsettag.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)), let ms = Double(ns.substring(with: m.range(at: 1))) {
                offset = ms / 1000
                continue
            }
            let tags = tag.matches(in: raw, range: NSRange(location: 0, length: ns.length))
            guard !tags.isEmpty else {
                let t = raw.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty, !t.hasPrefix("[") { plain.append(t) }
                continue
            }
            let body = ns.substring(from: tags.last!.range.location + tags.last!.range.length)
            for m in tags {
                guard let t = lrcclock(ns.substring(with: m.range(at: 1))) else { continue }
                var words: [LyricWord] = []
                let bs = body as NSString
                let wm = wtag.matches(in: body, range: NSRange(location: 0, length: bs.length))
                for (i, w) in wm.enumerated() {
                    let start = lrcclock(bs.substring(with: w.range(at: 1))) ?? t
                    let from = w.range.location + w.range.length
                    let to = i + 1 < wm.count ? wm[i + 1].range.location : bs.length
                    let word = bs.substring(with: NSRange(location: from, length: max(0, to - from)))
                    let end = i + 1 < wm.count ? (lrcclock(bs.substring(with: wm[i + 1].range(at: 1))) ?? start) : start + 0.5
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
        if offset != 0 {
            for i in lines.indices {
                lines[i].time = max(0, lines[i].time - offset)
                for j in lines[i].words.indices {
                    lines[i].words[j].time = max(0, lines[i].words[j].time - offset)
                    lines[i].words[j].end = max(0, lines[i].words[j].end - offset)
                }
            }
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
        // Keep explicit overlapping TTML intervals. Duets commonly put two vocal lines over the
        // same time range; clipping every line to the next line's start cut the first singer off.
        return LyricsDoc(lines: lines, synced: true, source: source)
    }

    private final class TTMLDelegate: NSObject, XMLParserDelegate {
        var lines: [LyricLine] = []
        private var cur: LyricLine?
        private var spanstart: Double?
        private var spanend = 0.0
        private var buf = ""
        private var inspan = false
        private var depth = 0               // span nesting depth
        private var bgdepth: Int?           // depth of the open ttm:role="x-bg" span, when inside one
        private var bgbuf = ""
        private var bgwords: [LyricWord] = []
        private var primaryagent: String?

        private func local(_ n: String) -> String { n.components(separatedBy: ":").last ?? n }

        func parser(_ parser: XMLParser, didStartElement rawname: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
            let name = local(rawname)
            if name == "p" {
                let t = a["begin"].flatMap { LyricsParser.clock($0) } ?? 0
                let e = a["end"].flatMap { LyricsParser.clock($0) } ?? t
                let agent = a.first(where: { local($0.key) == "agent" })?.value
                if primaryagent == nil, let agent, !agent.isEmpty { primaryagent = agent }
                cur = LyricLine(time: t, end: e, text: "", words: [], opposite: agent != nil && agent != primaryagent)
                depth = 0; bgdepth = nil; inspan = false
            } else if name == "span", cur != nil {
                depth += 1
                let role = a.first(where: { local($0.key) == "role" })?.value
                if role == "x-bg", bgdepth == nil {
                    bgdepth = depth
                    bgbuf = ""
                    bgwords = []
                } else {
                    inspan = true
                    buf = ""
                    spanstart = a["begin"].flatMap { LyricsParser.clock($0) }
                    spanend = a["end"].flatMap { LyricsParser.clock($0) } ?? 0
                }
            } else if name == "br" {
                if bgdepth != nil { bgbuf += " " } else { cur?.text += " " }
            }
        }

        func parser(_ parser: XMLParser, foundCharacters s: String) {
            if inspan { buf += s }
            else if bgdepth != nil { bgbuf += s }
            else if cur != nil {
                cur?.text += s
                // apple ttml puts the space between words outside the spans; keep it on the previous word so words join correctly
                if s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !s.isEmpty, let n = cur?.words.count, n > 0,
                   cur?.words[n - 1].text.last?.isWhitespace == false { cur?.words[n - 1].text += " " }
            }
        }

        func parser(_ parser: XMLParser, didEndElement rawname: String, namespaceURI: String?, qualifiedName: String?) {
            let name = local(rawname)
            if name == "span", cur != nil {
                if inspan {
                    inspan = false
                    if bgdepth != nil {
                        bgbuf += buf
                        if let s = spanstart, !buf.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            bgwords.append(LyricWord(time: s, end: max(spanend, s), text: buf))
                        }
                    }
                    else {
                        cur?.text += buf
                        if let s = spanstart { cur?.words.append(LyricWord(time: s, end: max(spanend, s), text: buf)) }
                    }
                } else if bgdepth == depth {
                    var t = bgbuf.trimmingCharacters(in: .whitespacesAndNewlines)
                    if t.hasPrefix("("), t.hasSuffix(")") { t = String(t.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces) }
                    if !t.isEmpty { cur?.background = t; cur?.backgroundwords = bgwords.isEmpty ? nil : bgwords }
                    bgdepth = nil
                }
                depth = max(0, depth - 1)
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
    private var loadedkey = ""          // track id + the settings a load depends on, so toggling them reloads
    private var serial = 0              // bumps on every published doc, so a late romanization never lands on a newer one

    init(settings: Settings) {
        self.settings = settings
        dir = LibraryStore.supportdir.appendingPathComponent("lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // the line being sung (with its cached romanization), for the lock screen
    func currentlyric(for trackid: String, at position: Double) -> LyricLine? {
        guard forid == trackid, let doc, doc.synced else { return nil }
        guard let line = doc.lines.last(where: { $0.time <= position && position < $0.end }),
              !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return line
    }

    func currentline(for trackid: String, at position: Double) -> String? { currentlyric(for: trackid, at: position)?.text }

    // the doc only counts for the track it was loaded for (the previous song's lyrics must never show on the next one)
    func doc(for trackid: String) -> LyricsDoc? { forid == trackid ? doc : nil }

    // effective romanization for a song: its own choice when it has one, otherwise the app settings. off / replace / below / current
    func romanmode(for trackid: String, library: LibraryStore) -> String {
        let modes = ["replace", "below", "current"]
        if let m = library.romanization(trackid), m == "off" || modes.contains(m) { return m }
        guard settings.lyricsromanize else { return "off" }
        return modes.contains(settings.lyricsromanstyle) ? settings.lyricsromanstyle : "replace"
    }

    // publish a doc right away, then fill the romanization cache off the main thread and publish the annotated copy
    @MainActor
    private func publish(_ x: LyricsDoc, id: String) {
        doc = x
        serial += 1
        let mine = serial
        // the romanizing runs detached; the result comes back to the main actor, where self is only touched
        Task { [weak self] in
            let annotated = await Task.detached(priority: .utility) { LyricRomanizer.annotate(x) }.value
            guard let annotated, let self, self.serial == mine, self.forid == id else { return }
            self.doc = annotated
        }
    }

    private func path(_ id: String, _ ext: String) -> URL { dir.appendingPathComponent("\(id).\(ext)") }

    func hasuser(_ id: String) -> Bool { ["lrc", "ttml"].contains { FileManager.default.fileExists(atPath: path(id, $0).path) } }

    @MainActor
    func load(_ t: Track, refetch: Bool = false) async {
        if refetch, hasuser(t.id) { ToastCenter.shared.show("remove your lyrics first"); return }   // saved lyrics would win again and nothing would change
        let key = "\(t.id)|\(settings.lyricson)|\(settings.lyricsnet)|\(settings.lyricsmore)|\(settings.offlineonly)|\(settings.spicycommunity)|\(settings.spicyapple)|\(settings.spicyspotify)"
        guard loadedkey != key || refetch else { return }
        loadedkey = key
        forid = t.id
        doc = nil
        serial += 1
        status = ""
        guard settings.lyricson else { status = "lyrics are off"; return }
        if let d = try? Data(contentsOf: path(t.id, "ttml")), let x = LyricsParser.ttml(d, source: "your ttml") { publish(x, id: t.id); return }
        if let s = try? String(contentsOf: path(t.id, "lrc"), encoding: .utf8), let x = LyricsParser.lrc(s, source: "your lrc") { publish(x, id: t.id); return }
        if !refetch, let d = try? Data(contentsOf: path(t.id, "lyricsjson")), let x = try? JSONDecoder().decode(LyricsDoc.self, from: d) { publish(x, id: t.id); return }
        // spotify has no official lyrics api, so there is no spotify step here
        if !refetch, let s = try? String(contentsOf: path(t.id, "cache"), encoding: .utf8), let x = LyricsParser.lrc(s, source: (try? String(contentsOf: path(t.id, "src"), encoding: .utf8)) ?? "lyrics cache") { publish(x, id: t.id); return }
        guard settings.lyricsnet, !settings.offlineonly else { status = "no lyrics stored for this track"; return }
        loadingid = t.id
        defer { if loadingid == t.id { loadingid = "" } }     // a newer song may have taken the spinner over
        var plainfallback: LyricsDoc?
        for p in LyricsProviders.chain(settings: settings) {
            guard forid == t.id else { return }
            guard let x = await p.fetch(t, settings: settings) else { continue }
            if x.synced {
                guard forid == t.id else { return }
                if let data = try? JSONEncoder().encode(x) { try? data.write(to: path(t.id, "lyricsjson"), options: .atomic) }
                publish(x, id: t.id)
                return
            }
            if plainfallback == nil { plainfallback = x }   // keep looking for a synced version on the next source
        }
        guard forid == t.id else { return }
        if let x = plainfallback {
            if let data = try? JSONEncoder().encode(x) { try? data.write(to: path(t.id, "lyricsjson"), options: .atomic) }
            publish(x, id: t.id)
        } else { status = "no lyrics found" }
    }

    @MainActor
    func save(_ text: String, ext: String, for t: Track) async {
        try? FileManager.default.removeItem(at: path(t.id, "lrc"))
        try? FileManager.default.removeItem(at: path(t.id, "ttml"))
        try? text.write(to: path(t.id, ext), atomically: true, encoding: .utf8)
        forid = ""; loadedkey = ""
        await load(t)
        if doc == nil, settings.lyricson { status = "couldn't read that lyrics file" }     // with lyrics off the file is saved but not shown
    }

    @MainActor
    func removeuser(for t: Track) async {
        try? FileManager.default.removeItem(at: path(t.id, "lrc"))
        try? FileManager.default.removeItem(at: path(t.id, "ttml"))
        forid = ""; loadedkey = ""
        await load(t)
    }

    func clearcache() {
        let fm = FileManager.default
        for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where ["cache", "src", "lyricsjson"].contains(f.pathExtension) { try? fm.removeItem(at: f) }
    }

    func clearall() {
        let fm = FileManager.default
        for file in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: file)
        }
        doc = nil; status = ""; loadingid = ""; forid = ""; loadedkey = ""; serial += 1
    }
}

// MARK: online sources. each one returns lrc text (synced when it can) or nil. all of them are unofficial public endpoints, so
// every call is short-timeout and failure just moves on to the next source.
protocol LyricsProvider: Sendable {
    var id: String { get }
    var name: String { get }
    func fetch(_ track: Track, settings: Settings) async -> LyricsDoc?
}

struct TextLyricsProvider: LyricsProvider, @unchecked Sendable {
    let id: String
    let name: String
    let loader: @Sendable (Track) async -> String?
    func fetch(_ track: Track, settings: Settings) async -> LyricsDoc? {
        guard let text = await loader(track), !text.isEmpty else { return nil }
        return LyricsParser.lrc(text, source: name)
    }
}

enum LyricsProviders {
    static let labels = ["spicy": "spicy lyrics", "lrclib": "lrclib", "netease": "netease", "qq": "qq music", "kugou": "kugou"]

    static func chain(settings: Settings) -> [any LyricsProvider] {
        let all: [String: any LyricsProvider] = [
            "spicy": SpicyLyrics.shared,
            "lrclib": TextLyricsProvider(id: "lrclib", name: "lrclib") { track in
                if let exact = await lrclibget(track) { return exact }
                return await lrclibsearch(track)
            },
            "netease": TextLyricsProvider(id: "netease", name: "netease") { await netease($0) },
            "qq": TextLyricsProvider(id: "qq", name: "qq music") { await qqmusic($0) },
            "kugou": TextLyricsProvider(id: "kugou", name: "kugou") { await kugou($0) }
        ]
        return settings.lyricsproviderorder.filter { !settings.lyricsdisabledproviders.contains($0) }.compactMap { all[$0] }
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
