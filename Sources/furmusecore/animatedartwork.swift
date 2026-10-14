import Foundation
import MediaPlayer
import UIKit
import Network

// iOS 26+ animated Now Playing artwork (lock screen / Control Centre), per Apple's "Providing animated artwork for media items".
//
// rules that matter (all from the docs):
//  - the preview image and the video must match the aspect ratio of the key (1x1 = square, 3x4 = tall), otherwise the system
//    ignores the animation and shows the static artwork. artwork added in furmuse is cropped to one of those two shapes.
//  - the system uses the still preview instead in low power mode, low data mode, high thermal state, Reduce Motion on, or
//    Auto-Play Animated Images off (Settings > Accessibility > Motion). that is the system's call, not the app's.
//  - the video must be a local file; short loops under 30 s, no more than 60 fps.
//
// a custom video is used when it matches the preview's shape. otherwise (png / jpg covers, spotify covers, old uncropped videos)
// a seamless looping zoom is generated from the cover (ArtworkMotion.loopVideo) and cached, so the lock screen animates anyway.
//
// the key constants and `supportedAnimatedArtworkKeys` are taken from the docs; the constructor is the async-handler form.
// if Xcode 26 objects to anything here, clear wolfified_animated_flag in config/base.xcconfig to switch this file off.
#if WOLF_ANIMATED_ARTWORK && compiler(>=6.2)

// the docs list when the system shows only the still preview and never asks for the video. this logs every one of them so the
// diagnostics show which applies: low power mode, low data mode (a per-network setting, easy to have on for cellular), thermal
// state, Reduce Motion, and Auto-Play Animated Images.
enum ArtworkConditions {
    private static let monitor: NWPathMonitor = { let m = NWPathMonitor(); m.start(queue: DispatchQueue(label: "furmuse.conditions")); return m }()
    static func summary() -> String {
        let p = monitor.currentPath
        let thermal = ["nominal", "fair", "serious", "critical"][min(ProcessInfo.processInfo.thermalState.rawValue, 3)]
        return "low power: \(ProcessInfo.processInfo.isLowPowerModeEnabled), low data: \(p.isConstrained), thermal: \(thermal), reduce motion: \(UIAccessibility.isReduceMotionEnabled), auto-play video previews: \(UIAccessibility.isVideoAutoplayEnabled)"
    }
}

@available(iOS 26.0, *)
enum AnimatedArtworkInfo {
    // refresh() runs often (every playback state change). handing the system a NEW MPMediaItemAnimatedArtwork each time restarts
    // its loading, so the video never gets to play and only the preview shows. instances are therefore kept and reused for as
    // long as the artworkID is the same.
    private static var cache: [String: MPMediaItemAnimatedArtwork] = [:]
    private static let lock = NSLock()

    static func apply(to info: inout [String: Any], id: String, preview: UIImage, video: URL?, cachekey: String) {
        let supported = MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys
        var live = Set<String>()
        // both shapes are offered (when the platform supports them): which one the lock screen uses isn't something to guess.
        for aspect in ArtworkAspect.allCases {
            let key = aspect == .square ? MPNowPlayingInfoProperty1x1AnimatedArtwork : MPNowPlayingInfoProperty3x4AnimatedArtwork
            guard supported.contains(key) else { continue }
            let aid = id + "." + aspect.rawValue
            live.insert(aid)
            lock.lock(); let existing = cache[aid]; lock.unlock()
            if let e = existing { info[key] = e; continue }
            guard let fitted = preview.cropped(toAspect: aspect.ratio) else { continue }
            let art = MPMediaItemAnimatedArtwork(
                artworkID: aid,
                previewImageRequestHandler: { (size: CGSize) async -> UIImage? in
                    Log.i(.artwork, "lock screen asked for the \(aspect.rawValue) preview (\(Int(size.width))x\(Int(size.height)))")
                    return fitted
                },
                videoAssetFileURLRequestHandler: { (size: CGSize) async -> URL? in
                    Log.i(.artwork, "lock screen asked for the \(aspect.rawValue) video (\(Int(size.width))x\(Int(size.height)))")
                    if let v = video {
                        if let a = await ArtworkMotion.videoAspect(v), abs(a - aspect.ratio) < 0.02 { return v }
                        if let d = await ArtworkMotion.derivedVideo(from: v, aspect: aspect) { return d }
                    }
                    let out = await ArtworkMotion.loopVideo(from: fitted, aspect: aspect, key: cachekey)
                    if out == nil { Log.w(.artwork, "no \(aspect.rawValue) video could be provided; the still artwork stays") }
                    return out
                }
            )
            lock.lock(); cache[aid] = art; lock.unlock()
            info[key] = art
            Log.i(.artwork, "lock screen conditions -> " + ArtworkConditions.summary())
            Log.i(.artwork, "animated artwork offered for \(key == MPNowPlayingInfoProperty1x1AnimatedArtwork ? "1x1" : "3x4") (\(aid))")
        }
        if live.isEmpty { Log.w(.artwork, "this device reports no supported animated artwork keys") }
        lock.lock(); cache = cache.filter { live.contains($0.key) }; lock.unlock()
    }
}
#endif
