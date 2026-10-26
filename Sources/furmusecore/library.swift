import Foundation
import UIKit
import AVFoundation

// per-artist overlay data, keyed by the artist name as furmuse shows it. photo is a custom image the user picked (file name in the
// artwork folder); imageurl is a photo found on spotify; checked is the last spotify lookup so misses aren't retried constantly.
struct ArtistInfo: Codable, Equatable {
    var photo: String?
    var imageurl: String?
    var checked: Date?
}

struct LibraryData: Codable {
    var version = 3
    var tracks: [String: Track] = [:]
    var playlists: [LocalPlaylist] = []
    var mappings: [String: Mapping] = [:]
    var overrides: [String: Override] = [:]
    var artistmap: [String: String] = [:]
    var albummap: [String: String] = [:]
    var downloads: [String: DownloadItem] = [:]
    var aliases: [String: String] = [:]
    var sources: [String: SourceChoice] = [:]
    var library: [String: LibraryEntry] = [:]
    var artists: [String: ArtistInfo] = [:]
    var albumart: [String: String] = [:]       // album-group key -> local artwork file
    var albumvideo: [String: String] = [:]     // album-group key -> local animated artwork
    var animatedcoverpriority: [String: String] = [:] // per-song override: canvas or apple
    var romanization: [String: String] = [:]   // per-song override: off, replace, below or current

    init() {}

    private enum Keys: String, CodingKey {
        case version, tracks, playlists, mappings, overrides, artistmap, albummap, downloads, aliases, sources, library, artists, albumart, albumvideo, animatedcoverpriority, romanization
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        tracks = try c.decodeIfPresent([String: Track].self, forKey: .tracks) ?? [:]
        playlists = try c.decodeIfPresent([LocalPlaylist].self, forKey: .playlists) ?? []
        mappings = try c.decodeIfPresent([String: Mapping].self, forKey: .mappings) ?? [:]
        overrides = try c.decodeIfPresent([String: Override].self, forKey: .overrides) ?? [:]
        artistmap = try c.decodeIfPresent([String: String].self, forKey: .artistmap) ?? [:]
        albummap = try c.decodeIfPresent([String: String].self, forKey: .albummap) ?? [:]
        downloads = try c.decodeIfPresent([String: DownloadItem].self, forKey: .downloads) ?? [:]
        aliases = try c.decodeIfPresent([String: String].self, forKey: .aliases) ?? [:]
        sources = try c.decodeIfPresent([String: SourceChoice].self, forKey: .sources) ?? [:]   // added in 0.2.1; older files simply lack it
        artists = try c.decodeIfPresent([String: ArtistInfo].self, forKey: .artists) ?? [:]     // artist photos; older files simply lack it
        albumart = try c.decodeIfPresent([String: String].self, forKey: .albumart) ?? [:]
        albumvideo = try c.decodeIfPresent([String: String].self, forKey: .albumvideo) ?? [:]
        animatedcoverpriority = try c.decodeIfPresent([String: String].self, forKey: .animatedcoverpriority) ?? [:]
        romanization = try c.decodeIfPresent([String: String].self, forKey: .romanization) ?? [:]
        if let l = try c.decodeIfPresent([String: LibraryEntry].self, forKey: .library) {
            library = l
        } else {
            // files from before the library revamp: everything already remembered is kept in the library
            for (id, _) in tracks { library[id] = LibraryEntry(added: Date(timeIntervalSince1970: 0), via: "earlier") }
        }
    }
}

// one album as the library shows it: tracks that share an album name and album artist
struct AlbumGroup: Identifiable {
    let id: String
    let name: String
    let artist: String
    var tracks: [Track]
}

