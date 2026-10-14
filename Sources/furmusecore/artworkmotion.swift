import Foundation
import AVFoundation
import UIKit
import CryptoKit

// the two shapes the lock screen accepts for animated artwork (MPNowPlayingInfoProperty1x1AnimatedArtwork / 3x4AnimatedArtwork).
// per Apple's docs, if the preview image or video doesn't match the aspect ratio of the key it is attached to, the system
// ignores the animation and shows the static artwork. that is why artwork has to be cropped to one of these when it is added.
enum ArtworkAspect: String, CaseIterable, Identifiable {
    case square, tall
    var id: String { rawValue }
    var ratio: CGFloat { self == .square ? 1 : 0.75 }                       // width / height
    var label: String { self == .square ? "square 1:1" : "tall 3:4" }
    var outsize: CGSize { self == .square ? CGSize(width: 1080, height: 1080) : CGSize(width: 1080, height: 1440) }
    static func nearest(_ r: CGFloat) -> ArtworkAspect { abs(r - 1) <= abs(r - 0.75) ? .square : .tall }
}

extension UIImage {
    // upright copy (orientation baked in), so cgImage coordinates match what is displayed
    func normalizedup() -> UIImage {
        if imageOrientation == .up { return self }
        let fmt = UIGraphicsImageRendererFormat.default(); fmt.scale = 1
        return UIGraphicsImageRenderer(size: size, format: fmt).image { _ in draw(in: CGRect(origin: .zero, size: size)) }
    }
    // centre crop to a width/height ratio (aspect fill: nothing is stretched)
    func cropped(toAspect a: CGFloat) -> UIImage? {
        guard let cg = normalizedup().cgImage else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        var cw = w, ch = w / a
        if ch > h { ch = h; cw = h * a }
        let r = CGRect(x: (w - cw) / 2, y: (h - ch) / 2, width: cw, height: ch).integral
        return cg.cropping(to: r).map { UIImage(cgImage: $0) }
    }
}

enum ArtworkMotion {
    struct Failure: Error { let text: String }

    static let dir: URL = {
        var u = LibraryStore.supportdir.appendingPathComponent("motion", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        var v = URLResourceValues(); v.isExcludedFromBackup = true
        try? u.setResourceValues(v)
        return u
    }()

    static func key(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    // displayed (orientation applied) pixel size of a video
    static func orientedSize(_ url: URL) async -> CGSize? {
        let a = AVURLAsset(url: url)
        guard let t = try? await a.loadTracks(withMediaType: .video).first,
              let n = try? await t.load(.naturalSize), let tr = try? await t.load(.preferredTransform) else { return nil }
        let r = CGRect(origin: .zero, size: n).applying(tr)
        return CGSize(width: abs(r.width), height: abs(r.height))
    }

    static func videoAspect(_ url: URL) async -> CGFloat? {
        guard let s = await orientedSize(url), s.height > 0 else { return nil }
        return s.width / s.height
    }

    // ---- crop a video to the chosen aspect --------------------------------------------------------------------------
    // cropRect is in displayed video pixels. output: no audio, at most 30 s, 30 fps (the system wants a short loop, <= 60 fps),
    // exactly aspect.outsize. nothing is stretched: the crop rect has the aspect's ratio, so scaling is uniform.
    static func exportCropped(video url: URL, cropRect: CGRect, aspect: ArtworkAspect) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure(text: "no video track") }
        let natural = try await track.load(.naturalSize)
        let tr = try await track.load(.preferredTransform)
        let dur = try await asset.load(.duration)
        let comp = AVMutableComposition()
        guard let ct = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw Failure(text: "composition") }
        let limit = CMTimeMinimum(dur, CMTime(seconds: 30, preferredTimescale: 600))
        try ct.insertTimeRange(CMTimeRange(start: .zero, duration: limit), of: track, at: .zero)

