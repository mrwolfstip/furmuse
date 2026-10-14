import Foundation

// central diagnostics log. never called with secrets; every line is also passed through redact().
// writes happen on a private serial queue, so it is safe (and cheap) to call from anywhere except
// the realtime audio render callback, which must never log (it only bumps counters that are logged later).
enum LogCategory: String {
    case lifecycle, auth, spotify, connect, librespot, webplayback, pcm, source, playback, speed, effects
    case youtube, local, lastfm, playlist, artwork, lyrics, error
}

final class Log {
    static let shared = Log()
    private let q = DispatchQueue(label: "furmuse.log", qos: .utility)
    private let file: URL
    private let old: URL
    private let maxbytes = 512 * 1024
    private var recent: [String] = []
    private let stamp: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f
    }()

    private init() {
        let dir = LibraryStore.supportdir.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("furmuse.log")
        old = dir.appendingPathComponent("furmuse.1.log")
    }

    static func i(_ c: LogCategory, _ m: @autoclosure () -> String) { shared.write("I", c, m()) }
    static func w(_ c: LogCategory, _ m: @autoclosure () -> String) { shared.write("W", c, m()) }
    static func e(_ c: LogCategory, _ m: @autoclosure () -> String) { shared.write("E", c, m()) }

    private func write(_ level: String, _ c: LogCategory, _ msg: String) {
        let text = Log.redact(msg)
        let now = Date()
        q.async {
            let line = "\(self.stamp.string(from: now)) \(level) [\(c.rawValue)] \(text)"
            self.recent.append(line)
            if self.recent.count > 400 { self.recent.removeFirst(self.recent.count - 400) }
            #if DEBUG
            print(line)
            #endif
            self.append(line + "\n")
        }
    }

    private func append(_ s: String) {
        guard let data = s.data(using: .utf8) else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: file.path) { fm.createFile(atPath: file.path, contents: nil) }
        if let size = (try? fm.attributesOfItem(atPath: file.path))?[.size] as? NSNumber, size.intValue > maxbytes {
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: file, to: old)
            fm.createFile(atPath: file.path, contents: nil)
        }
        guard let h = try? FileHandle(forWritingTo: file) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: data)
    }

    // strips things that look like credentials, in case one slips into a message
    static func redact(_ s: String) -> String {
        var r = s
        let rules: [(String, String)] = [
            ("(?i)(access_token|refresh_token|token|code|sk|api_sig|secret|password|authorization)([\"'=: ]+)[A-Za-z0-9._~+/\\-]{8,}", "$1$2<redacted>"),
            ("(?i)bearer\\s+[A-Za-z0-9._~+/\\-]{8,}", "bearer <redacted>")
        ]
        for (p, t) in rules { r = r.replacingOccurrences(of: p, with: t, options: .regularExpression) }
        return r
    }

    func tail(_ n: Int = 200, completion: @escaping ([String]) -> Void) {
        q.async { let t = Array(self.recent.suffix(n)); DispatchQueue.main.async { completion(t) } }
    }

    // flushes pending writes, then returns a url that can be shared
    func exportfile(completion: @escaping (URL?) -> Void) {
        q.async {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("furmuse-log.txt")
            var out = Data()
            if let o = try? Data(contentsOf: self.old) { out.append(o) }
            if let c = try? Data(contentsOf: self.file) { out.append(c) }
            let ok = (try? out.write(to: tmp, options: .atomic)) != nil
            DispatchQueue.main.async { completion(ok ? tmp : nil) }
        }
    }

    func clear() {
        q.async {
            try? FileManager.default.removeItem(at: self.file)
            try? FileManager.default.removeItem(at: self.old)
            self.recent.removeAll()
        }
    }
}