final class LibraryStore: ObservableObject {
    @Published private(set) var data = LibraryData()
    static let supportdir: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("wolfified", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    private let file = LibraryStore.supportdir.appendingPathComponent("library.json")

    init() {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601   // matches save(); dates were being encoded as iso8601 but decoded as numbers
        if let raw = try? Data(contentsOf: file), let d = try? dec.decode(LibraryData.self, from: raw) {
            data = d
        }
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let raw = try? enc.encode(data) { try? raw.write(to: file, options: .atomic) }
    }

    func mutate(_ change: (inout LibraryData) -> Void) {
        var next = data
        change(&next)
        data = next
        save()
    }

    func shown(_ t: Track) -> Track {
        var r = t
        let o = data.overrides[t.id]
        // explicit user text is used exactly as typed; spotify values are only the fallback
        r.title = o?.title ?? t.title
        r.artist = o?.artist ?? data.artistmap[t.artist] ?? t.artist
        r.album = o?.album ?? data.albummap[t.album] ?? t.album
        if let f = o?.artwork { r.artwork = ArtworkStore.url(f).absoluteString }
        else if let key = albumkey(shown: r, original: t), let f = data.albumart[key] { r.artwork = ArtworkStore.url(f).absoluteString }
        return r
    }

    private func albumkey(shown track: Track, original: Track) -> String? {
        let album = track.album.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !album.isEmpty else { return nil }
        let albumArtist: String
        if let raw = original.albumartist, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            albumArtist = data.artistmap[raw] ?? raw
        } else {
            albumArtist = Track.firstname(track.artist)
        }
        return album.lowercased() + "|" + albumArtist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // ---- library membership ---------------------------------------------------------------------------------------
    // data.tracks is "metadata furmuse knows" (queue items, search results); data.library is what is actually in the user's library.
    func inlibrary(_ id: String) -> Bool { data.library[id] != nil }

    // a youtube-only track always plays from its own video. storing that as a confirmed mapping means playback never has to guess
    // (search results, playlist adds and the link import all end up here)
    static func ytmapping(_ t: Track) -> Mapping? {
        guard t.id.hasPrefix(Track.ytprefix) else { return nil }
        let vid = String(t.id.dropFirst(Track.ytprefix.count))
        guard !vid.isEmpty else { return nil }
        return Mapping(videoid: vid, source: "youtube", verified: true, label: nil, auto: false, videotitle: t.title, channel: t.artist,
                       videoduration: t.duration > 0 ? t.duration : nil, trackduration: t.duration, score: nil, matchedat: Date(),
                       confirmed: true, confirmedat: Date(), invalid: nil)
    }

    func addtolibrary(_ t: Track, via: String, played: Bool = false) {
        mutate { d in
            if d.tracks[t.id] == nil { d.tracks[t.id] = t }
            if d.mappings[t.id]?.videoid == nil, let m = LibraryStore.ytmapping(t) { d.mappings[t.id] = m }
            var e = d.library[t.id] ?? LibraryEntry(added: Date(), via: via)
            if played { e.plays += 1; e.lastplayed = Date() }
            d.library[t.id] = e
        }
    }

    func removefromlibrary(_ id: String) { mutate { $0.library[id] = nil } }

    private var likedName: String { "Liked Songs" }
    func isliked(_ id: String) -> Bool {
        data.playlists.first(where: { $0.name.caseInsensitiveCompare(likedName) == .orderedSame })?.trackids.contains(id) == true
    }

    func toggleliked(_ track: Track) {
        mutate { data in
            if data.tracks[track.id] == nil { data.tracks[track.id] = track }
            let index: Int
            if let found = data.playlists.firstIndex(where: { $0.name.caseInsensitiveCompare(likedName) == .orderedSame }) { index = found }
            else { data.playlists.insert(LocalPlaylist(name: likedName), at: 0); index = 0 }
            if let item = data.playlists[index].trackids.firstIndex(of: track.id) { data.playlists[index].trackids.remove(at: item) }
            else { data.playlists[index].trackids.insert(track.id, at: 0) }
        }
    }

    func eraseall() {
        data = LibraryData(); save()
        AppleCovers.shared.clear()
        SpotifyCanvas.shared.clear()
        ArtworkLoader.shared.clear()
        SilenceTrim.clear()
        Log.shared.clear()
        for directory in [ArtworkStore.dir, DownloadManager.root, LibraryStore.localdir, YouTubeSource.cachedir, ArtworkMotion.dir] {
            if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                for file in files { try? FileManager.default.removeItem(at: file) }
            }
        }
    }

    var librarytracks: [Track] { data.library.keys.compactMap { data.tracks[$0] } }

