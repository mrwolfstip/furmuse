import Foundation
import AVFoundation
import UIKit

// Spotify Canvas (the short looping videos behind songs in the Spotify app) as one more animated cover, next to Apple's.
//
// the videos come from a copy of the "Spotify-Canvas-API" service that you run yourself (it needs your own sp_dc cookie, see its
// readme; furmuse never sees that cookie). the server url is a setting and the feature is OFF until a url is entered and the
// switch is on. flow: GET <server>/api/canvas?trackId=<spotify track id> -> json -> the .mp4 url (canvaz.scdn.co) -> the mp4 is
// downloaded once and kept on this device with a first-frame preview (the lock screen needs both). "this track has no canvas" is
// remembered for two weeks so each track costs at most one lookup; a network failure is not remembered and is retried later.
//
// the service uses undocumented Spotify endpoints and may break or go against Spotify's terms: that is on whoever runs it.
final class SpotifyCanvas: ObservableObject, @unchecked Sendable {
    static let shared = SpotifyCanvas()
    var serverurl: () -> String = { "" }
    @Published private(set) var status = ""

    private let dir: URL
    private let lock = NSLock()
    private var inflight: [String: Task<AppleCover?, Never>] = [:]
    private var serviceRetryAfter = Date.distantPast
    private let retryafter: TimeInterval = 14 * 24 * 3600

    private init() {
        var u = LibraryStore.supportdir.appendingPathComponent("spotifycanvas", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        var v = URLResourceValues(); v.isExcludedFromBackup = true
        try? u.setResourceValues(v)
        dir = u
    }

    private func mp4(_ id: String) -> URL { dir.appendingPathComponent(id + ".mp4") }
    private func jpg(_ id: String) -> URL { dir.appendingPathComponent(id + ".jpg") }
    // A negative answer belongs to one service. Switching service must retry instead of inheriting another server's miss.
    private func none(_ id: String) -> URL {
        let service = serverurl().trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return dir.appendingPathComponent(id + "-" + ArtworkMotion.key(service).prefix(10) + ".none")
    }
    private func locked<T>(_ f: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return f() }

    var configured: Bool { !serverurl().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var cachecount: Int { ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".mp4") }.count }
    func clear() {
        let running = locked { () -> [Task<AppleCover?, Never>] in
            let values = Array(inflight.values); inflight.removeAll(); return values
        }
        running.forEach { $0.cancel() }
        for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] { try? FileManager.default.removeItem(at: dir.appendingPathComponent(f)) }
        publish("cache cleared")
    }

    func cached(trackid: String) -> AppleCover? {
        guard FileManager.default.fileExists(atPath: mp4(trackid).path), let img = UIImage(contentsOfFile: jpg(trackid).path) else { return nil }
        return AppleCover(video: mp4(trackid), preview: img)
    }

    private func recentlynone(_ id: String) -> Bool {
        guard let d = try? FileManager.default.attributesOfItem(atPath: none(id).path)[.modificationDate] as? Date else { return false }
        return Date().timeIntervalSince(d) < retryafter
    }

    // the cached canvas, or one lookup + download. nil = none exists, not configured, or it failed (try again later)
    func cover(trackid: String) async -> AppleCover? {
        let id = Self.trackid(trackid)
        guard id.count == 22 else { publish("not a valid spotify track id"); return nil }
        guard configured else { publish("add a canvas server address first"); return nil }
        guard locked({ Date() >= serviceRetryAfter }) else { publish("canvas service is taking a break"); return nil }
        if let c = cached(trackid: id) { return c }
        if recentlynone(id) { publish("this song has no canvas"); return nil }
        let task: Task<AppleCover?, Never> = locked {
            if let running = inflight[id] { return running }
            let created = Task { [weak self] in await self?.fetch(trackid: id) }
            inflight[id] = created
            return created
        }
        let result = await task.value
        locked { inflight[id] = nil }
        return result
    }

    private func fetch(trackid: String) async -> AppleCover? {
        publish("finding canvas…")
        do {
            guard let video = try await lookup(trackid) else {
                try? Data().write(to: none(trackid))
                publish("this song has no canvas")
                return nil
            }
            var request = URLRequest(url: video); request.timeoutInterval = 45
            let (tmp, resp) = try await URLSession.shared.download(for: request)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw Failure(text: "canvas download rejected") }
            let mime = (http.mimeType ?? "").lowercased()
            guard !mime.contains("html") && !mime.contains("json") else { throw Failure(text: "canvas server returned \(mime) instead of video") }
            let bytes = ((try? FileManager.default.attributesOfItem(atPath: tmp.path))?[.size] as? NSNumber)?.int64Value ?? 0
            guard bytes >= 10_000, bytes <= 100 * 1024 * 1024 else { throw Failure(text: "canvas video has an invalid size") }
            let part = dir.appendingPathComponent(trackid + ".part.mp4")
            try? FileManager.default.removeItem(at: part)
            try FileManager.default.moveItem(at: tmp, to: part)
            guard let size = await ArtworkMotion.orientedSize(part), size.width > 0, size.height > 0 else { throw Failure(text: "canvas file isn't playable") }
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: part)); gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 1200, height: 1920)
            let cg = try gen.copyCGImage(at: CMTime(seconds: 0.1, preferredTimescale: 600), actualTime: nil)
            guard let data = UIImage(cgImage: cg).jpegData(compressionQuality: 0.9) else { throw Failure(text: "preview") }
            try data.write(to: jpg(trackid), options: .atomic)
            try? FileManager.default.removeItem(at: mp4(trackid))
            try FileManager.default.moveItem(at: part, to: mp4(trackid))
            Log.i(.artwork, "spotify canvas cached for \(trackid) (\(Int(size.width))x\(Int(size.height)))")
            publish("canvas ready")
            return cached(trackid: trackid)
        } catch {
            if error is CancellationError { return nil }
            // A provider-wide 5xx used to be retried on every artwork refresh and produced dozens
            // of requests per minute. Pause the service, while leaving cached videos available.
            locked { serviceRetryAfter = Date().addingTimeInterval(60) }
            Log.w(.artwork, "spotify canvas lookup failed: \((error as? Failure)?.text ?? error.localizedDescription)")
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(trackid + ".part.mp4"))
            publish((error as? Failure)?.text ?? "canvas lookup failed")
            return nil
        }
    }

    struct Failure: Error { let text: String }

    // nil = the service answered and this track has no canvas
    private func lookup(_ trackid: String) async throws -> URL? {
        let base = serverurl().trimmingCharacters(in: CharacterSet(charactersIn: "/ \n"))
        guard var baseComponents = URLComponents(string: base), let scheme = baseComponents.scheme?.lowercased(), ["http", "https"].contains(scheme), baseComponents.host != nil else { throw Failure(text: "bad canvas server url") }
        let path = baseComponents.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !path.hasSuffix("api/canvas") {
            let prefix = baseComponents.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            baseComponents.path = "/" + ([prefix, "api/canvas"].filter { !$0.isEmpty }.joined(separator: "/"))
        }
        var comps = baseComponents
        comps.queryItems = [URLQueryItem(name: "trackId", value: trackid)]
        guard let url = comps.url else { throw Failure(text: "bad canvas server url") }
        var req = URLRequest(url: url); req.timeoutInterval = 25
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("furmuse", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw Failure(text: "canvas server answered \(code)") }     // 500 = the service itself failed: not "no canvas"
        guard data.count <= 2 * 1024 * 1024 else { throw Failure(text: "canvas server response was too large") }
        guard let json = try? JSONSerialization.jsonObject(with: data) else { throw Failure(text: "canvas server sent something unreadable") }
        // Known servers return data.canvasesList or data.canvases. Accept either, including an unwrapped response.
        var list: [[String: Any]] = []
        var foundList = false
        func walk(_ v: Any) {
            if let d = v as? [String: Any] {
                for key in ["canvasesList", "canvases"] where d[key] != nil {
                    foundList = true
                    if let l = d[key] as? [[String: Any]] { list.append(contentsOf: l) }
                }
                for x in d.values { walk(x) }
            } else if let a = v as? [Any] { for x in a { walk(x) } }
        }
        walk(json)
        guard foundList else { throw Failure(text: "canvas server response had no canvas list") }
        let wanted = "spotify:track:\(trackid)"
        let exact = list.filter { ($0["trackUri"] as? String) == wanted || ($0["track_uri"] as? String) == wanted }
        let candidates = exact.isEmpty ? list : exact
        guard let s = candidates.compactMap({ ($0["canvasUrl"] as? String) ?? ($0["canvas_url"] as? String) ?? ($0["url"] as? String) }).first,
              let u = URL(string: s), let videoScheme = u.scheme?.lowercased(), ["http", "https"].contains(videoScheme) else { return nil }
        return u
    }

    private static func trackid(_ value: String) -> String {
        if value.hasPrefix("spotify:track:") { return String(value.dropFirst("spotify:track:".count)) }
        if let url = URL(string: value), url.host?.contains("spotify.com") == true, let id = url.pathComponents.last { return id }
        return value
    }

    private func publish(_ value: String) {
        if Thread.isMainThread { status = value }
        else { DispatchQueue.main.async { [weak self] in self?.status = value } }
    }
}

