import Foundation
import AVFoundation
import CryptoKit

// youtube audio as a playback source. the resolver (resolver.swift / youtubematch.swift) decides WHICH stream;
// this wrapper only turns a resolved stream into something the shared graph can play:
//   decodable container -> cached to disk (youtube audio only, never spotify) -> LocalFileSource on the shared graph
//   hls / cache failure  -> AVPlayerStreamSource (speed works, effects don't)
final class YouTubeSource: PlaybackSource {
    let kind: SourceKind = .youtube
    var info: String { inner?.info ?? "" }
    var duration: Double { inner?.duration ?? track.duration }
    var position: Double { inner?.position ?? 0 }
    var onEnd: (() -> Void)? { didSet { inner?.onEnd = onEnd } }
    var onFail: ((String) -> Void)? { didSet { inner?.onFail = onFail } }

    private let track: Track
    private let resolver: ResolverManager
    private let graph: SharedAudioGraph
    private let fresh: Bool
    private let settings: Settings
    private var inner: PlaybackSource?
    private var cachetask: Task<Void, Never>?

    static let decodable: Set<String> = ["m4a", "mp4", "aac", "mp3", "wav", "caf", "flac", "alac"]
    static let cachedir: URL = {
        var u = LibraryStore.supportdir.appendingPathComponent("ytcache", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        var v = URLResourceValues(); v.isExcludedFromBackup = true
        try? u.setResourceValues(v)
        return u
    }()

    init(track: Track, resolver: ResolverManager, graph: SharedAudioGraph, settings: Settings, fresh: Bool) {
        self.track = track; self.resolver = resolver; self.graph = graph; self.settings = settings; self.fresh = fresh
    }

    func prepare() async throws {
        let s: ResolvedSource
        do { s = try await resolver.resolve(track, fresh: fresh) } catch let e as ResolveError { throw SourceError.unavailable(e.text) } catch { throw SourceError.unavailable("couldn't resolve a youtube source") }
        let ok = ["m4a", "mp4", "aac", "mp3", "m3u8", "hls", "wav", "caf", "flac", "alac"]
        guard ok.contains(s.container) else { throw SourceError.unavailable("\(s.container)/\(s.codec) can't be played") }
        let label = [s.container, s.codec, s.bitrate.map { "\($0 / 1000)kbps" }, s.origin].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        var made: PlaybackSource?
        if YouTubeSource.decodable.contains(s.container), let f = cachedFile(s) { made = await openlocal(f, label: label) }
        // Advanced YouTube is explicitly the graph/effects backend. Download the authenticated
        // audio first so the very first play goes through AVAudioEngine rather than AVPlayer.
        if made == nil, settings.youtubebackend == .advanced, YouTubeSource.decodable.contains(s.container),
           let f = await cached(s) { made = await openlocal(f, label: label) }
        if made == nil {
            // A cache miss used to download the entire track before playback. Start AVPlayer against
            // the resolved URL now and warm the graph-compatible cache at utility priority.
            let ceiling = track.duration > 0 ? track.duration + 3 : 0
            let src = AVPlayerStreamSource(kind: .youtube, url: s.url, duration: ceiling, info: label + " · instant stream")
            try await src.prepare()
            made = src
            if YouTubeSource.decodable.contains(s.container), !s.url.isFileURL {
                cachetask = Task(priority: .utility) { [weak self] in
                    guard let self = self else { return }
                    // Give AVPlayer first use of the connection while it fills its startup
                    // buffer; the cache warm-up is deliberately off the critical path.
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard !Task.isCancelled else { return }
                    _ = await self.cached(s)
                }
            }
            Log.i(.youtube, "streaming \(track.id) immediately; effects become available from cache next time")
        }
        inner = made
        inner?.onEnd = onEnd
        inner?.onFail = onFail
    }

    // opens an audio file on the shared graph, with any long trailing silence cut off. nil = unusable (truncated, wrong, or unreadable)
    private func openlocal(_ f: URL, label: String) async -> PlaybackSource? {
        let trim = await SilenceTrim.end(of: f)
        let ceiling = track.duration > 0 ? track.duration + 3 : nil
        let end = [trim, ceiling].compactMap { $0 }.min()
        let src = LocalFileSource(kind: .youtube, url: f, graph: graph, info: label + " · graph" + (end != nil ? " · duration limited" : ""), endlimit: end)
        do {
            try await src.prepare()
            let d = src.duration
            if track.duration > 0, d > 0, d < track.duration - YouTubeMatcher.tolerance(track.duration).loose {
                // the audio is much shorter than the song: it is truncated (or the wrong video). never play it.
                Log.w(.youtube, "cached audio is \(fmttime(d)) but the track is \(fmttime(track.duration)); discarding cache for \(track.id)")
                src.stop()
                YouTubeSource.discard(f)
                return nil
            }
            if let t = trim { Log.i(.youtube, "playing \(track.id) up to \(fmttime(t)); the silent tail is skipped") }
            else if track.duration > 0, d > track.duration + YouTubeMatcher.tolerance(track.duration).loose {
                Log.w(.youtube, "cached audio is \(fmttime(d)), \(fmttime(d - track.duration)) longer than the track \(fmttime(track.duration)) and has no silent tail; playing it in full")
            }
            return src
        } catch {
            Log.w(.youtube, "cached file wouldn't open, streaming immediately: \(error.localizedDescription)")
            YouTubeSource.discard(f)
            return nil
        }
    }

    private func cached(_ s: ResolvedSource) async -> URL? {
        if s.url.isFileURL { return s.url }
        let dest = cacheURL(s)
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        do {
            let tmp = try await fetchall(s.url)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            YouTubeSource.trim(keep: dest)
            Log.i(.youtube, "cached youtube audio for \(track.id)")
            return dest
        } catch {
            Log.w(.youtube, "couldn't cache youtube audio: \(error.localizedDescription)")
            return nil
        }
    }

    private func cacheURL(_ s: ResolvedSource) -> URL {
        let key = SHA256.hash(data: Data((track.id + s.origin).utf8)).map { String(format: "%02x", $0) }.joined().prefix(24)
        return YouTubeSource.cachedir.appendingPathComponent("\(key).\(s.container == "hls" ? "m4a" : s.container)")
    }

    private func cachedFile(_ s: ResolvedSource) -> URL? {
        if s.url.isFileURL { return s.url }
        let url = cacheURL(s)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // youtube throttles and sometimes cuts off one long request, which used to leave a half-written file that
    // still reported the full length (the "3 minutes left" symptom). fetch in 2 MiB ranges and refuse a short file.
    private func fetchall(_ url: URL) async throws -> URL {
        let cfg = URLSessionConfiguration.default
        cfg.allowsCellularAccess = !settings.wifionly
        let session = URLSession(configuration: cfg)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".part")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let fh = try FileHandle(forWritingTo: out)
        var completed = false
        defer {
            try? fh.close()
            if !completed { try? FileManager.default.removeItem(at: out) }
        }
        let step = 2 * 1024 * 1024
        var offset = 0
        var total: Int?
        var finished = false
        while !finished {
            try Task.checkCancellation()
            var req = URLRequest(url: url); req.timeoutInterval = 30
            req.setValue("bytes=\(offset)-\(offset + step - 1)", forHTTPHeaderField: "Range")
            let (data, resp) = try await session.data(for: req)
            guard let h = resp as? HTTPURLResponse, h.statusCode == 200 || h.statusCode == 206 else {
                throw SourceError.failed("youtube refused the audio download (\((resp as? HTTPURLResponse)?.statusCode ?? 0))")
            }
            if h.statusCode == 200 {
                // server ignored the range: it sent the whole file in one go
                try fh.write(contentsOf: data)
                offset = data.count
                total = h.expectedContentLength > 0 ? Int(h.expectedContentLength) : data.count
                finished = true
                continue
            }
            if let cr = h.value(forHTTPHeaderField: "Content-Range"), let slash = cr.lastIndex(of: "/"), let n = Int(cr[cr.index(after: slash)...]) { total = n }
            guard !data.isEmpty else { throw SourceError.failed("youtube sent an empty audio chunk at \(offset)") }
            try fh.write(contentsOf: data)
            offset += data.count
            if let t = total { finished = offset >= t } else if data.count < step { total = offset; finished = true }   // no total given: a short chunk is the end
        }
        guard let t = total, offset >= t else { throw SourceError.failed("audio download incomplete (\(offset) of \(total ?? 0) bytes)") }
        completed = true
        Log.i(.youtube, "downloaded \(offset) bytes for \(track.id)")
        return out
    }

    // only ever deletes files that furmuse cached itself
    private static func discard(_ f: URL) {
        guard f.standardizedFileURL.path.hasPrefix(cachedir.standardizedFileURL.path) else { return }
        try? FileManager.default.removeItem(at: f)
    }

    private static func trim(keep: URL, limit: Int = 25) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: cachedir, includingPropertiesForKeys: [.contentModificationDateKey]), files.count > limit else { return }
        let sorted = files.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) <
            ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        for f in sorted.prefix(files.count - limit) where f != keep { try? fm.removeItem(at: f) }
    }

    func play(from t: Double) { inner?.play(from: t) }
    func resume() { inner?.resume() }
    func pause() { inner?.pause() }
    func seek(to t: Double) { inner?.seek(to: t) }
    func stop() { inner?.stop(); inner = nil }
    func apply(_ s: Settings, playing: Bool) { inner?.apply(s, playing: playing) }
}