    // The visible song history is deliberately narrower than the metadata cache and imported
    // playlist contents: it contains only tracks that actually started playing in Furmuse.
    var playedtracks: [Track] {
        data.library
            .filter { $0.value.plays > 0 || $0.value.lastplayed != nil }
            .sorted { ($0.value.lastplayed ?? .distantPast) > ($1.value.lastplayed ?? .distantPast) }
            .compactMap { data.tracks[$0.key] }
    }

    // everything in the library, most recently played (or added) first. this is what the artists / albums / songs sections show, so
    // imported playlist tracks appear there before they have ever been played.
    var allsongs: [Track] {
        data.library
            .sorted { ($0.value.lastplayed ?? $0.value.added) > ($1.value.lastplayed ?? $1.value.added) }
            .compactMap { data.tracks[$0.key] }
    }

    // brings every track that sits in a playlist into the library (older imports and manual adds can miss it). returns how many were added.
    @discardableResult
    func syncfromplaylists() -> Int {
        var added = 0
        mutate { d in
            for p in d.playlists {
                for id in p.trackids where d.tracks[id] != nil && d.library[id] == nil {
                    d.library[id] = LibraryEntry(added: Date(), via: "playlist")
                    added += 1
                }
            }
        }
        return added
    }

    // ---- albums ----------------------------------------------------------------------------------------------------
    private func albumartistname(_ t: Track) -> String {
        guard let a = t.albumartist, !a.trimmingCharacters(in: .whitespaces).isEmpty else { return primaryartist(t) }
        return (a.components(separatedBy: ",").first ?? a).trimmingCharacters(in: .whitespaces)
    }

    // nil when the track has no album (e.g. a youtube-only import)
    func albumkey(_ t: Track) -> String? {
        albumkey(shown: shown(t), original: t)
    }

