import Foundation
import AVFoundation
import UIKit

// Apple Music animated covers, fetched through the m8tec "apple-music-animated-artworks" service (self-hostable; the url is a
// setting). OFF by default: when on, furmuse sends the artist and album name of tracks it plays / caches to that server,
// and the service scrapes Apple Music, so Apple's terms apply to that use. nothing here talks to Apple directly.
//
// flow: search endpoint -> json -> HLS (.m3u8) url(s) -> this file downloads the stream's segments and joins them into ONE local
// mp4 (the lock screen needs a local file, not a stream) -> first frame saved as the preview -> both cached on disk.
// results (and "this album has none") are cached, so each album costs at most one lookup.
//
// NOT TESTED: the service's json schema wasn't available when this was written, so the parser collects every ".m3u8" string in
// the response (preferring square over tall). the HLS joiner handles fMP4 (EXT-X-MAP) streams, with or without byte ranges.
struct AppleCover {
    let video: URL
    let preview: UIImage
}

final class AppleCovers: ObservableObject, @unchecked Sendable {
    static let shared = AppleCovers()
    var serverurl: () -> String = { "https://artwork.m8tec.top" }

    @Published private(set) var running = false
    @Published private(set) var done = 0
    @Published private(set) var total = 0
    @Published private(set) var found = 0
    @Published private(set) var status = ""
    @Published private(set) var revision = 0

    private let dir: URL
    private let lock = NSLock()
    private var cancelflag = false
    private var inflight = Set<String>()
    private let retryafter: TimeInterval = 14 * 24 * 3600

