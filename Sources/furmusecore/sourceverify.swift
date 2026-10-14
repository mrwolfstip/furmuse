import Foundation

// "does this YouTube video actually correspond to this Spotify track?" one place, used by the source popup (search) and by the
// playlist import review when the user changes a pick. it reuses the existing matcher (title / artist / length scoring, rejects
// live / remix / sped-up and so on) and the existing stream path (a real, playable stream whose real length is compared).
struct SourceVerdict {
    enum Level { case verified, uncertain, rejected }
    var level: Level
    var reasons: [String]          // human readable, shown to the user
    var score: Double?
    var realduration: Double?

    var summary: String {
        switch level {
        case .verified: return "matches"
        case .uncertain: return reasons.first ?? "might not match"
        case .rejected: return reasons.first ?? "can't be used"
        }
    }
}

enum SourceVerifier {
    // cheap check from the search listing only (no network): used to label candidates while the user is choosing
    static func quick(_ c: YouTubeCandidate, for track: Track) -> (good: Bool, text: String, score: Double?) {
        let r = YouTubeMatcher.score(c, for: track)
        if let s = r.score, s >= YouTubeMatcher.threshold { return (true, "good match", s) }
        return (false, r.reason.isEmpty ? "weak match" : r.reason, r.score)
    }

    // full check before a source is saved
    static func verify(_ c: YouTubeCandidate, for track: Track) async -> SourceVerdict {
        var reasons: [String] = []
        let r = YouTubeMatcher.score(c, for: track)
        if let s = r.score {
            if s < YouTubeMatcher.threshold { reasons.append("weak match with the spotify track") }
        } else {
            reasons.append(r.reason.isEmpty ? "doesn't look like this track" : r.reason)
        }
        var real: Double?
        do {
            real = try await YouTubeResolver().probe(c.id)
        } catch {
            return SourceVerdict(level: .rejected, reasons: [(error as? ResolveError)?.text ?? "youtube won't give audio for this video"], score: r.score, realduration: nil)
        }
        if let d = real, !YouTubeMatcher.durationok(d, track) {
            reasons.append("the audio is \(fmttime(d)) but the track is \(fmttime(track.duration))")
        }
        return SourceVerdict(level: reasons.isEmpty ? .verified : .uncertain, reasons: reasons, score: r.score, realduration: real)
    }
}

// when does choosing a track need the source popup? only when the track would play from YouTube and no source has been confirmed yet.
// local files, downloads, spotify playback and already-confirmed sources never ask.
enum SourcePolicy {
    static func needschoice(_ t: Track, library: LibraryStore, settings: Settings) -> Bool {
        guard settings.askforsource, t.isspotify, !settings.offlineonly else { return false }
        if library.localurl(t.id) != nil { return false }
        if settings.preferdownloads, library.data.downloads[t.id] != nil { return false }
        let pref = library.preferred(t.id)?.rawValue ?? settings.defaultsource
        guard pref == "youtube" || pref == "local" else { return false }     // "local" default still falls back to youtube
        if let m = library.data.mappings[t.id], m.videoid != nil, m.invalid != true, (m.confirmed == true || m.auto == false) { return false }
        return true
    }
}
