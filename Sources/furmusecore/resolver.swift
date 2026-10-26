import Foundation
#if canImport(YouTubeKit)
import YouTubeKit
#endif

struct ResolvedSource {
    var url: URL
    var container: String
    var codec: String
    var bitrate: Int?
    var videovariants: [URL] = []
    var expires: Date?
    var isfile = false
    var origin = ""
    var match: Mapping?   // set when the resolver itself found the source; stored by ResolverManager
}

enum ResolveError: Error {
    case unavailable(String), nomatch, unplayable(String), rejected(String)
    var text: String {
        switch self {
        case .unavailable(let s): return s
        case .nomatch: return "no audio source found"
        case .unplayable(let s): return s
        case .rejected(let s): return s
        }
    }
}

protocol AudioResolver {
    var id: String { get }
    var name: String { get }
    var available: Bool { get }
    func resolve(_ track: Track, mapping: Mapping?) async throws -> ResolvedSource
}

struct YouTubeResolver: AudioResolver {
    let id = "youtube"
    let name = "youtubekit"
    var available: Bool {
        #if canImport(YouTubeKit)
        return true
        #else
        return false
        #endif
    }

    #if canImport(YouTubeKit)
    // the single stream path, used for manual ids and automatic candidates alike
    private func stream(_ v: String) async throws -> ResolvedSource {
        let streams = try await YouTube(videoID: v).streams
        guard let s = streams.filterAudioOnly().filter({ $0.fileExtension == .m4a }).highestAudioBitrateStream() else {
            throw ResolveError.unplayable("no m4a audio stream (webm/opus can't play in avplayer)")
        }
        return ResolvedSource(url: s.url, container: "m4a", codec: "aac", bitrate: nil, expires: Date().addingTimeInterval(3600), origin: "youtube:" + v)
    }

    private func queries(_ t: Track) -> [String] { YouTubeSearch.queries(for: t) }

    private func automatch(_ track: Track) async throws -> ResolvedSource {
        let pool = await YouTubeSearch.candidates(for: track, limit: 30)
        let ranked = YouTubeMatcher.rank(pool, for: track)
        if pool.isEmpty { throw ResolveError.rejected("youtube search returned nothing (offline or blocked)") }
        var lastwhy = ranked.why
        // Stream extraction can fail for an otherwise excellent candidate when YouTube
        // rotates a player response, so try more than the first three ranked results.
        for (c, score) in ranked.ok.prefix(8) {
            do {
                let src = try await stream(c.id)
                // AVFoundation occasionally reports an fMP4 audio stream as roughly twice
                // its real length. The search duration is still useful corroboration, so a
                // clearly broken container reading must not reject an otherwise tight match.
                let real = await YouTubeSearch.streamduration(src.url)
                let listingMatches = c.duration.map { YouTubeMatcher.durationok($0, track) } ?? false
                if let r = real, !YouTubeMatcher.durationok(r, track), !listingMatches {
                    lastwhy = "\"\(c.title)\": stream is \(fmttime(r)) but the track is \(fmttime(track.duration))"
                    continue
                }
                var out = src
                out.match = Mapping(videoid: c.id, source: "youtube", verified: true, label: nil, auto: true, videotitle: c.title, channel: c.channel,
                                    videoduration: listingMatches ? c.duration : (real ?? c.duration), trackduration: track.duration, score: score, matchedat: Date())
                return out
            } catch { lastwhy = "\"\(c.title)\": \((error as? ResolveError)?.text ?? "couldn't load stream")" }
        }
        throw ResolveError.rejected("no trustworthy youtube match for \"\(track.title)\" (\(pool.count) checked; \(lastwhy.isEmpty ? "none matched" : lastwhy))")
    }
    #endif

    // does this video give us playable audio, and how long is it really? used to verify a source before it is saved.
    // returns nil duration when the length couldn't be read; throws when there is no playable stream at all.
    func probe(_ videoid: String) async throws -> Double? {
        #if canImport(YouTubeKit)
        let s = try await stream(videoid)
        return await YouTubeSearch.streamduration(s.url)
        #else
        throw ResolveError.unavailable("youtubekit isn't added to the project (see readme)")
        #endif
    }

    func resolve(_ track: Track, mapping: Mapping?) async throws -> ResolvedSource {
        #if canImport(YouTubeKit)
        if let m = mapping, let v = m.videoid {
            if m.confirmed == true, m.invalid != true {
                // confirmed by the user: reuse it without searching again. only if the video itself stopped working is it given up on.
                do {
                    var s = try await stream(v)
                    s.origin = "youtube:" + v
                    return s
                } catch {
                    ToastCenter.shared.show("the chosen youtube source for \"\(track.title)\" stopped working, looking for another", route: .mapping)
                    var bad = m; bad.invalid = true; bad.confirmed = false
                    let id = track.id, mm = bad
                    Task { @MainActor in Services.shared.library.setmapping(id, mm) }
                    return try await automatch(track)
                }
            }
            if m.auto == false {
                // chosen by the user: always honour it
                var s = try await stream(v)
                if track.duration > 0, let real = await YouTubeSearch.streamduration(s.url), !YouTubeMatcher.durationok(real, track) {
                    ToastCenter.shared.show("duration mismatch: source is \(fmttime(real)), track is \(fmttime(track.duration))", route: .mapping)
                }
                s.origin = "youtube:" + v
                return s
            }
            // automatic or legacy mapping: only keep it while it still checks out
            let unchanged = m.trackduration.map { abs($0 - track.duration) <= 3 } ?? false
            if let s = try? await stream(v) {
                if m.auto == true, m.verified, unchanged, m.videoduration != nil { return s }
                let real = await YouTubeSearch.streamduration(s.url)
                if real == nil || YouTubeMatcher.durationok(real!, track) {
                    var out = s
                    var nm = m
                    nm.auto = m.auto ?? true; nm.verified = true; nm.trackduration = track.duration; nm.videoduration = real ?? m.videoduration
                    out.match = nm
                    return out
                }
                ToastCenter.shared.show("stored source for \"\(track.title)\" has the wrong length, searching again", route: .mapping)
            }
        }
        return try await automatch(track)
        #else
        throw ResolveError.unavailable("youtubekit isn't added to the project (see readme)")
        #endif
    }
}

struct EndpointResolver: AudioResolver {
    let id = "endpoint"
    let name = "custom endpoint"
    let base: String
    var available: Bool { URL(string: base)?.scheme?.hasPrefix("http") == true }