    private init() {
        var u = LibraryStore.supportdir.appendingPathComponent("applecovers", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        var v = URLResourceValues(); v.isExcludedFromBackup = true
        try? u.setResourceValues(v)
        dir = u
    }

    // ---- keys / cache ----------------------------------------------------------------------------------------------------
    static func firstartist(_ s: String) -> String {
        s.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? s
    }
    func key(artist: String, album: String) -> String {
        ArtworkMotion.key(AppleCovers.firstartist(artist).lowercased() + "|" + album.lowercased())
    }
    private func mp4(_ k: String) -> URL { dir.appendingPathComponent(k + ".mp4") }
    private func jpg(_ k: String) -> URL { dir.appendingPathComponent(k + ".jpg") }
    private func none(_ k: String) -> URL { dir.appendingPathComponent(k + ".none") }

    func cached(artist: String, album: String) -> AppleCover? {
        let k = key(artist: artist, album: album)
        guard FileManager.default.fileExists(atPath: mp4(k).path), let img = UIImage(contentsOfFile: jpg(k).path) else { return nil }
        return AppleCover(video: mp4(k), preview: img)
    }
    // true when a lookup already has an answer (a cover, or a recent "none")
    func resolved(artist: String, album: String) -> Bool {
        let k = key(artist: artist, album: album)
        if cached(artist: artist, album: album) != nil { return true }
        if let d = try? FileManager.default.attributesOfItem(atPath: none(k).path)[.modificationDate] as? Date { return Date().timeIntervalSince(d) < retryafter }
        return false
    }
    var cachecount: Int { ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".mp4") }.count }
    func clear() {
        for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] { try? FileManager.default.removeItem(at: dir.appendingPathComponent(f)) }
        publish { self.found = 0; self.status = "cache cleared"; self.revision += 1 }
    }

    // synchronous lock helper: NSLock.lock()/unlock() can't be called directly from async functions in Swift 6 mode
    private func locked<T>(_ f: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return f() }

    private func publish(_ f: @escaping () -> Void) { if Thread.isMainThread { f() } else { DispatchQueue.main.async(execute: f) } }

    // ---- lookup -----------------------------------------------------------------------------------------------------------
    func cover(artist: String, album: String) async -> AppleCover? {
        if let c = cached(artist: artist, album: album) { return c }
        let k = key(artist: artist, album: album)
        if resolved(artist: artist, album: album) { return nil }
        let fresh = locked { inflight.insert(k).inserted }
        guard fresh else { return nil }
        defer { _ = locked { inflight.remove(k) } }
        let a = AppleCovers.firstartist(artist)
        do {
            let urls = try await search(artist: a, album: album)
            guard let pick = urls.first(where: { !$0.path.contains("tall") && !$0.path.contains("3x4") }) ?? urls.first else {
                try? Data().write(to: none(k)); return nil      // the service answered: this album has no animated cover
            }
            let tmp = dir.appendingPathComponent(k + ".part.mp4")
            try await HLSJoin.download(master: pick.url, to: tmp)
            guard let size = await ArtworkMotion.orientedSize(tmp), size.width > 0 else { throw HLSJoin.Failure(text: "joined file isn't playable") }
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: tmp)); gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 1200, height: 1200)
            let cg = try gen.copyCGImage(at: .zero, actualTime: nil)
            guard let data = UIImage(cgImage: cg).jpegData(compressionQuality: 0.9) else { throw HLSJoin.Failure(text: "preview") }
            try data.write(to: jpg(k), options: .atomic)
            try? FileManager.default.removeItem(at: mp4(k))
            try FileManager.default.moveItem(at: tmp, to: mp4(k))
            Log.i(.artwork, "apple animated cover cached (\(Int(size.width))x\(Int(size.height)))")
            publish { self.revision += 1 }
            return cached(artist: artist, album: album)
        } catch {
            Log.w(.artwork, "apple cover lookup failed: \((error as? HLSJoin.Failure)?.text ?? error.localizedDescription)")
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(k + ".part.mp4"))
            return nil                                           // not marked: a network problem should be retried later
        }
    }

    private struct Found { let path: String; let url: URL }

    private func search(artist: String, album: String) async throws -> [Found] {
        guard var comps = URLComponents(string: serverurl().trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) + "/api/v1/artwork/search") else { throw HLSJoin.Failure(text: "bad server url") }
        comps.queryItems = [URLQueryItem(name: "artist", value: artist), URLQueryItem(name: "album", value: album)]
        guard let url = comps.url else { throw HLSJoin.Failure(text: "bad server url") }
        var req = URLRequest(url: url); req.timeoutInterval = 25
        req.setValue("furmuse", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { return [] }
        guard code == 200 else { throw HLSJoin.Failure(text: "server answered \(code)") }
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var out: [Found] = []
        func walk(_ v: Any, _ path: String) {
            if let s = v as? String {
                if s.lowercased().contains(".m3u8"), let u = URL(string: s), u.scheme?.hasPrefix("http") == true { out.append(Found(path: path.lowercased(), url: u)) }
            } else if let d = v as? [String: Any] { for (k, x) in d { walk(x, path + "." + k) } }
            else if let a = v as? [Any] { for x in a { walk(x, path) } }
        }
        walk(json, "")
        return out
    }

    // ---- cache ahead ------------------------------------------------------------------------------------------------------
    func stop() { locked { cancelflag = true } }
    private var cancelled: Bool { locked { cancelflag } }

    // walks every track furmuse knows, one lookup per album (1.5 s apart, so the service isn't hammered), then makes sure every
    // track that has no Apple cover and no custom video has its generated loop ready, so every cover can animate on the lock screen
    func precache(tracks: [Track], useapple: Bool, library: LibraryStore) async {
        locked { cancelflag = false }
        var albums: [String: (artist: String, album: String)] = [:]
        for t in tracks { albums[key(artist: t.artist, album: t.album)] = (t.artist, t.album) }
        publish { self.running = true; self.done = 0; self.total = albums.count + tracks.count; self.found = 0; self.status = "looking up albums…" }
        var covered = Set<String>()
        if useapple {
            for (k, a) in albums {
                if cancelled { break }
                let had = resolved(artist: a.artist, album: a.album)
                if let _ = await cover(artist: a.artist, album: a.album) { covered.insert(k); publish { self.found += 1 } }
                publish { self.done += 1 }
                if !had { try? await Task.sleep(nanoseconds: 1_500_000_000) }
            }
        } else { publish { self.done += albums.count } }
        publish { self.status = "preparing loops for the rest…" }
        for t in tracks {
            if cancelled { break }
            defer { publish { self.done += 1 } }
            let hasvideo: Bool = await MainActor.run { library.videourl(t.id) != nil }
            let shown: Track = await MainActor.run { library.shown(t) }
            if hasvideo || covered.contains(key(artist: t.artist, album: t.album)) { continue }
            guard let u = shown.artworkurl, let img = await ArtworkLoader.shared.image(u, maxpixel: 600) else { continue }
            let asp = ArtworkAspect.nearest(img.size.width / max(img.size.height, 1))
            _ = await ArtworkMotion.loopVideo(from: img.cropped(toAspect: asp.ratio) ?? img, aspect: asp, key: ArtworkMotion.key(u.absoluteString))
        }
        publish { self.running = false; self.status = self.cancelled ? "stopped" : "done" }
    }
}

// joins an HLS stream into one local file. fMP4 streams only (EXT-X-MAP init segment + media segments), which is what a
// single concatenated .mp4 can be made from; picks the largest variant up to 1920 px.
enum HLSJoin {
    struct Failure: Error { let text: String }