    func albumgroups(_ tracks: [Track]) -> [AlbumGroup] {
        var order: [String] = [], map: [String: AlbumGroup] = [:]
        for t in tracks {
            guard let k = albumkey(t) else { continue }
            if map[k] == nil { map[k] = AlbumGroup(id: k, name: shown(t).album.trimmingCharacters(in: .whitespaces), artist: albumartistname(t), tracks: []); order.append(k) }
            map[k]?.tracks.append(t)
        }
        return order.compactMap { map[$0] }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // a playlist's picture: its own cover, else the cover of its first song with artwork
    func playlistcoverurl(_ p: LocalPlaylist) -> URL? {
        if let f = p.coverfile { return ArtworkStore.url(f) }
        if let u = p.coverurl.flatMap({ URL(string: $0) }) { return u }
        for id in p.trackids { if let t = data.tracks[id], let u = shown(t).artworkurl { return u } }
        return nil
    }

    // the playback source of a track, for display. the spotify track is the identity; this is only its attribute.
    func sourcesummary(_ t: Track, defaultsource: String) -> (kind: String, detail: String, confirmed: Bool) {
        if localurl(t.id) != nil { return ("local file", data.sources[t.id]?.localname ?? "", true) }
        let pref = preferred(t.id)?.rawValue ?? (t.isspotify ? defaultsource : "youtube")
        if pref == "youtube" || !t.isspotify {
            if let m = data.mappings[t.id], let v = m.videoid {
                let conf = m.confirmed == true || m.auto == false
                return ("youtube", m.invalid == true ? "needs a new source" : v, conf && m.invalid != true)
            }
            return ("youtube", "not chosen yet", false)
        }
        return (pref == "local" ? "local file" : pref, "", true)
    }

    // saves a user-confirmed youtube source for a spotify track. the mapping is final until the video stops working.
    func confirmsource(_ t: Track, video: YouTubeCandidate, realduration: Double?, score: Double?, auto: Bool) {
        let m = Mapping(videoid: video.id, source: "youtube", verified: true, label: nil, auto: auto, videotitle: video.title, channel: video.channel,
                        videoduration: realduration ?? video.duration, trackduration: t.duration, score: score, matchedat: Date(),
                        confirmed: true, confirmedat: Date(), invalid: nil)
        mutate { d in
            if d.tracks[t.id] == nil { d.tracks[t.id] = t }
            d.mappings[t.id] = m
            var s = d.sources[t.id] ?? SourceChoice()
            if t.isspotify { s.preferred = SourceKind.youtube.rawValue }   // the confirmed source is what plays
            d.sources[t.id] = s
        }
    }

    // youtube playlist import, after the user confirmed the review screen
    func importyoutube(id: String, name: String, items: [(track: Track, video: YouTubeCandidate, realduration: Double?, score: Double?)]) {
        mutate { d in
            var ids: [String] = []
            for it in items {
                let t = it.track
                if d.tracks[t.id] == nil { d.tracks[t.id] = t }
                d.mappings[t.id] = Mapping(videoid: it.video.id, source: "youtube", verified: true, label: nil, auto: true, videotitle: it.video.title,
                                           channel: it.video.channel, videoduration: it.realduration ?? it.video.duration, trackduration: t.duration,
                                           score: it.score, matchedat: Date(), confirmed: true, confirmedat: Date(), invalid: nil)
                var s = d.sources[t.id] ?? SourceChoice()
                if t.isspotify { s.preferred = SourceKind.youtube.rawValue }
                d.sources[t.id] = s
                if d.library[t.id] == nil { d.library[t.id] = LibraryEntry(added: Date(), via: "youtube import") }
                ids.append(t.id) // preserve the upstream order, including intentional duplicates
            }
            if let i = d.playlists.firstIndex(where: { $0.youtubeid == id }) {
                // A refresh mirrors the reviewed upstream playlist, including removals and order.
                d.playlists[i].trackids = ids
            } else {
                var p = LocalPlaylist(name: name, trackids: ids)
                p.youtubeid = id
                d.playlists.append(p)
            }
        }
    }

    // a song that only exists as a file on this phone (unreleased, a demo...). nothing is created if the audio can't be read.
    @discardableResult
    func addlocaltrack(title: String, artist: String, album: String, cover: UIImage?, audio: URL) -> Track? {
        let id = Track.localprefix + UUID().uuidString
        guard attachlocal(id, from: audio) else { return nil }
        var length = 0.0
        if let u = localurl(id), let f = try? AVAudioFile(forReading: u), f.processingFormat.sampleRate > 0 { length = Double(f.length) / f.processingFormat.sampleRate }
        let t = Track(id: id, title: title, artist: artist, album: album, artwork: nil, duration: length, albumartist: artist)
        addtolibrary(t, via: "added")
        if let cover = cover {
            if let key = albumkey(t) { setalbumartwork(key, image: cover) }
            else { setartwork(id, image: cover) }
        }
        return t
    }

    func remember(_ ts: [Track]) {
        mutate { d in for t in ts where d.tracks[t.id] == nil { d.tracks[t.id] = t } }
    }


    // ---- local audio (attached to a spotify track id; sends nothing to spotify)
    static let localdir: URL = {
        var u = supportdir.appendingPathComponent("localaudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        var v = URLResourceValues(); v.isExcludedFromBackup = true
        try? u.setResourceValues(v)
        return u
    }()

    func localurl(_ id: String) -> URL? {
        guard let f = data.sources[id]?.localaudio else { return nil }
        let u = LibraryStore.localdir.appendingPathComponent(f)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    // copies the picked file into the app (user-provided local audio, never spotify audio) and attaches it to the track
    @discardableResult
    func attachlocal(_ id: String, from url: URL) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let ext = url.pathExtension.isEmpty ? "audio" : url.pathExtension.lowercased()
        let name = UUID().uuidString + "." + ext
        let dest = LibraryStore.localdir.appendingPathComponent(name)
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            _ = try AVAudioFile(forReading: dest)   // reject files that can't be decoded
        } catch {
            try? FileManager.default.removeItem(at: dest)
            Log.e(.local, "local import failed for \(id): \(error.localizedDescription)")
            return false
        }
        let old = data.sources[id]?.localaudio
        mutate { d in var s = d.sources[id] ?? SourceChoice(); s.localaudio = name; s.localname = url.lastPathComponent; d.sources[id] = s }
        if let o = old { try? FileManager.default.removeItem(at: LibraryStore.localdir.appendingPathComponent(o)) }
        Log.i(.local, "attached local audio to \(id): \(url.lastPathComponent)")
        return true
    }

    // File-provider URLs can block while iCloud downloads or a large file is copied. Keep that
    // work away from the main actor, but apply the source overlay and library.json mutation back
    // on it so observers see one consistent change.
    @MainActor
    @discardableResult
    func attachlocalasync(_ id: String, from url: URL) async -> Bool {
        let copied: (name: String, original: String)? = await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let ext = url.pathExtension.isEmpty ? "audio" : url.pathExtension.lowercased()
            let name = UUID().uuidString + "." + ext
            let dest = LibraryStore.localdir.appendingPathComponent(name)
            do {
                try Task.checkCancellation()
                try FileManager.default.copyItem(at: url, to: dest)
                try Task.checkCancellation()
                _ = try AVAudioFile(forReading: dest)
                return (name, url.lastPathComponent)
            } catch {
                try? FileManager.default.removeItem(at: dest)
                if !(error is CancellationError) { Log.e(.local, "local import failed for \(id): \(error.localizedDescription)") }
                return nil
            }
        }.value
        guard let copied else { return false }
        let old = data.sources[id]?.localaudio
        mutate { d in
            var s = d.sources[id] ?? SourceChoice()
            s.localaudio = copied.name
            s.localname = copied.original
            d.sources[id] = s
        }
        if let old { try? FileManager.default.removeItem(at: LibraryStore.localdir.appendingPathComponent(old)) }
        Log.i(.local, "attached local audio to \(id): \(copied.original)")
        return true
    }

