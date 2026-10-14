import Foundation
import CryptoKit

final class DownloadManager: ObservableObject {
    static let root: URL = {
        var u = LibraryStore.supportdir.appendingPathComponent("downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        var v = URLResourceValues(); v.isExcludedFromBackup = true
        try? u.setResourceValues(v)
        return u
    }()

    @Published private(set) var active: Set<String> = []
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
        if settings.offlineonly { ToastCenter.shared.show("offline mode is on", route: .downloads); return }
        active.insert(t.id)
        defer { active.remove(t.id) }
        do {
            // Signed YouTube URLs expire quickly. Downloads always request a fresh URL instead of reusing the
            // short-lived stream currently held by the player.
            let src = try await resolver.resolve(t, fresh: true)
            if ["m3u8", "hls"].contains(src.container) { throw ResolveError.unavailable("streaming playlists can't be downloaded") }
            let cfg = URLSessionConfiguration.default
            cfg.allowsCellularAccess = !settings.wifionly
            let (tmp, resp) = try await URLSession(configuration: cfg).download(from: src.url)
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
            library.remember([t])
            let trim = await SilenceTrim.end(of: dest)
            library.mutate { $0.downloads[t.id] = DownloadItem(path: rel, container: src.container, codec: src.codec, bitrate: src.bitrate, bytes: size, date: Date(), title: t.title, artist: t.artist, album: t.album, trimend: trim) }
            await ArtworkLoader.shared.prefetch(s.artworkurl)
        } catch {
            ToastCenter.shared.show("download failed: \((error as? ResolveError)?.text ?? error.localizedDescription)", route: .downloads)
        }
    }

    func remove(_ id: String) {
        if let d = library.data.downloads[id] { try? FileManager.default.removeItem(at: DownloadManager.root.appendingPathComponent(d.path)) }
        library.mutate { $0.downloads[id] = nil }
    }

    var totalbytes: Int64 { library.data.downloads.values.reduce(0) { $0 + $1.bytes } }
}