    private static func attrs(_ line: String) -> [String: String] {
        var out: [String: String] = [:]
        guard let colon = line.firstIndex(of: ":") else { return out }
        var key = "", val = "", inkey = true, quoted = false
        func flush() { if !key.isEmpty { out[key] = val }; key = ""; val = ""; inkey = true }
        for ch in line[line.index(after: colon)...] {
            if ch == "\"" { quoted.toggle(); continue }
            if ch == "," && !quoted { flush(); continue }
            if ch == "=" && inkey && !quoted { inkey = false; continue }
            if inkey { key.append(ch) } else { val.append(ch) }
        }
        flush()
        return out
    }

    private static func get(_ url: URL, range: (off: Int, len: Int)? = nil) async throws -> Data {
        var r = URLRequest(url: url); r.timeoutInterval = 40
        if let g = range { r.setValue("bytes=\(g.off)-\(g.off + g.len - 1)", forHTTPHeaderField: "Range") }
        let (d, resp) = try await URLSession.shared.data(for: r)
        let c = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard c == 200 || c == 206 else { throw Failure(text: "segment answered \(c)") }
        return d
    }

    static func download(master: URL, to out: URL) async throws {
        var playlisturl = master
        var text = String(decoding: try await get(master), as: UTF8.self)
        if text.contains("#EXT-X-STREAM-INF") {
            var best: (px: Int, url: URL)?, smallest: (px: Int, url: URL)?
            let lines = text.components(separatedBy: .newlines)
            for (i, l) in lines.enumerated() where l.hasPrefix("#EXT-X-STREAM-INF") && i + 1 < lines.count {
                let uri = lines[i + 1].trimmingCharacters(in: .whitespaces)
                guard !uri.isEmpty, let u = URL(string: uri, relativeTo: master)?.absoluteURL else { continue }
                let res = (attrs(l)["RESOLUTION"] ?? "").split(separator: "x").compactMap { Int($0) }
                let w = res.first ?? 0, h = res.count > 1 ? res[1] : 0
                if smallest == nil || w * h < smallest!.px { smallest = (w * h, u) }
                if w <= 1920, h <= 1920, best == nil || w * h > best!.px { best = (w * h, u) }
            }
            guard let pick = best ?? smallest else { throw Failure(text: "no variants in playlist") }
            playlisturl = pick.url
            text = String(decoding: try await get(playlisturl), as: UTF8.self)
        }
        typealias Part = (url: URL, range: (off: Int, len: Int)?)
        var parts: [Part] = []
        var map: Part?
        var pending: (len: Int, off: Int?)?
        var next: [String: Int] = [:]          // next byte offset per uri, for "len" without "@offset"
        func resolve(_ s: String) -> URL? { URL(string: s, relativeTo: playlisturl)?.absoluteURL }
        func range(_ br: String, _ uri: URL) -> (off: Int, len: Int)? {
            let p = br.split(separator: "@")
            guard let len = Int(p[0]) else { return nil }
            let off = p.count > 1 ? Int(p[1]) ?? 0 : (next[uri.absoluteString] ?? 0)
            next[uri.absoluteString] = off + len
            return (off, len)
        }
        for l in text.components(separatedBy: .newlines).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if l.hasPrefix("#EXT-X-MAP") {
                let a = attrs(l)
                guard let u = a["URI"].flatMap(resolve) else { continue }
                map = (u, a["BYTERANGE"].flatMap { range($0, u) })
            } else if l.hasPrefix("#EXT-X-BYTERANGE:") {
                let v = String(l.dropFirst("#EXT-X-BYTERANGE:".count)).split(separator: "@")
                if let len = Int(v[0]) { pending = (len, v.count > 1 ? Int(v[1]) : nil) }
            } else if !l.isEmpty, !l.hasPrefix("#") {
                guard let u = resolve(l) else { continue }
                var r: (off: Int, len: Int)?
                if let p = pending {
                    let off = p.off ?? (next[u.absoluteString] ?? 0)
                    r = (off, p.len); next[u.absoluteString] = off + p.len
                }
                pending = nil
                parts.append((u, r))
            }
        }
        guard !parts.isEmpty else { throw Failure(text: "playlist has no segments") }
        guard map != nil else { throw Failure(text: "stream isn't fMP4 (no EXT-X-MAP); not supported") }
        guard parts.count <= 600 else { throw Failure(text: "too many segments") }

        try? FileManager.default.removeItem(at: out)
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let fh = try FileHandle(forWritingTo: out)
        defer { try? fh.close() }
        var written = 0
        // everything is one file addressed by byte ranges: fetch it whole instead of dozens of range requests
        let single = Set(parts.map { $0.url }).count == 1 && map!.url == parts[0].url
        if single {
            let d = try await get(parts[0].url)
            fh.write(d); written = d.count
        } else {
            for p in [map!] + parts {
                let d = try await get(p.url, range: p.range)
                fh.write(d); written += d.count
                guard written < 80_000_000 else { throw Failure(text: "stream too large") }
            }
        }
        guard written > 1000 else { throw Failure(text: "empty download") }
    }
}
