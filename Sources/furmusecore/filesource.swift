import Foundation
import AVFoundation

// plays any file avaudiofile can decode (imported local audio, downloads, cached youtube audio)
// through the shared graph. position is track time: the player node sits upstream of the time-pitch unit.
final class LocalFileSource: PlaybackSource {
    let kind: SourceKind
    private(set) var info: String
    private(set) var duration = 0.0
    var onEnd: (() -> Void)?
    var onFail: ((String) -> Void)?

    private let url: URL
    private let graph: SharedAudioGraph
    private let node = AVAudioPlayerNode()
    private var file: AVAudioFile?
    private var startsec = 0.0
    private var heldpos = 0.0
    private var gen = 0
    private var wantsplay = false

    // where the music really ends when the file carries trailing silence (see silencetrim.swift). nil = play the whole file.
    private let endlimit: Double?

    init(kind: SourceKind, url: URL, graph: SharedAudioGraph, info: String, endlimit: Double? = nil) {
        self.kind = kind; self.url = url; self.graph = graph; self.info = info; self.endlimit = endlimit
    }

    func prepare() async throws {
        do {
            let f = try AVAudioFile(forReading: url)
            file = f
            duration = Double(f.length) / f.processingFormat.sampleRate
            if let e = endlimit, e > 1, e < duration { duration = e }        // the silent tail is not part of the song
            graph.attach(node, format: f.processingFormat)
            graph.onreset = { [weak self] in self?.recover() }
            try graph.start()
        } catch {
            throw SourceError.failed("couldn't open audio file: \(error.localizedDescription)")
        }
    }

    private func recover() {
        let p = position, w = wantsplay
        schedule(from: p)
        if w { node.play() }
    }

    var position: Double {
        if node.isPlaying, let nt = node.lastRenderTime, let pt = node.playerTime(forNodeTime: nt), pt.sampleTime >= 0 {
            return min(duration, startsec + Double(pt.sampleTime) / pt.sampleRate)
        }
        return heldpos
    }

    private func schedule(from sec: Double) {
        guard let f = file else { return }
        gen += 1
        let g = gen
        node.stop()
        let sr = f.processingFormat.sampleRate
        let start = AVAudioFramePosition(min(max(sec, 0), duration) * sr)
        startsec = Double(start) / sr
        heldpos = startsec
        let endframe = min(f.length, AVAudioFramePosition((duration * sr).rounded()))
        let frames = AVAudioFrameCount(max(endframe - start, 0))
        guard frames > 0 else { DispatchQueue.main.async { [weak self] in self?.onEnd?() }; return }
        node.scheduleSegment(f, startingFrame: start, frameCount: frames, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, self.gen == g, self.wantsplay else { return }
                self.onEnd?()
            }
        }
    }

    func play(from sec: Double) {
        wantsplay = true
        try? graph.start()
        schedule(from: sec)
        node.play()
    }

    func resume() {
        wantsplay = true
        try? graph.start()
        if !node.isPlaying { schedule(from: heldpos); node.play() }
    }

    func pause() { heldpos = position; wantsplay = false; gen += 1; node.pause() }

    func stop() {
        wantsplay = false; gen += 1
        node.stop()
        graph.detach()
    }

    func seek(to sec: Double) {
        let target = min(max(0, sec), duration)
        if wantsplay { schedule(from: target); node.play() } else { gen += 1; node.stop(); startsec = target; heldpos = target }
    }
}