        let oriented = CGRect(origin: .zero, size: natural).applying(tr)
        let s = aspect.outsize.width / max(cropRect.width, 1)
        let transform = tr
            .concatenating(CGAffineTransform(translationX: -oriented.minX - cropRect.minX, y: -oriented.minY - cropRect.minY))
            .concatenating(CGAffineTransform(scaleX: s, y: s))
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: ct)
        layer.setTransform(transform, at: .zero)
        let inst = AVMutableVideoCompositionInstruction()
        inst.timeRange = CMTimeRange(start: .zero, duration: limit)
        inst.layerInstructions = [layer]
        let vc = AVMutableVideoComposition()
        vc.instructions = [inst]
        vc.renderSize = aspect.outsize
        vc.frameDuration = CMTime(value: 1, timescale: 30)

        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        guard let ex = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else { throw Failure(text: "export session") }
        ex.outputURL = out
        ex.outputFileType = .mp4
        ex.videoComposition = vc
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in ex.exportAsynchronously { c.resume() } }
        guard ex.status == .completed else { throw Failure(text: ex.error?.localizedDescription ?? "export failed") }
        return out
    }

    // other shape from an existing video (e.g. a square video asked for as 3:4): centre crop, exported once and cached
    static func derivedVideo(from url: URL, aspect: ArtworkAspect) async -> URL? {
        let out = dir.appendingPathComponent("derived-\(key(url.lastPathComponent))-\(aspect.rawValue).mp4")
        if FileManager.default.fileExists(atPath: out.path) { return out }
        guard let size = await orientedSize(url) else { return nil }
        var cw = size.width, ch = cw / aspect.ratio
        if ch > size.height { ch = size.height; cw = ch * aspect.ratio }
        let rect = CGRect(x: (size.width - cw) / 2, y: (size.height - ch) / 2, width: cw, height: ch)
        guard let tmp = try? await exportCropped(video: url, cropRect: rect, aspect: aspect) else { return nil }
        try? FileManager.default.removeItem(at: out)
        do { try FileManager.default.moveItem(at: tmp, to: out) } catch { return nil }
        return out
    }

    // ---- animate a still cover ----------------------------------------------------------------------------------------
    // 8 s, 30 fps, seamless loop (slow zoom in and out with a tiny drift; the last frame leads straight back into the first),
    // generated from the cover and cached on disk. used so the lock screen can show an animated cover even when the cover
    // is a plain png / jpg. the image is centre-cropped to `aspect` first, so the video matches the preview exactly.
    static func loopVideo(from image: UIImage, aspect: ArtworkAspect, key: String) async -> URL? {
        let out = dir.appendingPathComponent("\(key)-\(aspect.rawValue).mp4")
        if FileManager.default.fileExists(atPath: out.path) { return out }
        return await Task.detached(priority: .utility) { render(image, aspect, out) }.value
    }

    private static func render(_ image: UIImage, _ aspect: ArtworkAspect, _ out: URL) -> URL? {
        guard let src = image.cropped(toAspect: aspect.ratio)?.cgImage else { return nil }
        let w = 720, h = aspect == .square ? 720 : 960
        let tmp = out.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".tmp.mp4")
        guard let writer = try? AVAssetWriter(outputURL: tmp, fileType: .mp4) else { return nil }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        guard writer.startWriting() else { return nil }
        writer.startSession(atSourceTime: .zero)
        let fps = 30, total = 30 * 8
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        for f in 0..<total {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { return nil }
                Thread.sleep(forTimeInterval: 0.002)
            }
            guard let pool = adaptor.pixelBufferPool else { return nil }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let buf = pb else { return nil }
            CVPixelBufferLockBaseAddress(buf, [])
            if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buf), width: w, height: h, bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(buf), space: space, bitmapInfo: info) {
                let p = Double(f) / Double(total)                       // 0..<1, frame `total` would equal frame 0
                let ease = (1 - cos(2 * Double.pi * p)) / 2             // 0 -> 1 -> 0
                let zoom = 1.0 + 0.08 * ease
                let dx = sin(2 * Double.pi * p) * 0.012 * Double(w)
                let dy = sin(4 * Double.pi * p) * 0.008 * Double(h)
                let dw = Double(w) * zoom, dh = Double(h) * zoom
                ctx.interpolationQuality = .high
                ctx.draw(src, in: CGRect(x: -(dw - Double(w)) / 2 + dx, y: -(dh - Double(h)) / 2 + dy, width: dw, height: dh))
            }
            CVPixelBufferUnlockBaseAddress(buf, [])
            adaptor.append(buf, withPresentationTime: CMTime(value: Int64(f), timescale: Int32(fps)))
        }
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        guard writer.status == .completed else { try? FileManager.default.removeItem(at: tmp); return nil }
        try? FileManager.default.removeItem(at: out)
        do { try FileManager.default.moveItem(at: tmp, to: out) } catch { return nil }
        return out
    }
}
