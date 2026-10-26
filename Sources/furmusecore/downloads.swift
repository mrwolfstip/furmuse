import Foundation
import CryptoKit
import AVFoundation

final class DownloadManager: ObservableObject {
    static let root: URL = {
        var u = LibraryStore.supportdir.appendingPathComponent("downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        var v = URLResourceValues(); v.isExcludedFromBackup = true
        try? u.setResourceValues(v)
        return u
    }()

    @Published private(set) var active: Set<String> = []
    @Published private(set) var progress: [String: Double] = [:]
    private let settings: Settings
    private let library: LibraryStore
    private let resolver: ResolverManager

    init(settings: Settings, library: LibraryStore, resolver: ResolverManager) {
        self.settings = settings
        self.library = library
        self.resolver = resolver
    }

    private func clean(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let r = s.components(separatedBy: bad).joined(separator: "_").trimmingCharacters(in: .whitespaces)
        return r.isEmpty ? "unknown" : String(r.prefix(80))
    }

    private func stableSuffix(_ id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    func has(_ t: Track) -> Bool { library.data.downloads[t.id] != nil }

    @MainActor
    func download(_ t: Track) async {
        guard !active.contains(t.id), !has(t) else { return }
        if library.localurl(t.id) != nil || t.id.hasPrefix(Track.localprefix) {
            ToastCenter.shared.show("this song is already stored on this phone", route: .downloads)
            return
        }
        if settings.offlineonly { ToastCenter.shared.show("offline mode is on", route: .downloads); return }
        active.insert(t.id)
        progress[t.id] = 0
        defer { active.remove(t.id); progress[t.id] = nil }
        do {
            // Signed YouTube URLs expire quickly. Downloads always request a fresh URL instead of reusing the
            // short-lived stream currently held by the player.
            let src = try await resolver.resolve(t, fresh: true)
            if ["m3u8", "hls"].contains(src.container) { throw ResolveError.unavailable("streaming playlists can't be downloaded") }
            let cfg = URLSessionConfiguration.default
            cfg.allowsCellularAccess = !settings.wifionly
            cfg.waitsForConnectivity = true
            let resume = DownloadManager.root.appendingPathComponent(".\(stableSuffix(t.id)).resume")
            let staging = DownloadManager.root.appendingPathComponent(".\(stableSuffix(t.id)).partial")
            let transfer = DownloadTransfer(configuration: cfg, staging: staging, resume: resume) { [weak self] value in
                Task { @MainActor in self?.progress[t.id] = value }
            }
            let (tmp, resp) = try await transfer.start(url: src.url)
            guard (resp as? HTTPURLResponse)?.statusCode ?? 200 < 300 else { throw ResolveError.unavailable("download rejected") }
            if let type = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.lowercased(), type.contains("text/html") {
                throw ResolveError.unavailable("the source returned a web page instead of audio")
            }
            let s = library.shown(t)
            // Metadata is not a unique identity (deluxe albums and compilations often contain the
            // same artist/album/title). Keep paths readable, but suffix them with the stable track id.
            let rel = "\(clean(s.artist))/\(clean(s.album))/\(clean(s.title))–\(stableSuffix(t.id)).\(src.container == "hls" ? "m4a" : src.container)"
            let dest = DownloadManager.root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            let size = ((try? FileManager.default.attributesOfItem(atPath: dest.path))?[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 1024 else { try? FileManager.default.removeItem(at: dest); throw ResolveError.unavailable("the downloaded audio was empty") }
            guard (try? AVAudioFile(forReading: dest)) != nil else {
                try? FileManager.default.removeItem(at: dest)
                throw ResolveError.unavailable("the downloaded file wasn't valid audio")
            }
            library.remember([t])
            let trim = await SilenceTrim.end(of: dest)
            library.mutate { $0.downloads[t.id] = DownloadItem(path: rel, container: src.container, codec: src.codec, bitrate: src.bitrate, bytes: size, date: Date(), title: t.title, artist: t.artist, album: t.album, trimend: trim) }
            await ArtworkLoader.shared.prefetch(s.artworkurl)
            let source = t.id.hasPrefix(Track.ytprefix) ? "youtube" : "a matched youtube source"
            ToastCenter.shared.show("downloaded from \(source)", route: .downloads)
            Log.i(.youtube, "download complete for \(t.id) via \(source), \(size) bytes")
        } catch {
            Log.e(.youtube, "download failed for \(t.id): \(error.localizedDescription)")
            ToastCenter.shared.show("download failed: \((error as? ResolveError)?.text ?? error.localizedDescription)", route: .downloads)
        }
    }

    func remove(_ id: String) {
        if let d = library.data.downloads[id] { try? FileManager.default.removeItem(at: DownloadManager.root.appendingPathComponent(d.path)) }
        library.mutate { $0.downloads[id] = nil }
    }

    var totalbytes: Int64 { library.data.downloads.values.reduce(0) { $0 + $1.bytes } }
}

// URLSession's resume data is kept in Application Support beside the downloads. It contains no
// credentials, and is deleted after a successful transfer. The delegate moves the temporary file
// before URLSession invalidates its location.
private final class DownloadTransfer: NSObject, URLSessionDownloadDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let staging: URL
    private let resume: URL
    private let report: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var response: URLResponse?
    private var finished = false
    private var session: URLSession?

    init(configuration: URLSessionConfiguration, staging: URL, resume: URL, report: @escaping @Sendable (Double) -> Void) {
        self.configuration = configuration; self.staging = staging; self.resume = resume; self.report = report
    }

    func start(url: URL) async throws -> (URL, URLResponse) {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                let task: URLSessionDownloadTask
                if let data = try? Data(contentsOf: resume), !data.isEmpty { task = session.downloadTask(withResumeData: data) }
                else { task = session.downloadTask(with: url) }
                task.resume()
            }
        }, onCancel: { [weak self] in self?.session?.invalidateAndCancel() })
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        report(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            try? FileManager.default.removeItem(at: staging)
            try FileManager.default.moveItem(at: location, to: staging)
            response = downloadTask.response
            try? FileManager.default.removeItem(at: resume)
            finished = true
            if let response { continuation?.resume(returning: (staging, response)); continuation = nil }
        } catch {
            continuation?.resume(throwing: error); continuation = nil
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { session.finishTasksAndInvalidate() }
        guard !finished else { return }
        if let data = (error as NSError?)?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data { try? data.write(to: resume, options: .atomic) }
        continuation?.resume(throwing: error ?? ResolveError.unavailable("the download stopped")); continuation = nil
    }
}
