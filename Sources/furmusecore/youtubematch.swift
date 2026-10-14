import Foundation
import AVFoundation

struct YouTubeCandidate: Identifiable {
    let id: String
    let title: String
    var channel = ""
    var duration: Double?
}

// search + scoring for automatic source finding. the actual stream resolution stays in YouTubeResolver.
enum YouTubeSearch {
    static func videoid(from text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count == 11, t.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil { return t }
        guard let u = URLComponents(string: t) else { return nil }
        if let v = u.queryItems?.first(where: { $0.name == "v" })?.value, v.count == 11 { return v }
        if u.host?.contains("youtu.be") == true { let p = String(u.path.dropFirst()); if p.count == 11 { return p } }
        let parts = u.path.split(separator: "/").map(String.init)
        if let i = parts.firstIndex(where: { ["shorts", "embed", "live"].contains($0) }), parts.count > i + 1, parts[i + 1].count == 11 { return parts[i + 1] }
        return nil
    }

    private static let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    private static func clock(_ s: String) -> Double? {
        let p = s.split(separator: ":").compactMap { Int($0) }
        guard !p.isEmpty, p.count <= 3, p.count == s.split(separator: ":").count else { return nil }
        return Double(p.reduce(0) { $0 * 60 + $1 })
    }

    private static func text(_ any: Any?) -> String {
        guard let d = any as? [String: Any] else { return "" }
        if let s = d["simpleText"] as? String { return s }
        return (d["runs"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined() ?? ""
    }

    private static func collect(_ any: Any, _ out: inout [YouTubeCandidate]) {
        if let d = any as? [String: Any] {
            if let v = d["videoRenderer"] as? [String: Any], let id = v["videoId"] as? String, id.count == 11 {
                let ch = text(v["ownerText"]).isEmpty ? text(v["longBylineText"]) : text(v["ownerText"])
                out.append(YouTubeCandidate(id: id, title: text(v["title"]), channel: ch, duration: clock(text(v["lengthText"]))))
            }
            for (_, val) in d { collect(val, &out) }
        } else if let a = any as? [Any] {
            for x in a { collect(x, &out) }
        }
    }

    private static func parse(_ json: Any) -> [YouTubeCandidate] {
        var raw: [YouTubeCandidate] = []
        collect(json, &raw)
        var seen = Set<String>()
        return raw.filter { seen.insert($0.id).inserted }
    }

    private static func innertube(_ q: String) async -> [YouTubeCandidate] {
        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/search?prettyPrint=false") else { return [] }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        req.setValue("CONSENT=YES+1", forHTTPHeaderField: "Cookie")
        let body: [String: Any] = [
            "context": ["client": ["clientName": "WEB", "clientVersion": "2.20250101.00.00", "hl": "en", "gl": "US"]],
            "query": q,
            "params": "EgIQAQ=="   // videos only
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        return parse(json)
    }

    private static func htmlsearch(_ q: String) async -> [YouTubeCandidate] {
        var c = URLComponents(string: "https://www.youtube.com/results")!
        c.queryItems = [.init(name: "search_query", value: q), .init(name: "sp", value: "EgIQAQ==")]
        guard let url = c.url else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("CONSENT=YES+1", forHTTPHeaderField: "Cookie")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        guard let (data, _) = try? await URLSession.shared.data(for: req), let html = String(data: data, encoding: .utf8),
              let a = html.range(of: "ytInitialData = ") else { return [] }
        let rest = html[a.upperBound...]
        guard let b = rest.range(of: ";</script>"), let json = try? JSONSerialization.jsonObject(with: Data(rest[..<b.lowerBound].utf8)) else { return [] }
        return parse(json)
    }

    // the same queries the automatic matcher uses, so the source popup and the resolver look in the same places
    static func queries(for t: Track) -> [String] {
        let primary = t.artist.components(separatedBy: ",").first ?? t.artist
        let clean = t.title.replacingOccurrences(of: "\\s*[\\(\\[].*?[\\)\\]]", with: "", options: .regularExpression)
        var q = ["\(primary) \(t.title)", "\(primary) - \(clean) audio", "\(primary) \(clean) topic"]
        var seen = Set<String>()
        q = q.filter { seen.insert($0.lowercased()).inserted }
        return q
    }

    // every candidate for a track across those queries, de-duplicated
    static func candidates(for t: Track, limit: Int = 24) async -> [YouTubeCandidate] {
        let qs = queries(for: t)
        var byQuery: [Int: [YouTubeCandidate]] = [:]
        await withTaskGroup(of: (Int, [YouTubeCandidate]).self) { group in
            for (index, query) in qs.enumerated() {
                group.addTask { (index, await search(query)) }
            }
            for await (index, result) in group { byQuery[index] = result }
        }
        var pool: [YouTubeCandidate] = []
        var seen = Set<String>()
        for index in qs.indices {
            for c in byQuery[index, default: []] where seen.insert(c.id).inserted { pool.append(c) }
            if pool.count >= limit { break }
        }
        return Array(pool.prefix(limit))
    }

    static func thumbnail(_ id: String) -> URL? { URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg") }

    static func search(_ q: String) async -> [YouTubeCandidate] {
        let r = await innertube(q)
        return r.isEmpty ? await htmlsearch(q) : r
    }

    // duration of what the stream url really contains
    static func streamduration(_ url: URL) async -> Double? {
        await withTaskGroup(of: Double?.self) { g in
            g.addTask {
                let a = AVURLAsset(url: url)
                if let d = try? await a.load(.duration), d.seconds.isFinite, d.seconds > 0 { return d.seconds }
                return nil
            }
            g.addTask { try? await Task.sleep(nanoseconds: 10_000_000_000); return nil }
            let first: Double? = (await g.next()) ?? nil
            g.cancelAll()
            return first
        }
    }
}

enum YouTubeMatcher {
    static func norm(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
            .replacingOccurrences(of: "&", with: " and ")
        let cleaned = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(cleaned).split(separator: " ").joined(separator: " ")
    }

    // "Song (feat. X) - Remastered 2011" -> "song"
    static func cleantitle(_ s: String) -> String {
        var t = s
        for pat in ["\\([^)]*\\)", "\\[[^\\]]*\\]", "\\s-\\s.*$", "(?i)\\bfeat\\.?.*$", "(?i)\\bft\\.?.*$"] {
            t = t.replacingOccurrences(of: pat, with: " ", options: .regularExpression)
        }
        let r = norm(t)
        return r.isEmpty ? norm(s) : r
    }

    private static let bad: [String] = ["live", "remix", "cover", "sped up", "speed up", "speedup", "slowed", "reverb", "instrumental", "extended", "karaoke",
                                        "nightcore", "8d", "bass boosted", "mashup", "reaction", "tutorial", "acoustic", "piano version", "orchestral",
                                        "1 hour", "10 hours", "full album", "lesson", "tribute", "parody", "mix"]

    private static let artistnoise: Set<String> = ["topic", "vevo", "official", "music", "records", "channel", "the"]

    static func tolerance(_ d: Double) -> (tight: Double, loose: Double) { (max(5, d * 0.03), max(15, d * 0.08)) }

    // nil = rejected (reason says why). higher score = better.
    static func score(_ c: YouTubeCandidate, for track: Track) -> (score: Double?, reason: String) {
        let vt = norm(c.title)
        let vtokens = Set(vt.split(separator: " ").map(String.init))
        let own = norm(track.title + " " + track.album)
        for w in bad where (" " + vt + " ").contains(" " + w + " ") && !(" " + own + " ").contains(" " + w + " ") {
            return (nil, "looks like a \(w) version")
        }
        let tt = cleantitle(track.title).split(separator: " ").map(String.init)
        guard !tt.isEmpty else { return (nil, "track has no title") }
        let hit = Double(tt.filter { vtokens.contains($0) || ($0.count > 3 && vt.contains($0)) }.count) / Double(tt.count)
        if hit < (tt.count <= 2 ? 1.0 : 0.75) { return (nil, "title doesn't match") }

        let primary = track.artist.components(separatedBy: ",").first ?? track.artist
        let at = norm(primary).split(separator: " ").map(String.init).filter { !artistnoise.contains($0) }
        let pool = vtokens.union(norm(c.channel).split(separator: " ").map(String.init))
        let ahit = at.isEmpty ? 1.0 : Double(at.filter { pool.contains($0) || norm(c.channel).contains($0) || vt.contains($0) }.count) / Double(at.count)
        if ahit < 0.6 { return (nil, "artist doesn't match") }

        var dscore = 0.5
        if track.duration > 0 {
            guard let d = c.duration else { return (nil, "unknown duration") }
            let diff = abs(d - track.duration), tol = tolerance(track.duration)
            if diff > tol.loose { return (nil, "duration differs by \(Int(diff))s") }
            dscore = diff <= tol.tight ? 1.0 : 1.0 - 0.6 * (diff - tol.tight) / max(1, tol.loose - tol.tight)
        }
        var bonus = 0.0
        let ch = norm(c.channel)
        if ch.contains("topic") || ch.contains("vevo") || ch.contains("official") { bonus += 0.15 }
        if vt.contains("official audio") { bonus += 0.1 }
        if vt.contains("music video") || vt.contains("official video") { bonus -= 0.05 }
        return (0.35 * hit + 0.2 * ahit + 0.35 * dscore + bonus, "")
    }

    static let threshold = 0.7

    static func rank(_ cands: [YouTubeCandidate], for track: Track) -> (ok: [(YouTubeCandidate, Double)], why: String) {
        var ok: [(YouTubeCandidate, Double)] = []
        var why = ""
        for c in cands {
            let r = score(c, for: track)
            if let s = r.score, s >= threshold { ok.append((c, s)) } else if why.isEmpty { why = "\"\(c.title)\": \(r.reason.isEmpty ? "weak match" : r.reason)" }
        }
        return (ok.sorted { $0.1 > $1.1 }, why)
    }

    static func durationok(_ found: Double, _ track: Track) -> Bool {
        guard track.duration > 0 else { return true }
        return abs(found - track.duration) <= tolerance(track.duration).loose
    }
}