// the one place that decides which animated cover a track gets, for the player screen. priority: the user's own video (handled by
// the caller), then the user's preferred online provider, then the other provider.
enum AnimatedCovers {
    struct Result {
        let video: URL
        let provider: String
        let fellback: Bool
    }

    static func resolve(for t: Track, shown s: Track, settings: Settings, library: LibraryStore) async -> Result? {
        func apple() async -> URL? {
            guard settings.applecovers else { return nil }
            if let c = AppleCovers.shared.cached(artist: s.artist, album: s.album) { return c.video }
            if let c = await AppleCovers.shared.cover(artist: s.artist, album: s.album) { return c.video }
            return AppleCovers.shared.cached(artist: s.artist, album: s.album)?.video
        }
        func canvas() async -> URL? {
            guard settings.spotifycanvas, t.isspotify else { return nil }
            if let c = SpotifyCanvas.shared.cached(trackid: t.id) { return c.video }
            if let c = await SpotifyCanvas.shared.cover(trackid: t.id) { return c.video }
            return SpotifyCanvas.shared.cached(trackid: t.id)?.video
        }
        let preferred = library.animatedcoverorder(t.id) ?? settings.animatedcoverorder
        if preferred == "apple" {
            if let found = await apple() { return Result(video: found, provider: "apple music", fellback: false) }
            if let found = await canvas() { return Result(video: found, provider: "spotify canvas", fellback: true) }
            return nil
        }
        if let found = await canvas() { return Result(video: found, provider: "spotify canvas", fellback: false) }
        if let found = await apple() { return Result(video: found, provider: "apple music", fellback: true) }
        return nil
    }
}
