import Foundation
import AVFoundation

// some youtube videos are the song followed by a long stretch of silence (the video can be twice as long as the song). when the
// audio on disk ends in more than `minsilence` seconds of silence, the playable length is cut back to just after the last sound,
// so the player shows the song's real length, the seek bar fits it, and the next song starts when the music ends.
//
// the file itself is never modified: LocalFileSource is told where the audio ends. the scan reads the file backwards in half
// second windows and stops at the first window that has sound, so a normal song costs a single read. results are remembered per
// file (name + size), so each file is scanned once.
enum SilenceTrim {
    static let minsilence = 5.0       // trailing silence longer than this is cut
    static let tail = 1.0             // kept after the last sound, so a fade-out isn't clipped
    static let quiet: Float = 0.003   // samples quieter than this (about -50 dBFS) count as silence
    private static let defaultskey = "wolfified.silence.v1"
    private static let lock = NSLock()

    // where the audio really ends, in seconds, or nil when nothing should be cut (no long silence, or a file that is mostly silent)
    static func end(of url: URL) async -> Double? {
        let key = cachekey(url)
        if let hit = remembered(key) { return hit < 0 ? nil : hit }
        let result = await Task.detached(priority: .utility) { scan(url) }.value
        guard let r = result else { return nil }          // unreadable: not remembered, tried again next time
        remember(key, r ?? -1)
        if let e = r { Log.i(.youtube, "trailing silence found in \(url.lastPathComponent): audio ends at \(fmttime(e))") }
        return r
    }

    // nil = couldn't read the file; .some(nil) = nothing to cut; .some(x) = the audio ends at x seconds
    private static func scan(_ url: URL) -> Double?? {
        guard let f = try? AVAudioFile(forReading: url) else { return nil }
        let sr = f.processingFormat.sampleRate
        let total = f.length
        guard total > 0, sr > 0 else { return nil }
        let window = AVAudioFrameCount(sr * 0.5)
        guard let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: window) else { return nil }
        let duration = Double(total) / sr
        var pos = max(0, total - Int64(window))
        var lastsound: Double?
        while lastsound == nil {
            f.framePosition = pos
            buf.frameLength = 0
            let want = AVAudioFrameCount(min(Int64(window), total - pos))
            do { try f.read(into: buf, frameCount: want) } catch { return nil }
            let n = Int(buf.frameLength)
            if let ch = buf.floatChannelData, n > 0 {
                let chans = Int(buf.format.channelCount)
                var i = n - 1
                found: while i >= 0 {
                    for c in 0..<chans where abs(ch[c][i]) > quiet { lastsound = Double(pos + Int64(i) + 1) / sr; break found }
                    i -= 1
                }
            }
            if lastsound == nil {
                if pos == 0 { break }
                pos = max(0, pos - Int64(window))
            }
        }
        guard let s = lastsound else { return .some(nil) }                    // all silence: leave it alone
        guard duration - s > minsilence, s >= 10 else { return .some(nil) }   // short tail, or almost nothing before the silence
        return .some(min(duration, s + tail))
    }

    private static func cachekey(_ url: URL) -> String {
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        return "\(url.lastPathComponent)#\(size)"
    }
    private static func remembered(_ key: String) -> Double? {
        lock.lock(); defer { lock.unlock() }
        return (UserDefaults.standard.dictionary(forKey: defaultskey) as? [String: Double])?[key]
    }
    private static func remember(_ key: String, _ value: Double) {
        lock.lock(); defer { lock.unlock() }
        var d = (UserDefaults.standard.dictionary(forKey: defaultskey) as? [String: Double]) ?? [:]
        if d.count > 400 { d.removeAll() }       // a cache of facts that are cheap to recompute: never let it grow without bound
        d[key] = value
        UserDefaults.standard.set(d, forKey: defaultskey)
    }

    static func clear() {
        lock.lock(); defer { lock.unlock() }
        UserDefaults.standard.removeObject(forKey: defaultskey)
    }
}
