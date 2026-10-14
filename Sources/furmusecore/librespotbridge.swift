import Foundation

// everything librespot-specific that the rest of furmuse is allowed to know.
// the rust side (rust/wolfified-librespot-ffi) exposes a small C api; this protocol is its swift shape,
// so the spotify audio implementation can be replaced without touching the player, ui, queue or last.fm.

enum BridgeEvent {
    case loading
    case playing(positionms: Int)
    case paused(positionms: Int)
    case seeked(positionms: Int)
    case endoftrack
    case unavailable          // spotify refused / couldn't load this track
    case stopped
    case sink(String)         // "running" | "closed" | "temporarily_closed"
    case disconnected(String)
    case error(String)
    case log(level: Int, text: String)   // librespot's own info/warn/error lines (AP chosen, auth stages)
    // ---- spotify connect ----
    case remoteseek(positionms: Int)     // a spotify client seeked this device (the pcm buffer was already flushed)
    case volume(Int)                     // a spotify client set the volume, 0...65535
    case trackchanged(ConnectTrack)      // metadata of the track spotify put on this device
    case connectactive(Bool)             // this device is / is no longer the active connect device
    case controller(String)              // name of the spotify client controlling this device
}

struct ConnectTrack: Equatable {
    let id: String, title: String, artist: String, album: String, cover: String, durationms: Int
    var track: Track {
        Track(id: id, title: title, artist: artist, album: album, artwork: cover.isEmpty ? nil : cover, duration: Double(durationms) / 1000)
    }
    static func parse(_ json: String) -> ConnectTrack? {
        guard let d = json.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let id = o["id"] as? String, id.count == 22 else { return nil }   // episodes / local files have no 22 char track id
        return ConnectTrack(id: id, title: o["title"] as? String ?? "", artist: o["artist"] as? String ?? "", album: o["album"] as? String ?? "",
                            cover: o["cover"] as? String ?? "", durationms: o["duration_ms"] as? Int ?? 0)
    }
}

enum ConnectCommand: Int32 { case play = 1, pause, next, previous, seek, volume, disconnect }

// why wolf_start failed, kept distinct so the ui never calls an authentication problem a network problem
enum LibrespotFailure: String {
    case noToken = "no token", runtime = "runtime", rejected = "authentication rejected", network = "network",
         apRejected = "all access points refused the login", other = "other"
}
struct LibrespotStartError: Error {
    let code: Int
    var failure: LibrespotFailure {
        switch code {
        case -1: return .noToken
        case -2: return .runtime
        case -3: return .rejected
        case -4: return .network
        case -6: return .apRejected
        default: return .other
        }
    }
}

protocol LibrespotBridge: AnyObject, Sendable {
    var available: Bool { get }
    var unavailablereason: String { get }
    var connected: Bool { get }
    // blocking: call off the main thread. the token is used for the login and never logged.
    // devicename is what spotify's device picker shows; deviceid must be stable per install; devicetype 2 tablet / 3 smartphone;
    // volume is 0...65535 (what spotify shows until a client changes it)
    func start(token: String, clientid: String, devicename: String, deviceid: String, devicetype: Int, volume: Int, events: @escaping (BridgeEvent) -> Void) throws
    func shutdown()
    // transport / volume through spotify connect, so the state other spotify clients show stays correct
    @discardableResult func connect(_ cmd: ConnectCommand, arg: Int) -> Bool
    @discardableResult func connectload(trackid: String, positionms: Int) -> Bool
    var connectactive: Bool { get }
    func load(trackid: String, play: Bool, positionms: Int)
    func play()
    func pause()
    func seek(ms: Int)
    // realtime-safe, never blocks: copies up to `frames` interleaved stereo float32 frames, returns frames copied
    func read(_ out: UnsafeMutablePointer<Float>, frames: Int) -> Int
    func flush()
    var buffered: Int { get }       // frames waiting
    var underruns: UInt64 { get }   // render calls that wanted more than was buffered
}

final class UnavailableBridge: LibrespotBridge {
    let available = false
    let unavailablereason = "the librespot library isn't linked into this build (see rust/README.md)"
    let connected = false
    func start(token: String, clientid: String, devicename: String, deviceid: String, devicetype: Int, volume: Int, events: @escaping (BridgeEvent) -> Void) throws { throw SourceError.unavailable(unavailablereason) }
    func shutdown() {}
    func connect(_ cmd: ConnectCommand, arg: Int) -> Bool { false }
    func connectload(trackid: String, positionms: Int) -> Bool { false }
    var connectactive: Bool { false }
    func load(trackid: String, play: Bool, positionms: Int) {}
    func play() {}
    func pause() {}
    func seek(ms: Int) {}
    func read(_ out: UnsafeMutablePointer<Float>, frames: Int) -> Int { 0 }
    func flush() {}
    var buffered: Int { 0 }
    var underruns: UInt64 { 0 }
}

