import Foundation
import AVFoundation
import Combine

// fallback for audio that can't be decoded into the shared graph (hls playlists, or a stream that couldn't be cached).
// speed (0.5-2.0x) and pitch lock still work through avplayer; eq, bass, reverb and pitch shift do not.
// used from the main thread only (engine drives it); the unchecked marker silences the @Sendable observer closures.
final class AVPlayerStreamSource: PlaybackSource, @unchecked Sendable {
    let kind: SourceKind
    private(set) var info: String
    private(set) var duration: Double
    var onEnd: (() -> Void)?
    var onFail: ((String) -> Void)?

    private let url: URL
    private var player: AVPlayer?
    private var itemobs: AnyCancellable?
    private var endobs: NSObjectProtocol?
    private var timeobs: Any?
    private var rate: Float = 1
    private var lastpos = 0.0
    private var ended = false

    init(kind: SourceKind, url: URL, duration: Double, info: String) {
        self.kind = kind; self.url = url; self.duration = duration; self.info = info
    }

    func prepare() async throws {
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 1.5
        let p = AVPlayer(playerItem: item)
        p.automaticallyWaitsToMinimizeStalling = false
        player = p
        itemobs = item.publisher(for: \.status).receive(on: DispatchQueue.main).sink { [weak self] st in
            if st == .failed { self?.onFail?("stream failed to play") }
        }
        endobs = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            guard let self, !self.ended else { return }
            self.ended = true
            self.onEnd?()
        }
        if duration > 0 {
            timeobs = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main) { [weak self] time in
                guard let self, !self.ended, time.seconds.isFinite, time.seconds >= self.duration else { return }
                self.ended = true
                self.lastpos = self.duration
                self.player?.pause()
                self.onEnd?()
            }
        }
    }

    var position: Double {
        guard let p = player else { return lastpos }
        let s = p.currentTime().seconds
        if s.isFinite { lastpos = max(0, s) }
        return duration > 0 ? min(lastpos, duration) : lastpos
    }

    func play(from t: Double) {
        ended = false
        if t > 0 { player?.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) } else { player?.seek(to: .zero) }
        player?.rate = rate
    }
    func resume() { player?.rate = rate }
    func pause() { lastpos = position; player?.pause() }
    func seek(to t: Double) {
        player?.seek(to: CMTime(seconds: min(max(0, t), duration > 0 ? duration : t), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    func stop() {
        itemobs = nil
        if let e = endobs { NotificationCenter.default.removeObserver(e) }
        endobs = nil
        if let o = timeobs { player?.removeTimeObserver(o) }
        timeobs = nil
        player?.pause(); player = nil
    }

    func apply(_ s: Settings, playing: Bool) {
        rate = Float(min(max(s.speed, minspeed), maxspeed))
        player?.volume = Float(s.volume)
        player?.currentItem?.audioTimePitchAlgorithm = s.pitchlock ? .timeDomain : .varispeed
        if playing { player?.rate = rate }
    }
}
