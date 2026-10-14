import Foundation
import AVFoundation

let reverbnames = ["small room", "medium room", "large room", "medium hall", "large hall", "plate", "cathedral"]
private let reverbpresets: [AVAudioUnitReverbPreset] = [.smallRoom, .mediumRoom, .largeRoom, .mediumHall, .largeHall, .plate, .cathedral]
private let eqfreqs: [Float] = [60, 230, 910, 3600, 14000]

let minspeed = 0.5
let maxspeed = 2.0

// one engine for every source:
//   source node (file player node or pcm source node) -> time-pitch -> eq -> reverb -> main mixer -> output
// speed, pitch, eq, bass and reverb are applied here, live, without touching the source.
final class SharedAudioGraph {
    let engine = AVAudioEngine()
    private let pitch = AVAudioUnitTimePitch()
    private let eq = AVAudioUnitEQ(numberOfBands: 6)
    private let reverb = AVAudioUnitReverb()
    private var attached: AVAudioNode?
    private var chainformat: AVAudioFormat?
    private var obs: NSObjectProtocol?
    // set by the active source: called after the engine was rebuilt by the system (route change, media reset)
    var onreset: (() -> Void)?

    init() {
        for n in [pitch, eq, reverb] as [AVAudioNode] { engine.attach(n) }
        for (i, b) in eq.bands.enumerated() {
            b.bypass = false
            if i < 5 { b.filterType = .parametric; b.frequency = eqfreqs[i]; b.bandwidth = 1 } else { b.filterType = .lowShelf; b.frequency = 100 }
        }
        obs = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            Log.w(.playback, "audio engine configuration changed, restarting")
            try? self.engine.start()
            self.onreset?()
        }
    }

    deinit { if let o = obs { NotificationCenter.default.removeObserver(o) } }

    // connects a source node. the downstream chain is rewired only when the format changes.
    func attach(_ node: AVAudioNode, format: AVAudioFormat) {
        detach()
        engine.attach(node)
        let wasrunning = engine.isRunning
        if wasrunning { engine.pause() }
        if chainformat?.sampleRate != format.sampleRate || chainformat?.channelCount != format.channelCount {
            engine.connect(pitch, to: eq, format: format)
            engine.connect(eq, to: reverb, format: format)
            engine.connect(reverb, to: engine.mainMixerNode, format: format)
            chainformat = format
        }
        engine.connect(node, to: pitch, format: format)
        attached = node
        if wasrunning { try? engine.start() }
        Log.i(.playback, "graph attached source node \(Int(format.sampleRate))Hz \(format.channelCount)ch")
    }

    func detach() {
        guard let n = attached else { return }
        engine.disconnectNodeOutput(n)
        engine.detach(n)
        attached = nil
        onreset = nil
    }

    func start() throws { if !engine.isRunning { engine.prepare(); try engine.start() } }
    func pauseengine() { if engine.isRunning { engine.pause() } }

    func apply(_ s: Settings) {
        let sp = min(max(s.speed, minspeed), maxspeed)
        pitch.rate = Float(sp)
        // time-pitch changes speed without changing pitch; when pitch lock is off, pitch follows speed (varispeed feel)
        let follow = s.pitchlock ? 0.0 : 1200 * log2(sp)
        pitch.pitch = Float(min(max(follow + Double(s.pitchsemis) * 100, -2400), 2400))
        engine.mainMixerNode.outputVolume = Float(s.volume)
        for i in 0..<5 { eq.bands[i].gain = s.eqon ? Float(s.eq[i]) : 0 }
        eq.bands[5].gain = Float(s.bass)
        let idx = min(max(s.reverbpreset, 0), reverbpresets.count - 1)
        reverb.loadFactoryPreset(reverbpresets[idx])
        reverb.wetDryMix = s.reverbon ? Float(s.reverbmix) : 0
    }
}