    @MainActor
    func addlocaltrackasync(title: String, artist: String, album: String, cover: UIImage?, audio: URL) async -> Track? {
        let id = Track.localprefix + UUID().uuidString
        guard await attachlocalasync(id, from: audio) else { return nil }
        var length = 0.0
        if let u = localurl(id), let f = try? AVAudioFile(forReading: u), f.processingFormat.sampleRate > 0 {
            length = Double(f.length) / f.processingFormat.sampleRate
        }
        let track = Track(id: id, title: title, artist: artist, album: album, artwork: nil, duration: length, albumartist: artist)
        addtolibrary(track, via: "added")
        if let cover {
            if let key = albumkey(track) { setalbumartwork(key, image: cover) }
            else { setartwork(id, image: cover) }
        }
        return track
    }

    func detachlocal(_ id: String) {
        let old = data.sources[id]?.localaudio
        mutate { d in
            guard var s = d.sources[id] else { return }
            s.localaudio = nil; s.localname = nil
            d.sources[id] = s == SourceChoice() ? nil : s
        }
        if let o = old { try? FileManager.default.removeItem(at: LibraryStore.localdir.appendingPathComponent(o)) }
        Log.i(.local, "detached local audio from \(id)")
    }

    func setpreferred(_ id: String, _ kind: SourceKind?) {
        mutate { d in
            var s = d.sources[id] ?? SourceChoice()
            s.preferred = kind?.rawValue
            d.sources[id] = s == SourceChoice() ? nil : s
        }
    }
    // the global audio source was switched: every per-track spotify / youtube choice is dropped so those tracks follow the new
    // default (a spotify track plays from spotify, a youtube-sourced track from youtube, and back again). local files the user
    // attached are a different kind of choice and are kept; so are youtube mappings, so switching back reuses the confirmed video.
    func followglobalsource() {
        guard data.sources.values.contains(where: { $0.preferred == SourceKind.spotify.rawValue || $0.preferred == SourceKind.youtube.rawValue }) else { return }
        mutate { d in
            for (id, s) in d.sources {
                guard s.preferred == SourceKind.spotify.rawValue || s.preferred == SourceKind.youtube.rawValue else { continue }
                var n = s
                n.preferred = nil
                d.sources[id] = n == SourceChoice() ? nil : n
            }
        }
        Log.i(.source, "global audio source changed: per-track spotify/youtube choices now follow the default")
    }
    func preferred(_ id: String) -> SourceKind? { data.sources[id]?.preferred.flatMap { SourceKind(rawValue: $0) } }

    func setmapping(_ id: String, _ m: Mapping?) { mutate { $0.mappings[id] = m } }
    func animatedcoverorder(_ id: String) -> String? { data.animatedcoverpriority[id] }
    func setanimatedcoverorder(_ id: String, _ order: String?) {
        mutate { data in
            if let order { data.animatedcoverpriority[id] = order }
            else { data.animatedcoverpriority[id] = nil }
        }
    }
    func romanization(_ id: String) -> String? { data.romanization[id] }
    func setromanization(_ id: String, _ mode: String?) {
        mutate { data in
            if let mode { data.romanization[id] = mode }
            else { data.romanization[id] = nil }
        }
    }
    func setoverride(_ id: String, _ o: Override?) {
        mutate { d in
            if let o = o, o != Override() { d.overrides[id] = o } else { d.overrides[id] = nil }
        }
    }

