import Foundation
import MediaPlayer
import UIKit

final class NowPlayingCenter: @unchecked Sendable {
    private unowned let engine: PlaybackEngine
    private let settings: Settings
    private let library: LibraryStore
    private let lyrics: LyricsStore
    private var artid = ""
    private var art: MPMediaItemArtwork?
    private var artimage: UIImage?       // first frame / static image, kept so animated artwork can use it as its preview
    private var artvideo: URL?
    private var applerequested = Set<String>()   // track ids already looked up this launch
    private var canvasrequested = Set<String>()
    private var lyricsrequested = Set<String>()
    private var lyricTimer: Timer?

    init(engine: PlaybackEngine, settings: Settings, library: LibraryStore, lyrics: LyricsStore) {
        self.engine = engine
        self.settings = settings
        self.library = library
        self.lyrics = lyrics
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in self?.engine.resume(); return .success }
        c.pauseCommand.addTarget { [weak self] _ in self?.engine.pause(); return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.engine.toggle(); return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in self?.engine.next(); return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in self?.engine.previous(); return .success }
        c.likeCommand.localizedTitle = "liked songs"
        c.likeCommand.addTarget { [weak self] _ in
            guard let self, let track = self.engine.current else { return .noSuchContent }
            self.library.toggleliked(track)
            self.refresh()
            return .success
        }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.engine.seek(e.positionTime)
            return .success
        }
        for cmd in [c.playCommand, c.pauseCommand, c.togglePlayPauseCommand, c.nextTrackCommand, c.previousTrackCommand, c.changePlaybackPositionCommand, c.likeCommand] { cmd.isEnabled = true }
        lyricTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            guard let self, self.settings.lockscreenlyrics, self.engine.isplaying else { return }
            self.refresh()
        }
    }

    func refresh() {
        guard let t = engine.current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        let s = library.shown(t)
        var artist = s.artist
        if settings.lockscreenlyrics {
            if let line = lyrics.currentline(for: t.id, at: engine.livepos()) { artist = line }
            else if !lyricsrequested.contains(t.id) {
                lyricsrequested.insert(t.id)
                Task { @MainActor [weak self] in
                    await self?.lyrics.load(t)
                    self?.refresh()
                }
            }
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: s.title,
            MPMediaItemPropertyArtist: artist,
            MPMediaItemPropertyAlbumTitle: s.album,
            MPMediaItemPropertyPlaybackDuration: engine.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: engine.livepos(),
            MPNowPlayingInfoPropertyPlaybackRate: engine.isplaying ? settings.speed : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: settings.speed
        ]
        cLikeState(t)
        let url = s.artworkurl
        if artid == (url?.absoluteString ?? ""), let a = art { info[MPMediaItemPropertyArtwork] = a }   // static fallback on every iOS
        #if WOLF_ANIMATED_ARTWORK && compiler(>=6.2)
        if #available(iOS 26.0, *), settings.animatestatic, artid == (url?.absoluteString ?? ""), let img = artimage {
            // User video wins. Online providers follow the same user-selected order as the in-app player.
            let video = library.videourl(t.id)
            let custom = library.data.overrides[t.id]?.artwork != nil
            var preview = img, vid = video, id = ""
            let ckey = ArtworkMotion.key(artid)
            let apple = settings.applecovers ? AppleCovers.shared.cached(artist: s.artist, album: s.album) : nil
            let canvas = settings.spotifycanvas && t.isspotify && SpotifyCanvas.shared.configured ? SpotifyCanvas.shared.cached(trackid: t.id) : nil
            if video == nil, !custom {
                if settings.animatedcoverorder == "apple", let c = apple {
                    preview = c.preview; vid = c.video; id = "wolf.apple." + AppleCovers.shared.key(artist: s.artist, album: s.album)
                } else if settings.animatedcoverorder != "apple", let c = canvas {
                    preview = c.preview; vid = c.video; id = "wolf.canvas." + t.id
                } else if let c = settings.animatedcoverorder == "apple" ? canvas : apple {
                    preview = c.preview; vid = c.video
                    id = settings.animatedcoverorder == "apple" ? "wolf.canvas." + t.id : "wolf.apple." + AppleCovers.shared.key(artist: s.artist, album: s.album)
                }
                if settings.applecovers, apple == nil, !applerequested.contains(t.id) {
                    applerequested.insert(t.id)
                    let artist = s.artist, album = s.album, tid = t.id
                    Task { @MainActor [weak self] in
                        if await AppleCovers.shared.cover(artist: artist, album: album) != nil {
                            guard let self, self.engine.current?.id == tid else { return }
                            self.refresh()
                        }
                    }
                }
                if settings.spotifycanvas, t.isspotify, SpotifyCanvas.shared.configured, canvas == nil, !canvasrequested.contains(t.id) {
                    canvasrequested.insert(t.id)
                    let tid = t.id
                    Task { @MainActor [weak self] in
                        let found = await SpotifyCanvas.shared.cover(trackid: tid) != nil
                        guard let self else { return }
                        self.canvasrequested.remove(tid)
                        if found, self.engine.current?.id == tid { self.refresh() }
                    }
                }
            }
            if id.isEmpty { id = "wolf." + (video.map { "v." + $0.lastPathComponent } ?? "s." + ckey) }
            AnimatedArtworkInfo.apply(to: &info, id: id, preview: preview, video: vid, cachekey: ckey)
        }
        #endif
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = engine.isplaying ? .playing : .paused
        let want = url?.absoluteString ?? ""
        if artid != want {
            artid = want
            art = nil
            artimage = nil
            guard let u = url else { return }
            let tid = t.id
            Task { @MainActor [weak self] in
                guard let img = await ArtworkLoader.shared.image(u, maxpixel: 600) else { return }
                guard let self = self, self.engine.current?.id == tid, self.artid == want else { return }
                self.artimage = img
                self.art = MPMediaItemArtwork(boundsSize: img.size) { _ in img }   // boundsSize = the image's own size: aspect ratio is kept
                self.refresh()
            }
        }
    }

    private func cLikeState(_ track: Track) {
        MPRemoteCommandCenter.shared().likeCommand.isActive = library.isliked(track.id)
    }
}