func makelibrespotbridge() -> LibrespotBridge {
    #if canImport(CWolfLibrespot)
    return CLibrespotBridge()
    #else
    return UnavailableBridge()
    #endif
}

#if canImport(CWolfLibrespot)
import CWolfLibrespot

// binds the C header in rust/wolfified-librespot-ffi/include/wolf_librespot.h (module CWolfLibrespot, shipped in the xcframework).
// NOT COMPILED OR RUN: written against the header, which was written against the librespot 0.8.0 source.
final class CLibrespotBridge: LibrespotBridge, @unchecked Sendable {
    let available = true
    let unavailablereason = ""
    private var handle: OpaquePointer?
    private var sink: ((BridgeEvent) -> Void)?
    private let lock = NSLock()

    var connected: Bool { lock.lock(); defer { lock.unlock() }; return handle != nil }

    func start(token: String, clientid: String, devicename: String, deviceid: String, devicetype: Int, volume: Int, events: @escaping (BridgeEvent) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        if handle != nil { return }
        sink = events
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        var err: Int32 = 0
        let vol = UInt16(min(max(volume, 0), 65535))
        let h: OpaquePointer? = token.withCString { t in
          clientid.withCString { cid in
            devicename.withCString { d in
              deviceid.withCString { did in
                wolf_start(t, cid, d, did, Int32(devicetype), vol, { ctx, kind, a, b, text in
                    guard let ctx = ctx else { return }
                    let me = Unmanaged<CLibrespotBridge>.fromOpaque(ctx).takeUnretainedValue()
                    me.dispatch(kind, a, b, text.map { String(cString: $0) } ?? "")
                }, ctx, &err)
              }
            }
          }
        }
        guard let h = h else {
            throw LibrespotStartError(code: Int(err))
        }
        handle = h
    }

    private func dispatch(_ kind: Int32, _ a: Int64, _ b: Int64, _ text: String) {
        let e: BridgeEvent
        switch kind {
        case 1: e = .loading
        case 2: e = .playing(positionms: Int(a))
        case 3: e = .paused(positionms: Int(a))
        case 4: e = .endoftrack
        case 5: e = .unavailable
        case 6: e = b == 1 ? .remoteseek(positionms: Int(a)) : .seeked(positionms: Int(a))
        case 7: e = .stopped
        case 8: e = .sink(text)
        case 9: e = .disconnected(text)
        case 10: e = .log(level: Int(a), text: text)
        case 11: e = .volume(Int(a))
        case 12:
            guard let t = ConnectTrack.parse(text) else { return }
            e = .trackchanged(t)
        case 13: e = .connectactive(a == 1)
        case 14: e = .controller(text)
        default: e = .error(text)
        }
        DispatchQueue.main.async { self.sink?(e) }
    }

    func shutdown() {
        lock.lock(); let h = handle; handle = nil; lock.unlock()
        if let h = h { wolf_stop(h) }
    }
    func load(trackid: String, play: Bool, positionms: Int) {
        guard let h = handle else { return }
        trackid.withCString { _ = wolf_load(h, $0, play, UInt32(max(0, positionms))) }
    }
    var connectactive: Bool { handle.map { wolf_connect_active($0) } ?? false }
    @discardableResult func connect(_ cmd: ConnectCommand, arg: Int) -> Bool {
        guard let h = handle else { return false }
        return wolf_connect_cmd(h, cmd.rawValue, Int64(arg)) == 0
    }
    @discardableResult func connectload(trackid: String, positionms: Int) -> Bool {
        guard let h = handle else { return false }
        return trackid.withCString { wolf_connect_load(h, $0, UInt32(max(0, positionms))) == 0 }
    }
    func play() { if let h = handle { wolf_play(h) } }
    func pause() { if let h = handle { wolf_pause(h) } }
    func seek(ms: Int) { if let h = handle { wolf_seek(h, UInt32(max(0, ms))) } }
    func read(_ out: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        guard let h = handle else { return 0 }
        return Int(wolf_pcm_read(h, out, frames))
    }
    func flush() { if let h = handle { wolf_pcm_flush(h) } }
    var buffered: Int { handle.map { Int(wolf_pcm_buffered($0)) } ?? 0 }
    var underruns: UInt64 { handle.map { wolf_pcm_underruns($0) } ?? 0 }
}
#endif