    // edits display fields only. keeps artwork, mappings and the spotify identity untouched.
    func editmeta(_ id: String, title: String?, artist: String?, album: String?) {
        mutate { d in
            var o = d.overrides[id] ?? Override()
            o.title = title; o.artist = artist; o.album = album
            d.overrides[id] = o == Override() ? nil : o
        }
    }

    func setartwork(_ id: String, image: UIImage) {
        guard let name = ArtworkStore.save(image) else { ToastCenter.shared.show("couldn't save that image"); return }
        let old = data.overrides[id]?.artwork, oldvideo = data.overrides[id]?.video
        mutate { d in var o = d.overrides[id] ?? Override(); o.artwork = name; o.video = nil; d.overrides[id] = o }
        ArtworkStore.remove(old)
        ArtworkStore.remove(oldvideo)
    }

    func clearartwork(_ id: String) {
        let old = data.overrides[id]?.artwork
        let oldvideo = data.overrides[id]?.video
        mutate { d in
            guard var o = d.overrides[id] else { return }
            o.artwork = nil
            o.video = nil
            d.overrides[id] = o == Override() ? nil : o
        }
        ArtworkStore.remove(old)
        ArtworkStore.remove(oldvideo)
    }

    func setalbumartwork(_ key: String, image: UIImage) {
        guard let name = ArtworkStore.save(image) else { ToastCenter.shared.show("couldn't save that image"); return }
        let old = data.albumart[key]
        mutate { $0.albumart[key] = name }
        ArtworkStore.remove(old)
    }

    func clearalbumartwork(_ key: String) {
        let old = data.albumart[key]
        mutate { $0.albumart[key] = nil }
        ArtworkStore.remove(old)
    }

    func setalbumvideo(_ key: String, source: URL) {
        guard let saved = ArtworkStore.saveVideo(source) else { ToastCenter.shared.show("couldn't use that video"); return }
        let old = data.albumvideo[key]
        mutate { $0.albumvideo[key] = saved.video }
        ArtworkStore.remove(saved.preview)
        ArtworkStore.remove(old)
    }

    func clearalbumvideo(_ key: String) {
        let old = data.albumvideo[key]
        mutate { $0.albumvideo[key] = nil }
        ArtworkStore.remove(old)
    }

    // Animated artwork is independent of the square cover. The video is used by the player and lock screen,
    // while the original Spotify/custom still remains the regular cover and reduced-motion fallback.
    func setvideoartwork(_ id: String, source: URL) {
        guard let saved = ArtworkStore.saveVideo(source) else { ToastCenter.shared.show("couldn't use that video"); return }
        let oldvid = data.overrides[id]?.video
        mutate { d in var o = d.overrides[id] ?? Override(); o.video = saved.video; d.overrides[id] = o }
        ArtworkStore.remove(saved.preview)
        ArtworkStore.remove(oldvid)
    }

