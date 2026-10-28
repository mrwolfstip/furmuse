import SwiftUI
import UIKit
import ImageIO
import CryptoKit
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers

// custom artwork files live in Application Support/furmuse/artwork (never in the spotify identity).
// remote artwork is cached on disk in Application Support/furmuse/artcache so it also shows offline.
enum ArtworkStore {
    static let dir: URL = {
        let u = LibraryStore.supportdir.appendingPathComponent("artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    static func validFilename(_ file: String?) -> Bool {
        guard let file = file, !file.isEmpty else { return file == nil }
        return file == (file as NSString).lastPathComponent && file != "." && file != ".."
    }

    // Persisted/imported names are treated strictly as leaf names. This keeps a crafted library
    // import from escaping the artwork directory during reads or cleanup.
    static func url(_ file: String) -> URL { dir.appendingPathComponent((file as NSString).lastPathComponent) }

    // downsamples to 1200px (aspect ratio kept, never stretched). PNG stays PNG so transparency survives; everything else is jpeg.
    // every change gets a fresh file name, so every change gets a new url.
    static func save(_ image: UIImage) -> String? {
        let maxside: CGFloat = 1200
        let scale = min(1, maxside / max(image.size.width, image.size.height))
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        let out = UIGraphicsImageRenderer(size: size, format: fmt).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        let hasalpha: Bool = {
            guard let a = image.cgImage?.alphaInfo else { return false }
            return a != .none && a != .noneSkipFirst && a != .noneSkipLast
        }()
        let data: Data? = hasalpha ? out.pngData() : out.jpegData(compressionQuality: 0.85)
        guard let d = data else { return nil }
        let name = UUID().uuidString + (hasalpha ? ".png" : ".jpg")
        do { try d.write(to: url(name), options: .atomic); return name } catch { return nil }
    }

    // copies an uploaded video into the artwork folder (it is never uploaded anywhere) and renders its first frame as the
    // static preview. the generator applies the track's transform, so portrait videos keep their orientation.
    static func saveVideo(_ source: URL) -> (video: String, preview: String)? {
        let ext = source.pathExtension.isEmpty ? "mp4" : source.pathExtension.lowercased()
        let vname = UUID().uuidString + "." + ext
        let dest = url(vname)
        do { try FileManager.default.copyItem(at: source, to: dest) } catch { return nil }
        let asset = AVURLAsset(url: dest)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1200, height: 1200)
        guard let cg = try? gen.copyCGImage(at: .zero, actualTime: nil), let pname = save(UIImage(cgImage: cg)) else {
            try? FileManager.default.removeItem(at: dest)
            return nil
        }
        return (vname, pname)
    }

    static func remove(_ file: String?) {
        guard let f = file else { return }
        try? FileManager.default.removeItem(at: url(f))
    }
}

final class ArtworkLoader {
    static let shared = ArtworkLoader()
    private let mem = NSCache<NSString, UIImage>()
    private let cachedir: URL

