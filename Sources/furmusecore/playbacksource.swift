import Foundation

// where the audio being heard actually comes from. the player never needs to know more than this.
enum SourceKind: String, Codable, CaseIterable {
    case spotify, local, youtube
    var label: String {
        switch self {
        case .spotify: return "spotify"
        case .local: return "local file"
        case .youtube: return "youtube"
        }
    }
}

enum SourceError: Error {
    case unavailable(String)
    case failed(String)
    var text: String {
        switch self {
        case .unavailable(let s), .failed(let s): return s
        }
    }
}

// every source reports position in TRACK time (seconds of the song), never wall-clock time.
// at 2x, ten real seconds advance position by about twenty. sources that render through the shared
// graph get this for free because they sit upstream of the time-pitch unit.
protocol PlaybackSource: AnyObject {
    var kind: SourceKind { get }
    var info: String { get }
    var duration: Double { get }
    var position: Double { get }
    var onEnd: (() -> Void)? { get set }
    var onFail: ((String) -> Void)? { get set }

    func prepare() async throws
    func play(from trackTime: Double)
    func resume()
    func pause()
    func seek(to trackTime: Double)
    func stop()
    // only sources that don't render through the shared graph need this (the avplayer fallback)
    func apply(_ s: Settings, playing: Bool)
}

extension PlaybackSource {
    func apply(_ s: Settings, playing: Bool) {}
}