    func videourl(_ id: String) -> URL? {
        let explicit = data.overrides[id]
        let f: String?
        if let video = explicit?.video { f = video }
        else if explicit?.artwork != nil { f = nil }
        else if let track = data.tracks[id], let key = albumkey(track) { f = data.albumvideo[key] }
        else { f = nil }
        guard let f else { return nil }
        let u = ArtworkStore.url(f)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    // ---- artists ---------------------------------------------------------------------------------------------------
    // the first credited artist of a track, as shown (display renames applied). this is the key for artist pages and photos.
    func primaryartist(_ t: Track) -> String {
        let a = shown(t).artist
        if a == t.artist { return t.firstartist }      // not renamed: the credited list knows names that contain a comma
        return (a.components(separatedBy: ",").first ?? a).trimmingCharacters(in: .whitespaces)
    }

    // the artist's own photo: the custom one the user picked wins, then the one found on spotify. nil if neither exists.
    func artistphoto(_ name: String) -> URL? {
        guard let i = data.artists[name] else { return nil }
        if let f = i.photo {
            let u = ArtworkStore.url(f)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return i.imageurl.flatMap { URL(string: $0) }
    }

    // what to draw for an artist: their photo, or the cover of their most recently played song until a photo exists
    func artistimageurl(_ name: String) -> URL? {
        if let u = artistphoto(name) { return u }
        return allsongs.first { primaryartist($0) == name }.flatMap { shown($0).artworkurl }
    }

    func setartistphoto(_ name: String, image: UIImage) {
        guard let file = ArtworkStore.save(image) else { ToastCenter.shared.show("couldn't save that image"); return }
        let old = data.artists[name]?.photo
        mutate { d in var i = d.artists[name] ?? ArtistInfo(); i.photo = file; d.artists[name] = i }
        ArtworkStore.remove(old)
    }

    func clearartistphoto(_ name: String) {
        let old = data.artists[name]?.photo
        mutate { d in
            guard var i = d.artists[name] else { return }
            i.photo = nil
            d.artists[name] = i == ArtistInfo() ? nil : i
        }
        ArtworkStore.remove(old)
    }

    // looks the artist up on spotify and remembers the photo url. a miss is remembered for a week; a failure (offline, not signed in,
    // rate limited) is not, so it is simply tried again next time.
    @MainActor
    func fetchartistimage(_ name: String, force: Bool = false) async {
        if !force {
            let i = data.artists[name]
            if i?.imageurl != nil { return }
            if let c = i?.checked, Date().timeIntervalSince(c) < 7 * 86400 { return }
        }
        guard !name.isEmpty else { return }
        do {
            let url = try await Services.shared.api.artistimage(name)      // nil = spotify has no artist by that name
            mutate { d in
                var i = d.artists[name] ?? ArtistInfo()
                if let url = url { i.imageurl = url }
                i.checked = Date()
                d.artists[name] = i
            }
        } catch { /* offline, signed out or rate limited: not remembered, so it is tried again next time */ }
    }

    @discardableResult
    func addplaylist(_ name: String) -> String {
        let p = LocalPlaylist(name: name)
        mutate { $0.playlists.append(p) }
        return p.id
    }

    func playlist(_ id: String) -> LocalPlaylist? { data.playlists.first { $0.id == id } }

    func renameplaylist(_ id: String, _ name: String) {
        mutate { d in if let i = d.playlists.firstIndex(where: { $0.id == id }) { d.playlists[i].name = name } }
    }

    func setplaylistcover(_ id: String, image: UIImage?) {
        let old = playlist(id)?.coverfile
        let name = image.flatMap { ArtworkStore.save($0) }
        if image != nil && name == nil { ToastCenter.shared.show("couldn't save that image"); return }
        mutate { d in if let i = d.playlists.firstIndex(where: { $0.id == id }) { d.playlists[i].coverfile = name } }
        ArtworkStore.remove(old)
    }

    func removeplaylist(_ id: String) {
        let old = playlist(id)?.coverfile
        mutate { $0.playlists.removeAll { $0.id == id } }
        ArtworkStore.remove(old)
    }

    func remove(trackat offsets: IndexSet, from playlistid: String) {
        mutate { d in if let i = d.playlists.firstIndex(where: { $0.id == playlistid }) { d.playlists[i].trackids.remove(atOffsets: offsets) } }
    }

    func move(from: IndexSet, to: Int, in playlistid: String) {
        mutate { d in if let i = d.playlists.firstIndex(where: { $0.id == playlistid }) { d.playlists[i].trackids.move(fromOffsets: from, toOffset: to) } }
    }

    // imports (or refreshes) a spotify playlist while keeping its spotify id; local cover/name edits survive a refresh
    func importspotify(id: String, name: String, coverurl: String?, tracks: [Track]) {
        mutate { d in
            for t in tracks where d.tracks[t.id] == nil { d.tracks[t.id] = t }
            for t in tracks where d.library[t.id] == nil { d.library[t.id] = LibraryEntry(added: Date(), via: "spotify import") }
            if let i = d.playlists.firstIndex(where: { $0.spotifyid == id }) {
                d.playlists[i].trackids = tracks.map { $0.id }
                if d.playlists[i].coverurl == nil { d.playlists[i].coverurl = coverurl }
            } else {
                d.playlists.append(LocalPlaylist(name: name, trackids: tracks.map { $0.id }, spotifyid: id, coverfile: nil, coverurl: coverurl))
            }
        }
    }

    func add(_ t: Track, to playlistid: String) {
        mutate { d in
            d.tracks[t.id] = d.tracks[t.id] ?? t
            if d.mappings[t.id]?.videoid == nil, let m = LibraryStore.ytmapping(t) { d.mappings[t.id] = m }
            if d.library[t.id] == nil { d.library[t.id] = LibraryEntry(added: Date(), via: "playlist") }
            guard let i = d.playlists.firstIndex(where: { $0.id == playlistid }) else { return }
            if !d.playlists[i].trackids.contains(t.id) { d.playlists[i].trackids.append(t.id) }
        }
    }

    func tracks(of p: LocalPlaylist) -> [Track] { p.trackids.compactMap { data.tracks[$0] } }

    func exportdata() -> URL? {
        guard let raw = backupdata() else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("furmuse-library-\(UUID().uuidString).json")
        do {
            try raw.write(to: url, options: .atomic)
            Log.i(.local, "library backup prepared (\(raw.count) bytes)")
            return url
        } catch {
            Log.e(.local, "library backup write failed: \(error.localizedDescription)")
            return nil
        }
    }

    func backupdata() -> Data? {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        var copy = data
        copy.downloads = [:]
        do { return try enc.encode(copy) }
        catch { Log.e(.local, "library backup encode failed: \(error.localizedDescription)"); return nil }
    }

    @discardableResult
    func importdata(_ url: URL) -> Int {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let raw = try? Data(contentsOf: url), let inc = try? dec.decode(LibraryData.self, from: raw) else { return -1 }
        var added = 0
        mutate { d in
            for (k, v) in inc.tracks where d.tracks[k] == nil { d.tracks[k] = v; added += 1 }
            for (k, v) in inc.library where d.library[k] == nil { d.library[k] = v }
            for (k, v) in inc.mappings where d.mappings[k] == nil { d.mappings[k] = v; added += 1 }
            for (k, v) in inc.overrides where d.overrides[k] == nil {
                var safe = v
                if !ArtworkStore.validFilename(safe.artwork) { safe.artwork = nil }
                if !ArtworkStore.validFilename(safe.video) { safe.video = nil }
                d.overrides[k] = safe; added += 1
            }
            for (k, v) in inc.artistmap where d.artistmap[k] == nil { d.artistmap[k] = v; added += 1 }
            for (k, v) in inc.albummap where d.albummap[k] == nil { d.albummap[k] = v; added += 1 }
            for (k, v) in inc.aliases where d.aliases[k] == nil { d.aliases[k] = v; added += 1 }
            for (k, v) in inc.artists where d.artists[k] == nil {
                var safe = v
                if !ArtworkStore.validFilename(safe.photo) { safe.photo = nil }   // photo files themselves aren't exported
                if safe != ArtistInfo() { d.artists[k] = safe; added += 1 }
            }
            for (k, v) in inc.albumart where d.albumart[k] == nil {
                if ArtworkStore.validFilename(v) { d.albumart[k] = v; added += 1 }
            }
            for (k, v) in inc.albumvideo where d.albumvideo[k] == nil {
                if ArtworkStore.validFilename(v) { d.albumvideo[k] = v; added += 1 }
            }
            for (k, v) in inc.romanization where d.romanization[k] == nil && ["off", "replace", "below", "current"].contains(v) { d.romanization[k] = v; added += 1 }
            for (k, v) in inc.sources where d.sources[k] == nil { var s = v; s.localaudio = nil; s.localname = nil; if s != SourceChoice() { d.sources[k] = s; added += 1 } }   // audio files themselves aren't exported
            for p in inc.playlists {
                if let i = d.playlists.firstIndex(where: { $0.id == p.id }) {
                    for t in p.trackids where !d.playlists[i].trackids.contains(t) { d.playlists[i].trackids.append(t); added += 1 }
                } else {
                    var safe = p
                    if !ArtworkStore.validFilename(safe.coverfile) { safe.coverfile = nil }
                    d.playlists.append(safe); added += 1
                }
            }
        }
        return added
    }
}