    func resolve(_ track: Track, mapping: Mapping?) async throws -> ResolvedSource {
        guard var c = URLComponents(string: base), available else { throw ResolveError.unavailable("custom endpoint isn't set") }
        var items = c.queryItems ?? []
        items += [.init(name: "id", value: track.id), .init(name: "title", value: track.title), .init(name: "artist", value: track.artist),
                  .init(name: "album", value: track.album), .init(name: "duration", value: String(Int(track.duration)))]
        if let v = mapping?.videoid { items.append(.init(name: "videoid", value: v)) }
        c.queryItems = items
        var req = URLRequest(url: c.url!)
        req.timeoutInterval = 20
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let s = j["url"] as? String, let u = URL(string: s) else { throw ResolveError.unavailable("custom endpoint didn't answer") }
        let exp = (j["expires"] as? Double).map { Date(timeIntervalSince1970: $0) }
        let variants = (j["video"] as? [String] ?? []).compactMap { URL(string: $0) }
        return ResolvedSource(url: u, container: (j["container"] as? String ?? u.pathExtension).lowercased(), codec: (j["codec"] as? String ?? "unknown").lowercased(),
                              bitrate: j["bitrate"] as? Int, videovariants: variants, expires: exp, origin: "endpoint")
    }
}

// resolve() runs off the main thread, so the cache is lock-protected; library writes hop to the main actor.
final class ResolverManager: ObservableObject, @unchecked Sendable {
    private let settings: Settings
    private let library: LibraryStore
    private var cache: [String: ResolvedSource] = [:]
    private let cachelock = NSLock()
    private let flights = ResolverFlights()
    private func cached(_ id: String) -> ResolvedSource? { cachelock.lock(); defer { cachelock.unlock() }; return cache[id] }
    private func store(_ id: String, _ s: ResolvedSource?) { cachelock.lock(); cache[id] = s; cachelock.unlock() }

    init(settings: Settings, library: LibraryStore) {
        self.settings = settings
        self.library = library
    }

    var youtubeavailable: Bool { YouTubeResolver().available }

    func resolvers() -> [AudioResolver] {
        let yt = YouTubeResolver()
        let ep = EndpointResolver(base: settings.endpointurl)
        switch settings.sourceorder {
        case "endpoint": return [ep]
        case "endpointfirst": return [ep, yt]
        default:
            let all: [AudioResolver] = [yt, ep]
            return all.filter { $0.available || $0.id == "youtube" }
        }
    }

    func resolve(_ track: Track, fresh: Bool = false) async throws -> ResolvedSource {
        try Task.checkCancellation()
        if !fresh, let c = cached(track.id), (c.expires ?? .distantFuture) > Date().addingTimeInterval(60) { return c }
        return try await flights.value(key: fresh ? track.id + ":fresh" : track.id) { [self] in
            try Task.checkCancellation()
            if !fresh, let c = cached(track.id), (c.expires ?? .distantFuture) > Date().addingTimeInterval(60) { return c }
            return try await resolveUncoalesced(track)
        }
    }

    private func resolveUncoalesced(_ track: Track) async throws -> ResolvedSource {
        let mapping = library.data.mappings[track.id]
        var lasterr: ResolveError = .nomatch
        for r in resolvers() {
            try Task.checkCancellation()
            do {
                var s = try await r.resolve(track, mapping: mapping)
                s.origin = s.origin.isEmpty ? r.id : s.origin
                store(track.id, s)
                if let hint = s.match {
                    let id = track.id
                    Task { @MainActor [self] in self.library.setmapping(id, hint) }
                } else if mapping?.verified != true {
                    var m = mapping ?? Mapping()
                    m.source = r.id
                    if s.origin.hasPrefix("youtube:") { m.videoid = String(s.origin.dropFirst(8)) }
                    m.verified = true
                    let id = track.id, mm = m
                    Task { @MainActor [self] in self.library.setmapping(id, mm) }
                }
                return s
            } catch let e as ResolveError { lasterr = e } catch { lasterr = .unavailable("\(r.name) failed") }
        }
        throw lasterr
    }

    func forget(_ id: String) { store(id, nil) }

    // Playback requests are disposable: a rapid skip must stop the old network lookup rather than
    // letting its coalesced task finish and race the new source. Downloads use their own request and
    // will simply start a new flight if one was cancelled here.
    func cancel(_ id: String) {
        Task { await flights.cancel(id: id) }
        Log.i(.source, "cancelled resolver work for \(id)")
    }
}

private actor ResolverFlights {
    private var active: [String: Task<ResolvedSource, Error>] = [:]

    func value(key: String, operation: @escaping @Sendable () async throws -> ResolvedSource) async throws -> ResolvedSource {
        try Task.checkCancellation()
        if let task = active[key] { return try await task.value }
        let task = Task { try await operation() }
        active[key] = task
        defer { active[key] = nil }
        return try await task.value
    }

    func cancel(id: String) {
        for key in active.keys where key == id || key == id + ":fresh" {
            active.removeValue(forKey: key)?.cancel()
        }
    }
}