    private init() {
        mem.countLimit = 300
        cachedir = LibraryStore.supportdir.appendingPathComponent("artcache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cachedir, withIntermediateDirectories: true)
        var u = cachedir
        var v = URLResourceValues(); v.isExcludedFromBackup = true
        try? u.setResourceValues(v)
    }

    private func diskname(_ url: URL) -> URL {
        let h = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return cachedir.appendingPathComponent(h.prefix(40) + ".img")
    }

    private static func downsample(_ file: URL, _ maxpixel: CGFloat) -> UIImage? {
        guard let src = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxpixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    func image(_ url: URL, maxpixel: CGFloat) async -> UIImage? {
        let key = "\(url.absoluteString)@\(Int(maxpixel))" as NSString
        if let hit = mem.object(forKey: key) { return hit }
        let img: UIImage? = await Task.detached(priority: .utility) { [self] () -> UIImage? in
            if url.isFileURL { return ArtworkLoader.downsample(url, maxpixel) }
            let f = diskname(url)
            if !FileManager.default.fileExists(atPath: f.path) {
                var req = URLRequest(url: url)
                req.timeoutInterval = 15
                guard let (data, resp) = try? await URLSession.shared.data(for: req),
                      (resp as? HTTPURLResponse).map({ $0.statusCode < 300 }) ?? true,
                      UIImage(data: data) != nil else { return nil }
                try? data.write(to: f, options: .atomic)
            }
            return ArtworkLoader.downsample(f, maxpixel)
        }.value
        if let i = img { mem.setObject(i, forKey: key) }
        return img
    }

    // warms the disk cache so artwork is available offline later
    func prefetch(_ url: URL?) async { if let u = url { _ = await image(u, maxpixel: 300) } }

    func clear() {
        mem.removeAllObjects()
        for file in (try? FileManager.default.contentsOfDirectory(at: cachedir, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

struct ArtworkView: View {
    let url: URL?
    var size: CGFloat = 48
    var corner: CGFloat = 6
    var symbol = "music.note"
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.gray.opacity(0.18)
            if let i = image {
                Image(uiImage: i).resizable().scaledToFill()
            } else {
                Image(systemName: symbol).font(.system(size: size * 0.35)).foregroundColor(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .task(id: url) {
            image = nil
            guard let u = url else { return }
            image = await ArtworkLoader.shared.image(u, maxpixel: size * UIScreen.main.scale)
        }
    }
}

// artwork for a track as furmuse shows it (custom override wins, spotify is the fallback)
struct TrackArt: View {
    let track: Track
    var size: CGFloat = 48
    var corner: CGFloat = 6
    @EnvironmentObject var library: LibraryStore

    var body: some View { ArtworkView(url: library.shown(track).artworkurl, size: size, corner: corner) }
}

// Album artwork used by both the Library album list and album pages. A custom album video wins;
// otherwise the matching Apple Music cover is loaded and cached. The still cover remains visible
// while the video is loading and whenever motion is disabled.
struct AlbumArtworkView: View {
    let group: AlbumGroup
    var size: CGFloat? = 48
    var corner: CGFloat = 6

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: Settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var apple = AppleCovers.shared
    @State private var appleVideo: URL?

    private var stillURL: URL? {
        group.tracks.lazy.compactMap { library.shown($0).artworkurl }.first
    }

    private var customVideo: URL? { library.albumvideourl(group.id) }
    private var video: URL? {
        guard !reduceMotion else { return nil }
        return customVideo ?? appleVideo
    }

    private var lookupKey: String {
        "\(group.id)|\(customVideo?.absoluteString ?? "")|\(settings.applecovers)|\(settings.applecoversurl)|\(apple.revision)"
    }

    var body: some View {
        ZStack {
            if let size {
                ArtworkView(url: stillURL, size: size, corner: corner)
            } else {
                GeometryReader { proxy in
                    ArtworkView(url: stillURL, size: max(proxy.size.width, proxy.size.height), corner: 0)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
            if let video {
                LoopingVideoView(url: video)
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .task(id: lookupKey) {
            appleVideo = nil
            guard customVideo == nil, settings.applecovers else { return }
            if let cached = apple.cached(artist: group.artist, album: group.name) {
                appleVideo = cached.video
                return
            }
            appleVideo = await apple.cover(artist: group.artist, album: group.name)?.video
        }
    }
}

struct PlaylistCover: View {
    let playlist: LocalPlaylist
    var size: CGFloat = 48
    var corner: CGFloat = 6
    @EnvironmentObject var library: LibraryStore

    var body: some View {
        if let f = playlist.coverfile {
            ArtworkView(url: ArtworkStore.url(f), size: size, corner: corner, symbol: "music.note.list")
        } else if let u = playlist.coverurl.flatMap({ URL(string: $0) }) {
            ArtworkView(url: u, size: size, corner: corner, symbol: "music.note.list")
        } else {
            let arts = distinctart()
            if arts.count >= 4 {
                let h = size / 2
                VStack(spacing: 0) {
                    HStack(spacing: 0) { ArtworkView(url: arts[0], size: h, corner: 0); ArtworkView(url: arts[1], size: h, corner: 0) }
                    HStack(spacing: 0) { ArtworkView(url: arts[2], size: h, corner: 0); ArtworkView(url: arts[3], size: h, corner: 0) }
                }
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            } else {
                ArtworkView(url: arts.first, size: size, corner: corner, symbol: "music.note.list")
            }
        }
    }

    private func distinctart() -> [URL] {
        var seen = Set<String>(), out: [URL] = []
        // Stop after four usable covers instead of materialising every track in a
        // potentially very large playlist each time SwiftUI evaluates this view.
        for id in playlist.trackids {
            guard let t = library.data.tracks[id] else { continue }
            guard let u = library.shown(t).artworkurl, seen.insert(u.absoluteString).inserted else { continue }
            out.append(u)
            if out.count == 4 { break }
        }
        return out
    }
}

struct ImagePicker: UIViewControllerRepresentable {
    let onpick: (UIImage) -> Void
    @Environment(\.presentationMode) private var presentation

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var cfg = PHPickerConfiguration()
        cfg.filter = .images
        cfg.selectionLimit = 1
        let vc = PHPickerViewController(configuration: cfg)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: ImagePicker
        init(_ p: ImagePicker) { parent = p }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.presentation.wrappedValue.dismiss()
            guard let p = results.first?.itemProvider, p.canLoadObject(ofClass: UIImage.self) else { return }
            p.loadObject(ofClass: UIImage.self) { obj, _ in
                guard let img = obj as? UIImage else { return }
                DispatchQueue.main.async { self.parent.onpick(img) }
            }
        }
    }
}

// ---- video / animated artwork ---------------------------------------------------------------------------------------

// picks a video from the photo library. the file is copied to a temp location inside the provider callback (the provider's
// own url is deleted when the callback returns), then handed over for ArtworkStore.saveVideo to keep locally.
struct VideoPicker: UIViewControllerRepresentable {
    let onpick: (URL) -> Void
    @Environment(\.presentationMode) private var presentation

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var cfg = PHPickerConfiguration()
        cfg.filter = .videos
        cfg.selectionLimit = 1
        cfg.preferredAssetRepresentationMode = .current
        let vc = PHPickerViewController(configuration: cfg)
        vc.delegate = context.coordinator
        return vc
    }
    func updateUIViewController(_ vc: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: VideoPicker
        init(_ p: VideoPicker) { parent = p }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.presentation.wrappedValue.dismiss()
            guard let p = results.first?.itemProvider else { return }
            let type = UTType.movie.identifier
            guard p.hasItemConformingToTypeIdentifier(type) else { return }
            p.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                guard let url = url else { return }
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + (url.pathExtension.isEmpty ? "mov" : url.pathExtension))
                do { try FileManager.default.copyItem(at: url, to: tmp) } catch { return }
                DispatchQueue.main.async {
                    self.parent.onpick(tmp)   // the receiver deletes it after cropping
                }
            }
        }
    }
}

// muted, looping video shown whole at its natural aspect ratio (letterboxed when its frame differs).
// plain AVPlayer + an end-of-item observer: simpler and easier to diagnose than AVPlayerLooper. failures go to diagnostics.
struct LoopingVideoView: UIViewRepresentable {
    let url: URL
    var playing = true

    final class PlayerUIView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerlayer: AVPlayerLayer { layer as! AVPlayerLayer }
        var player: AVPlayer?
        var loaded: URL?
        var endobs: NSObjectProtocol?
        var statusobs: NSKeyValueObservation?
        func teardown() {
            player?.pause()
            if let o = endobs { NotificationCenter.default.removeObserver(o) }
            endobs = nil; statusobs = nil
            playerlayer.player = nil; player = nil; loaded = nil
        }
        deinit { teardown() }
    }

    func makeUIView(context: Context) -> PlayerUIView {
        let v = PlayerUIView()
        v.backgroundColor = .clear
        v.playerlayer.videoGravity = .resizeAspectFill
        return v
    }

    func updateUIView(_ v: PlayerUIView, context: Context) {
        if v.loaded != url {
            v.teardown()
            let item = AVPlayerItem(url: url)
            let p = AVPlayer(playerItem: item)
            p.isMuted = true
            p.actionAtItemEnd = .none
            p.allowsExternalPlayback = false
            v.endobs = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak p] _ in
                p?.seek(to: .zero); p?.play()
            }
            v.statusobs = item.observe(\.status, options: [.new]) { it, _ in
                if it.status == .failed { Log.e(.artwork, "animated artwork failed to play: \(it.error?.localizedDescription ?? "unknown error")") }
                else if it.status == .readyToPlay { Log.i(.artwork, "animated artwork ready") }
            }
            v.player = p
            v.playerlayer.player = p
            v.loaded = url
        }
        if playing { v.player?.play() } else { v.player?.pause() }
    }

    static func dismantleUIView(_ v: PlayerUIView, coordinator: ()) { v.teardown() }
}

// a muted version of the artwork's average colour, used for the Now Playing background. computed once per image.
enum ArtworkColor {
    private static let cache = NSCache<NSString, UIColor>()

    static func average(of image: UIImage, key: String) -> UIColor {
        if let c = cache.object(forKey: key as NSString) { return c }
        var px = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        var color = UIColor.darkGray
        if let cg = image.cgImage, let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space, bitmapInfo: info) {
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            let a = max(CGFloat(px[3]) / 255, 0.001)
            color = UIColor(red: CGFloat(px[0]) / 255 / a, green: CGFloat(px[1]) / 255 / a, blue: CGFloat(px[2]) / 255 / a, alpha: 1)
        }
        cache.setObject(color, forKey: key as NSString)
        return color
    }
}
