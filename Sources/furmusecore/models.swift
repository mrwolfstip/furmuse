import Foundation
import Combine

struct Track: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var artist: String
    var album: String
    var artwork: String?
    var duration: Double
    // Canonical service metadata. These are deliberately separate from Library overrides:
    // display edits must never change what is submitted to Last.fm.
    var tracknumber: Int? = nil
    var albumartist: String? = nil
    var musicbrainzid: String? = nil
    // every credited artist as spotify lists them (the joined `artist` string can't be split safely: "Tyler, The Creator").
    // nil for tracks that arrived from a connect event or an old library file; firstartist then falls back to splitting.
    var artists: [String]? = nil
    var albumid: String? = nil
    var artistids: [String]? = nil

    // the first credited artist. this is the only artist last.fm is ever sent, and the one the artist page opens.
    var firstartist: String {
        if let a = artists?.first, !a.trimmingCharacters(in: .whitespaces).isEmpty { return a.trimmingCharacters(in: .whitespaces) }
        return Track.firstname(artist)
    }
    var firstalbumartist: String? {
        guard let a = albumartist, !a.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        if let first = artists?.first, a.hasPrefix(first) { return first }
        return Track.firstname(a)
    }
    static func firstname(_ s: String) -> String {
        (s.components(separatedBy: ",").first ?? s).trimmingCharacters(in: .whitespaces)
    }

    // spotify is the canonical identity. the only tracks without a spotify id are YouTube-only imports (no spotify match was found);
    // their id is "yt_<videoid>" and they always play from that video.
    static let ytprefix = "yt_"
    // songs added by hand from a file on this phone (unreleased tracks, demos). they always play from that file.
    static let localprefix = "local_"
    var islocal: Bool { id.hasPrefix(Track.localprefix) }
    var isspotify: Bool { !id.hasPrefix(Track.ytprefix) && !islocal }
    var uri: String { isspotify ? "spotify:track:" + id : "" }
    var weburl: URL? {
        if islocal { return nil }
        return isspotify ? URL(string: "https://open.spotify.com/track/" + id) : URL(string: "https://www.youtube.com/watch?v=" + id.dropFirst(Track.ytprefix.count))
    }
    var artworkurl: URL? { artwork.flatMap { URL(string: $0) } }
}

// audio source mapping. independent of spotify identity, display metadata and artwork.
struct Mapping: Codable, Equatable {
    var videoid: String?
    var source: String = "youtube"
    var verified = false
    var label: String?
    // below: what we knew when the match was made, so a stored automatic match can be re-checked
    var auto: Bool?            // true = found by the resolver, false = chosen by the user, nil = legacy
    var videotitle: String?
    var channel: String?
    var videoduration: Double?
    var trackduration: Double?
    var score: Double?
    var matchedat: Date?
    // the user confirmed this video as the source (in the source popup or the playlist import review). a confirmed source is reused
    // as-is; it is only re-searched if the video stops working (invalid).
    var confirmed: Bool?
    var confirmedat: Date?
    var invalid: Bool?
}

// a track the user has in their Furmuse library. the track itself (spotify metadata) lives in LibraryData.tracks, its playback source
// in mappings / sources: the spotify track stays the identity and the source is just an attribute of it.
struct LibraryEntry: Codable, Equatable {
    var added: Date
    var via: String            // played, search, spotify import, youtube import, saved, earlier
    var lastplayed: Date?
    var plays = 0
}

// furmuse display metadata + artwork. never touches the spotify id or the audio mapping.
struct Override: Codable, Equatable {
    var title: String?
    var artist: String?
    var album: String?
    var artwork: String?   // file name inside the artwork folder (for video artwork this is the first-frame preview)
    var video: String?     // animated artwork: video file name inside the artwork folder, kept locally
}

// per-track audio source choice. local overlay only: it never touches the spotify identity.
// localaudio is a file name inside the localaudio folder; preferred is a SourceKind raw value, nil = follow the global default.
struct SourceChoice: Codable, Equatable {
    var localaudio: String?
    var localname: String?     // original file name, for display
    var preferred: String?
}

struct DownloadItem: Codable, Equatable {
    var path: String
    var container: String
    var codec: String
    var bitrate: Int?
    var bytes: Int64
    var date: Date
    var title: String?     // display metadata at download time, for offline use
    var artist: String?
    var album: String?
    var trimend: Double? = nil   // where the audio ends when the file has a long silent tail (the tail is skipped on playback)
}

struct LocalPlaylist: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name: String
    var trackids: [String] = []
    var spotifyid: String?      // set for imported spotify playlists; never changed by local edits
    var coverfile: String?      // custom cover (file name inside the artwork folder)
    var coverurl: String?       // remote cover, e.g. the spotify playlist image
    var youtubeid: String?      // set for imported youtube playlists
}

enum PlaybackEvent {
    case started(Track)
    case repeated(Track)
    case paused(Track, Double)
    case resumed(Track, Double)
    case seeked(Track, Double, Double)
    case skipped(Track, Double)
    case ended(Track, Double)
    case stopped(Track, Double)
    case failed(Track)
}

final class EventBus {
    static let shared = EventBus()
    let subject = PassthroughSubject<PlaybackEvent, Never>()
    func send(_ e: PlaybackEvent) { DispatchQueue.main.async { self.subject.send(e) } }
}

enum Route: String, Identifiable {
    case spotify, lastfm, source, mapping, devices, downloads
    var id: String { rawValue }
}

struct Toast: Identifiable {
    let id = UUID()
    let text: String
    let route: Route?
}

final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()
    @Published var current: Toast?
    @Published var route: Route?
    var enabled = true
    private var last: (String, Date) = ("", .distantPast)

    func show(_ text: String, route: Route? = nil) {
        DispatchQueue.main.async {
            guard self.enabled else { return }
            if self.last.0 == text, Date().timeIntervalSince(self.last.1) < 8 { return }
            self.last = (text, Date())
            let t = Toast(text: text, route: route)
            self.current = t
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                if self.current?.id == t.id { self.current = nil }
            }
        }
    }
}

func fmttime(_ s: Double) -> String {
    guard s.isFinite, s >= 0 else { return "0:00" }
    let t = Int(s)
    return String(format: "%d:%02d", t / 60, t % 60)
}
