import SwiftUI
import Combine
import UniformTypeIdentifiers
import AVFoundation
import CoreImage

struct MappingView: View {
    let track: Track
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var resolver: ResolverManager
    @State private var input = ""
    @State private var candidates: [YouTubeCandidate] = []
    @State private var searching = false
    @State private var verifying = false

    private var mapping: Mapping? { library.data.mappings[track.id] }

    private func dur(_ d: Double?) -> String { d.map { fmttime($0) } ?? "?" }

    private func choose(_ c: YouTubeCandidate) {
        library.setmapping(track.id, Mapping(videoid: c.id, source: "youtube", verified: false, label: nil, auto: false, videotitle: c.title, channel: c.channel, videoduration: c.duration, trackduration: track.duration))
        resolver.forget(track.id)
    }

    var body: some View {
        List {
            TrackSourceSection(track: track)
            Section(header: Text(library.shown(track).title), footer: Text("renaming doesn't change the match.")) {
                KeyValue(key: "source", value: mapping?.source ?? "none")
                KeyValue(key: "video id", value: mapping?.videoid ?? "none")
                if let t = mapping?.videotitle { KeyValue(key: "video", value: t) }
                if let c = mapping?.channel, !c.isEmpty { KeyValue(key: "channel", value: c) }
                if mapping?.videoid != nil {
                    KeyValue(key: "length", value: "\(dur(mapping?.videoduration)) (track \(fmttime(track.duration)))")
                    KeyValue(key: "chosen by", value: mapping?.auto == false ? "you" : (mapping?.auto == true ? "automatic match" : "earlier version"))
                }
                KeyValue(key: "verified", value: mapping?.verified == true ? "yes" : "no")
                Button(verifying ? "checking…" : "check source now") {
                    verifying = true
                    Task { @MainActor in
                        do { let s = try await resolver.resolve(track, fresh: true); ToastCenter.shared.show("source ok: \(s.container) \(s.codec)") }
                        catch { ToastCenter.shared.show((error as? ResolveError)?.text ?? "couldn't verify", route: .mapping) }
                        verifying = false
                    }
                }.disabled(verifying)
                Button("clear and find automatically") {
                    library.setmapping(track.id, nil)
                    resolver.forget(track.id)
                    verifying = true
                    Task { @MainActor in
                        do { let s = try await resolver.resolve(track, fresh: true); ToastCenter.shared.show("found a source: \(s.origin)") }
                        catch { ToastCenter.shared.show((error as? ResolveError)?.text ?? "couldn't find a source", route: .mapping) }
                        verifying = false
                    }
                }.disabled(verifying)
                if mapping != nil { Button("clear mapping", role: .destructive) { library.setmapping(track.id, nil); resolver.forget(track.id) } }
            }
            Section(header: Text("set manually"), footer: Text("paste a youtube link.")) {
                TextField("youtube link or id", text: $input).autocapitalization(.none).disableAutocorrection(true)
                Button("use this video") {
                    if let v = YouTubeSearch.videoid(from: input) {
                        library.setmapping(track.id, Mapping(videoid: v, source: "youtube", verified: false, auto: false, trackduration: track.duration))
                        resolver.forget(track.id)
                        input = ""
                    } else { ToastCenter.shared.show("that isn't a youtube link or id") }
                }
            }
            Section(header: Text("search youtube"), footer: Text("results are checked against the song.")) {
                Button(searching ? "searching…" : "search") {
                    searching = true
                    Task { @MainActor in
                        candidates = await YouTubeSearch.search("\(track.artist.components(separatedBy: ",").first ?? track.artist) \(track.title)")
                        searching = false
                        if candidates.isEmpty { ToastCenter.shared.show("no youtube results") }
                    }
                }.disabled(searching)
                ForEach(candidates) { c in
                    let r = YouTubeMatcher.score(c, for: track)
                    Button { choose(c) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.title).foregroundColor(.primary).lineLimit(2)
                            Text("\(c.channel) · \(dur(c.duration))\((r.score ?? 0) >= YouTubeMatcher.threshold ? " · good match" : " · \(r.reason.isEmpty ? "weak match" : r.reason)")")
                                .appFont(.caption).foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .themed()
        .navigationTitle("audio source")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct OverrideView: View {
    let track: Track
    @EnvironmentObject var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var artist = ""
    @State private var album = ""
    @State private var albumartist = ""
    @State private var tracknumber = ""
    @State private var duration = ""
    @State private var musicbrainzid = ""
    @State private var picking = false
    @State private var pickingvideo = false
    @State fileprivate var cropsource: CropSource?

    private func durationtext(_ value: Double) -> String {
        if value.rounded() == value { return String(Int(value)) }
        var text = String(format: "%.3f", value)
        while text.last == "0" { text.removeLast() }
        if text.last == "." { text.removeLast() }
        return text
    }

    private func saveandclose() {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, !cleanArtist.isEmpty,
              let seconds = Double(duration.trimmingCharacters(in: .whitespacesAndNewlines)), seconds >= 0 else {
            ToastCenter.shared.show("title, artist and duration must be valid")
            return
        }
        let cleanAlbumArtist = albumartist.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanMBID = musicbrainzid.trimmingCharacters(in: .whitespacesAndNewlines)
        let numberText = tracknumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let number = numberText.isEmpty ? nil : Int(numberText)
        guard numberText.isEmpty || (number ?? 0) > 0 else {
            ToastCenter.shared.show("track number must be empty or greater than zero")
            return
        }
        library.edittrackmetadata(
            track.id,
            title: cleanTitle,
            artist: cleanArtist,
            album: album.trimmingCharacters(in: .whitespacesAndNewlines),
            albumartist: cleanAlbumArtist.isEmpty ? nil : cleanAlbumArtist,
            tracknumber: number,
            duration: seconds,
            musicbrainzid: cleanMBID.isEmpty ? nil : cleanMBID
        )
        ToastCenter.shared.show("changes saved")
        dismiss()
    }

    var body: some View {
        Form {
            Section(header: Text("artwork"), footer: Text("custom artwork stays on this phone. song artwork takes priority over the album cover.")) {
                HStack {
                    Spacer()
                    ArtworkView(url: library.shown(track).artworkurl, size: 176, corner: 14)
                        .shadow(color: .black.opacity(0.22), radius: 16, y: 8)
                    Spacer()
                }
                Button { picking = true } label: { Label("choose still cover", systemImage: "photo") }
                Button { pickingvideo = true } label: { Label("choose animated cover", systemImage: "play.rectangle") }
                if library.data.overrides[track.id]?.video != nil {
                    Text("animated artwork is used in the player and on supported lock screens. your original square cover stays unchanged and is used with reduced motion.")
                        .appFont(.footnote).foregroundColor(.secondary)
                }
                if library.data.overrides[track.id]?.artwork != nil || library.data.overrides[track.id]?.video != nil {
                    Button(role: .destructive) { library.clearartwork(track.id) } label: {
                        Label("reset custom covers", systemImage: "arrow.counterclockwise")
                    }
                }
            }
            Section(header: Text("details"), footer: Text("these corrections are used throughout the library and for future last.fm submissions. the playback service and source are not changed.")) {
                HStack { Text("title"); TextField("title", text: $title).multilineTextAlignment(.trailing) }
                HStack { Text("artist"); TextField("artist", text: $artist).multilineTextAlignment(.trailing) }
                HStack { Text("album"); TextField("album", text: $album).multilineTextAlignment(.trailing) }
                HStack { Text("album artist"); TextField("optional", text: $albumartist).multilineTextAlignment(.trailing) }
                HStack { Text("track number"); TextField("optional", text: $tracknumber).keyboardType(.numberPad).multilineTextAlignment(.trailing) }
                HStack { Text("duration (seconds)"); TextField("0", text: $duration).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
                HStack { Text("musicbrainz id"); TextField("optional", text: $musicbrainzid).textInputAutocapitalization(.never).disableAutocorrection(true).multilineTextAlignment(.trailing) }
            }
            Section {
                Button(role: .destructive) {
                    title = track.title
                    artist = track.artist
                    album = track.album
                    albumartist = track.albumartist ?? ""
                    tracknumber = track.tracknumber.map(String.init) ?? ""
                    duration = durationtext(track.duration)
                    musicbrainzid = track.musicbrainzid ?? ""
                } label: { Label("undo unsaved changes", systemImage: "arrow.counterclockwise") }
            }
        }
        .listStyle(.insetGrouped)
        .themed()
        .navigationTitle("song details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("save & close", action: saveandclose).appFont(.body.weight(.semibold))
            }
        }
        .onAppear {
            let s = library.shown(track)
            title = s.title
            artist = s.artist
            album = s.album
            albumartist = track.albumartist ?? ""
            tracknumber = track.tracknumber.map(String.init) ?? ""
            duration = durationtext(track.duration)
            musicbrainzid = track.musicbrainzid ?? ""
        }
        // picked media always goes through the crop step (1:1 or 3:4) before it is saved
        .sheet(isPresented: $picking) { ImagePicker { img in DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { cropsource = CropSource(kind: .image(img)) } } }
        .sheet(isPresented: $pickingvideo) { VideoPicker { url in DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { cropsource = CropSource(kind: .video(url)) } } }
        .sheet(item: $cropsource) { src in
            ArtworkCropView(source: src, ondone: { rect, aspect in await finishcrop(src, rect, aspect) }, oncancel: { discard(src) })
        }
    }
}

extension OverrideView {
    private func discard(_ src: CropSource) {
        if case .video(let u) = src.kind { try? FileManager.default.removeItem(at: u) }
        cropsource = nil
    }

    // applies the normalized crop to the real pixels, then stores the result
    @MainActor
    private func finishcrop(_ src: CropSource, _ n: CGRect, _ aspect: ArtworkAspect) async {
        switch src.kind {
        case .image(let img):
            let up = img.normalizedup()
            guard let cg = up.cgImage else { discard(src); return }
            let w = CGFloat(cg.width), h = CGFloat(cg.height)
            let r = CGRect(x: n.minX * w, y: n.minY * h, width: n.width * w, height: n.height * h).integral
            if let c = cg.cropping(to: r) { library.setartwork(track.id, image: UIImage(cgImage: c)) }
            else { ToastCenter.shared.show("couldn't crop that image") }
        case .video(let url):
            guard let size = await ArtworkMotion.orientedSize(url) else { ToastCenter.shared.show("couldn't read that video"); discard(src); return }
            let r = CGRect(x: n.minX * size.width, y: n.minY * size.height, width: n.width * size.width, height: n.height * size.height)
            do {
                let out = try await ArtworkMotion.exportCropped(video: url, cropRect: r, aspect: aspect)
                library.setvideoartwork(track.id, source: out)
                try? FileManager.default.removeItem(at: out)
            } catch {
                Log.e(.artwork, "video crop failed: \((error as? ArtworkMotion.Failure)?.text ?? error.localizedDescription)")
                ToastCenter.shared.show("couldn't crop that video")
            }
            try? FileManager.default.removeItem(at: url)
        }
        cropsource = nil
    }
}

struct LyricsView: View {
    @EnvironmentObject var engine: PlaybackEngine
    @EnvironmentObject var lyrics: LyricsStore
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var pasting = false
    @State private var syncing = false
    @State private var active: Set<Int> = []
    @State private var focused = -1
    @State private var lyricFrames: [Int: CGRect] = [:]
    @State private var lastuser = Date.distantPast        // last time the user dragged the lyrics; auto-scroll waits a few seconds after that
    @State private var manualBrowsing = false
    @State private var needsRefocus = false
    @State private var artimage: UIImage?
    @State private var backdropVideo: URL?
    @State private var sharinglyrics = false
    private let ticker = Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack(alignment: .top) {
            // Keep the screen full-height even when loading or no lyrics exist. Without this
            // sizing layer the ZStack collapses around the empty-state message and drags the
            // pinned track header into the middle of the display.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Group {
                if let t = engine.current { content(t) } else { Text("nothing playing").foregroundColor(.white.opacity(0.65)) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            if let track = engine.current { floatingHeader(track) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LyricsBackdrop(image: artimage, video: backdropVideo).ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .navigationBarHidden(true)
        .task(id: "\(engine.current?.id ?? "")|\(settings.lyricson)|\(settings.lyricsnet)|\(settings.lyricsbackground)") {
            guard let t = engine.current else { artimage = nil; backdropVideo = nil; return }
            active = []; focused = -1; lastuser = .distantPast; manualBrowsing = false; needsRefocus = false
            lyricFrames = [:]
            backdropVideo = nil
            async let loaded: Void = lyrics.load(t)
            if let u = library.shown(t).artworkurl { artimage = await ArtworkLoader.shared.image(u, maxpixel: 1200) }
            else { artimage = nil }
            if settings.lyricsbackground != "cover", !UIAccessibility.isReduceMotionEnabled {
                if settings.lyricsbackground == "canvas" {
                    if settings.spotifycanvas, t.isspotify {
                        if let cached = SpotifyCanvas.shared.cached(trackid: t.id)?.video { backdropVideo = cached }
                        else { backdropVideo = await SpotifyCanvas.shared.cover(trackid: t.id)?.video }
                    }
                } else {
                    backdropVideo = await AnimatedCovers.resolve(for: t, shown: library.shown(t), settings: settings, library: library)?.video
                }
            }
            await loaded
        }
        .copyPicker(isPresented: $importing, types: [.plainText, .data]) { urls in
            guard let t = engine.current, let u = urls.first else { return }
            let scoped = u.startAccessingSecurityScopedResource()
            defer { if scoped { u.stopAccessingSecurityScopedResource() } }
            guard let text = LyricsText.read(u) else { ToastCenter.shared.show("couldn't read that file"); return }
            // ttml by name or content; anything else (lrc, or a plain .txt of words) goes in as lrc and plain words stay unsynced
            let ext = LyricsText.ext(for: text, filename: u.pathExtension)
            Task { @MainActor in
                await lyrics.save(text, ext: ext, for: t)
                LyricsText.notify(lyricson: settings.lyricson)
            }
        }
        .sheet(isPresented: $pasting) {
            if let track = engine.current { LyricPasteSheet(track: track) }
        }
        .sheet(isPresented: $syncing) {
            if let track = engine.current { LyricSyncEditor(track: track, engine: engine) }
        }
        .sheet(isPresented: $sharinglyrics) {
            if let track = engine.current, let doc = lyrics.doc {
                LyricCardComposer(track: library.shown(track), doc: doc, current: current(doc, engine.livepos()), artwork: artimage)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
            guard engine.current != nil, lyrics.doc?.lines.isEmpty == false else { return }
            sharinglyrics = true
        }
    }

    private func floatingHeader(_ track: Track) -> some View {
        VStack(spacing: 16) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .appFont(.system(size: 24, weight: .bold))
                        .frame(width: 50, height: 50)
                        .background(.ultraThinMaterial, in: Circle())
                }
                Spacer()
                Menu {
                    Button("create lyric card") { sharinglyrics = true }
                        .disabled(lyrics.doc?.lines.isEmpty != false)
                    Button("import lyrics file") { importing = true }
                    Button("paste lyrics") { pasting = true }
                    Button("sync lyrics") { syncing = true }
                    Menu("romanization") {
                        romanitem("off", "off")
                        romanitem("romanized words", "replace")
                        romanitem("small text below", "below")
                        romanitem("current line only", "current")
                        romanitem("use app default", nil)
                    }
                    Button("search lrclib again") { Task { await lyrics.load(track, refetch: true) } }
                    Button("remove my lyrics", role: .destructive) { Task { await lyrics.removeuser(for: track) } }
                } label: {
                    Image(systemName: "ellipsis")
                        .appFont(.system(size: 23, weight: .bold))
                        .frame(width: 50, height: 50)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }
            .foregroundColor(.white)

            HStack(spacing: 14) {
                if let artimage {
                    Image(uiImage: artimage).resizable().scaledToFill()
                        .frame(width: 68, height: 68)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .shadow(color: .black.opacity(0.3), radius: 12, y: 7)
                }
                VStack(alignment: .leading, spacing: 4) {
                    AlbumLink(track: track) { Text(library.shown(track).title).appFont(.title2.weight(.bold)).foregroundColor(.white).lineLimit(1) }
                    ArtistLink(track: track) { Text(library.shown(track).artist).appFont(.subheadline.weight(.semibold)).foregroundColor(.white.opacity(0.68)).lineLimit(1) }
                    if let doc = lyrics.doc(for: track.id), !doc.source.isEmpty {
                        attributionText(doc)
                        .appFont(.caption2)
                        .foregroundColor(.white.opacity(0.56))
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .frame(maxWidth: .infinity)
        .zIndex(10)
    }

    private func attributionText(_ doc: LyricsDoc) -> Text {
        var value = AttributedString(doc.source)
        func append(_ prefix: String, _ credit: LyricsCredit?) {
            guard let credit else { return }
            value += AttributedString(prefix)
            var linked = AttributedString(credit.name)
            linked.link = URL(string: credit.url)
            value += linked
        }
        append(" · ", doc.uploader)
        append(" · synced by ", doc.maker)
        return Text(value)
    }

    @ViewBuilder
    private func romanitem(_ title: String, _ value: String?) -> some View {
        let id = engine.current?.id ?? ""
        Button { if !id.isEmpty { library.setromanization(id, value) } } label: {
            if library.romanization(id) == value { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }

    private func current(_ doc: LyricsDoc, _ pos: Double) -> Int {
        guard doc.synced else { return -1 }
        let singing = activeLines(doc, pos)
        // Keep the stack anchored to the first overlapping voice. It advances only when that
        // upper line ends, rather than jumping as soon as a second singer enters.
        if let earliest = singing.min(by: { doc.lines[$0].time < doc.lines[$1].time }) { return earliest }
        return doc.lines.lastIndex(where: { $0.time <= pos }) ?? -1
    }

    private func activeLines(_ doc: LyricsDoc, _ pos: Double) -> Set<Int> {
        Set(doc.lines.indices.filter { doc.lines[$0].time <= pos && pos < doc.lines[$0].end })
    }

    @ViewBuilder
    private func content(_ t: Track) -> some View {
        if let doc = lyrics.doc(for: t.id) {
            let mode = lyrics.romanmode(for: t.id, library: library)
            let topBlurEnabled = !doc.synced || doc.lines.first.map { first in
                first.end >= 0 && engine.livepos() >= first.end
            } ?? false
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 26) {
                            if !doc.synced { Text("these lyrics aren't timed. use sync lyrics in the … menu to time them.").appFont(.caption).foregroundColor(.white.opacity(0.55)) }
                            LazyVStack(alignment: .leading, spacing: 22) {
                                ForEach(Array(doc.lines.enumerated()), id: \.offset) { i, lyric in
                                    LyricLineView(lyric: lyric, index: i, synced: doc.synced,
                                                  size: min(max(CGFloat(settings.lyricssize) * 1.15, 16), 40),
                                                  words: settings.lyricswords, estimate: settings.lyricsfake,
                                                  active: active, focused: focused,
                                                  laser: settings.lyricsstyle == "laser", manualBrowsing: manualBrowsing, mode: mode)
                                        .blur(radius: settings.lyricsstyle == "laser"
                                              ? edgeBlur(for: lyricFrames[i], viewport: geometry.size.height,
                                                         topEnabled: topBlurEnabled)
                                              : 0)
                                        .opacity(edgeOpacity(for: lyricFrames[i], viewport: geometry.size.height))
                                        .background(GeometryReader { lineProxy in
                                            Color.clear.preference(
                                                key: LyricFramePreferenceKey.self,
                                                value: [i: lineProxy.frame(in: .named("lyricsViewport"))]
                                            )
                                        })
                                        .id(i)
                                        .onTapGesture {
                                            if doc.synced, lyric.time >= 0 { lastuser = .distantPast; engine.seek(lyric.time) }
                                        }
                                }
                            }
                        }
                        .frame(width: max(1, geometry.size.width - 40), alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.top, 164)
                        .padding(.bottom, 170)
                    }
                    .coordinateSpace(name: "lyricsViewport")
                    .onPreferenceChange(LyricFramePreferenceKey.self) { lyricFrames = $0 }
                    // follow the song: the line being sung is kept near the upper third, unless the user is scrolling by hand
                    .onReceive(ticker) { _ in
                        guard doc.synced else { return }
                        let position = engine.livepos()
                        let nowActive = activeLines(doc, position)
                        let nowFocused = current(doc, position)
                        if nowActive != active { active = nowActive }
                        let browsingExpired = manualBrowsing && Date().timeIntervalSince(lastuser) >= 5
                        if browsingExpired { manualBrowsing = false }
                        let focusChanged = nowFocused != focused
                        if focusChanged { focused = nowFocused }
                        guard focusChanged || (browsingExpired && needsRefocus) else { return }
                        if nowFocused >= 0, !manualBrowsing {
                            needsRefocus = false
                            withAnimation(.easeInOut(duration: 0.5)) { proxy.scrollTo(nowFocused, anchor: UnitPoint(x: 0.5, y: 0.34)) }
                            // the romanized sub-line of the current line fades in and changes the height: land once more when it has settled
                            if mode == "current" {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                    guard focused == nowFocused, !manualBrowsing else { return }
                                    withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(nowFocused, anchor: UnitPoint(x: 0.5, y: 0.34)) }
                                }
                            }
                        }
                    }
                    .onChange(of: mode) { _ in
                        guard focused >= 0 else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { proxy.scrollTo(focused, anchor: UnitPoint(x: 0.5, y: 0.34)) }
                    }
                    .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in
                        lastuser = Date()
                        manualBrowsing = true
                        needsRefocus = true
                    })
                }
            }
        } else if lyrics.loadingid == t.id {
            ProgressView("finding lyrics…").tint(.white).foregroundColor(.white.opacity(0.75))
        } else {
            VStack(spacing: 8) {
                Image(systemName: "quote.bubble").appFont(.largeTitle)
                Text(lyrics.status.isEmpty ? "no lyrics available" : lyrics.status).appFont(.headline)
                Text("use the … menu to add synced lyrics.").appFont(.subheadline).opacity(0.6)
            }.padding()
            .foregroundColor(.white)
        }
    }

    private func edgeBlur(for frame: CGRect?, viewport: CGFloat, topEnabled: Bool) -> CGFloat {
        guard let frame else { return 0 }
        // The fixed track header ends around 150 pt. Lyrics become increasingly out of
        // focus as they travel underneath it, which makes the scroll feel spatial.
        let topSoftEdge: CGFloat = 245
        let topFullEdge: CGFloat = 105
        let topProgress = topEnabled ? min(max((topSoftEdge - frame.midY) / (topSoftEdge - topFullEdge), 0), 1) : 0

        // A lighter version at the bottom lets lines recede behind the floating tab bar.
        let bottomSoftEdge = viewport - 195
        let bottomFullEdge = viewport - 45
        let bottomProgress = min(max((frame.midY - bottomSoftEdge) / (bottomFullEdge - bottomSoftEdge), 0), 1)
        return max(topProgress * 8, bottomProgress * 4)
    }

    private func edgeOpacity(for frame: CGRect?, viewport: CGFloat) -> Double {
        guard let frame else { return 1 }
        let top = min(max((frame.midY - 70) / 105, 0), 1)
        let bottom = min(max((viewport - 20 - frame.midY) / 115, 0), 1)
        return Double(max(0.28, min(top, bottom)))
    }

}

private struct LyricFramePreferenceKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

// one lyric line. the active line lights up word by word: real word timing when the lyrics have it, otherwise an estimate
// spread over the line (so line-synced lrc still gets a sweep). words are joined as Text so the line wraps like normal text.
// Blur belongs to the viewport edges. Every line in the readable middle stays sharp,
// including all simultaneously active voices.
private struct LyricLineView: View {
    let lyric: LyricLine
    let index: Int
    let synced: Bool
    let size: CGFloat
    let words: Bool
    let estimate: Bool
    let active: Set<Int>
    let focused: Int
    let laser: Bool
    let manualBrowsing: Bool
    let mode: String            // off, replace, below or current
    @EnvironmentObject var engine: PlaybackEngine
    private var isactive: Bool {
        guard synced else { return true }
        return active.contains(index)
    }
    private var emphasized: Bool {
        isactive || (synced && focused < 0 && index == 0)
    }
    private var romanline: String? { mode == "off" ? nil : lyric.roman }
    private var replaced: Bool { mode == "replace" && romanline != nil }
    // small romanized line under the original: every line for "below", the active line for "current" (unsynced lyrics have no active line)
    private var showsub: Bool {
        guard romanline != nil else { return false }
        return mode == "below" || (mode == "current" && isactive)
    }
    private var shown: String {
        let base = lyric.text.isEmpty ? "♪" : lyric.text
        return replaced ? (lyric.roman ?? base) : base
    }
    private var adlib: String? {
        guard let b = lyric.background, !b.isEmpty else { return nil }
        return replaced ? (lyric.backgroundroman ?? b) : b
    }

    private var timedwords: [LyricWord] {
        guard synced, words else { return [] }
        let candidates: [LyricWord]
        if replaced {
            candidates = lyric.words.map { LyricWord(time: $0.time, end: $0.end, text: $0.roman ?? $0.text) }
        } else {
            candidates = lyric.words
        }
        if covers(candidates, text: shown) { return candidates }
        guard estimate else { return [] }
        var complete = lyric
        complete.text = shown
        return LyricsParser.estimatedwords(complete)
    }

    private var timedbackground: [LyricWord] {
        guard synced, words, let text = adlib, !text.isEmpty else { return [] }
        let candidates = lyric.backgroundwords ?? []
        if covers(candidates, text: text) { return candidates }
        guard estimate else { return [] }
        var backgroundLine = lyric
        backgroundLine.text = text
        backgroundLine.words = []
        return LyricsParser.estimatedwords(backgroundLine)
    }

    private func covers(_ words: [LyricWord], text: String) -> Bool {
        guard !words.isEmpty else { return false }
        func compact(_ value: String) -> String {
            value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return compact(words.map(\.text).joined()) == compact(text)
    }

    // opacity of the whole line; classic keeps its old values
    private var dim: Double {
        if !synced || emphasized { return 1 }
        if laser { return index < focused ? 0.3 : 0.45 }
        return index < focused ? 0.3 : 0.5
    }

    private var lineanimation: Animation? {
        if laser { return UIAccessibility.isReduceMotionEnabled ? nil : .easeInOut(duration: 0.4) }
        return .easeOut(duration: 0.25)
    }

    private var inactiveBlur: CGFloat {
        guard laser, synced, focused >= 0, !isactive, !manualBrowsing else { return 0 }
        return 1.35
    }

    var body: some View {
        let ws = timedwords
        let bws = timedbackground
        VStack(alignment: lyric.opposite ? .trailing : .leading, spacing: 4) {
            if let singer = lyric.agentName, !singer.isEmpty {
                Text(singer).appFont(.caption2).foregroundColor(.white.opacity(isactive ? 0.7 : 0.35))
            }
            if synced, isactive, !ws.isEmpty {
                TimelineView(.animation(minimumInterval: 1.0 / 60)) { _ in
                    if #available(iOS 16.0, *) {
                        LaserSweepText(words: ws, position: engine.livepos(), size: size,
                                       weight: .bold, trailing: lyric.opposite, glowEnabled: laser)
                    } else {
                        sweep(ws, engine.livepos()).appFont(.system(size: size, weight: .bold))
                    }
                }
            } else {
                Text(shown)
                    .appFont(.system(size: size, weight: emphasized ? .bold : .semibold))
                    .foregroundColor(.white)
                    .opacity(dim)
            }
            if showsub, let r = romanline {
                Text(r)
                    .appFont(.system(size: size * 0.6, weight: .medium))
                    .foregroundColor(.white)
                    .opacity(dim * 0.6)
                    .transition(.opacity)
            }
            if let a = adlib {
                if synced, isactive, !bws.isEmpty {
                    TimelineView(.animation(minimumInterval: 1.0 / 60)) { _ in
                        if #available(iOS 16.0, *) {
                            LaserSweepText(words: bws, position: engine.livepos(), size: size * 0.65,
                                           weight: .semibold, trailing: lyric.opposite,
                                           glowEnabled: laser).opacity(0.82)
                        } else {
                            sweep(bws, engine.livepos()).appFont(.system(size: size * 0.65, weight: .semibold)).opacity(0.82)
                        }
                    }
                } else {
                    Text(a).appFont(.system(size: size * 0.65, weight: .semibold)).foregroundColor(.white).opacity(dim * 0.55)
                }
            }
        }
        .multilineTextAlignment(lyric.opposite ? .trailing : .leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: lyric.opposite ? .trailing : .leading)
        .contentShape(Rectangle())
        .scaleEffect(laser && synced && !emphasized ? 0.965 : 1, anchor: lyric.opposite ? .trailing : .leading)
        .blur(radius: inactiveBlur)
        .animation(lineanimation, value: active)
    }

    private func sweep(_ ws: [LyricWord], _ pos: Double) -> Text {
        let floor = laser ? 0.38 : 0.36
        return ws.reduce(Text("")) { line, word in
            guard laser else {
                let p = pos >= word.end ? 1.0 : (pos <= word.time ? 0.0 : (pos - word.time) / max(word.end - word.time, 0.05))
                return line + Text(word.text).foregroundColor(.white.opacity(floor + (1 - floor) * p))
            }
            // Apple Music-style laser sweep: each glyph owns a slice of the word's timing, so the light visibly travels left-to-right.
            let glyphs = Array(word.text)
            guard !glyphs.isEmpty else { return line }
            let duration = max(word.end - word.time, 0.05)
            return glyphs.enumerated().reduce(line) { text, item in
                let start = word.time + duration * Double(item.offset) / Double(glyphs.count)
                let end = word.time + duration * Double(item.offset + 1) / Double(glyphs.count)
                let p = pos >= end ? 1.0 : (pos <= start ? 0.0 : (pos - start) / max(end - start, 0.01))
                return text + Text(String(item.element)).foregroundColor(.white.opacity(floor + (1 - floor) * p))
            }
        }
    }
}

@available(iOS 16.0, *)
private struct LaserSweepText: View {
    struct Glyph: Identifiable {
        let id: Int
        let character: Character
        let brightness: Double
        let scale: Double
        let x: CGFloat
        let y: CGFloat
        let glowRadius: CGFloat
        let glowAlpha: Double
    }

    let words: [LyricWord]
    let position: Double
    let size: CGFloat
    let weight: Font.Weight
    let trailing: Bool
    let glowEnabled: Bool

    private func clamp(_ value: Double, _ low: Double = 0, _ high: Double = 1) -> Double {
        min(max(value, low), high)
    }

    private func smooth(_ value: Double) -> Double {
        let x = clamp(value)
        return x * x * (3 - 2 * x)
    }

    // Spicy's ScaleRange: .95 at rest, 1.0505 at 70%, then 1 at completion.
    private func wordScale(_ progress: Double) -> Double {
        let p = clamp(progress)
        if p <= 0.7 { return 0.95 + (1.0505 - 0.95) * smooth(p / 0.7) }
        return 1.0505 + (1 - 1.0505) * smooth((p - 0.7) / 0.3)
    }

    // Spicy's GlowRange: quick entrance, a held crest, then a soft release.
    private func wordGlow(_ progress: Double) -> Double {
        let p = clamp(progress)
        if p < 0.15 { return smooth(p / 0.15) }
        if p <= 0.6 { return 1 }
        return 1 - smooth((p - 0.6) / 0.4)
    }

    private func emphasis(_ progress: Double) -> Double {
        let p = clamp(progress)
        guard p > 0, p < 1 else { return 0 }
        return p < 0.5 ? smooth(p * 2) : 1 - smooth((p - 0.5) * 2)
    }

    private var glyphs: [Glyph] {
        var result: [Glyph] = []
        var id = 0
        let reduced = UIAccessibility.isReduceMotionEnabled
        for (wordIndex, word) in words.enumerated() {
            let characters = Array(word.text)
            let count = max(characters.count, 1)
            let duration = max(word.end - word.time, 0.05)
            let wordProgress = clamp((position - word.time) / duration)
            let isSinging = word.time <= position && position < word.end
            let isSung = position >= word.end
            let baseScale = reduced ? 1 : (isSung ? 1 : wordScale(wordProgress))
            let baseYOffset = reduced ? 0 : size * CGFloat(0.01 + (-0.033 - 0.01) * wordProgress)
            let baseGlow = reduced || !isSinging ? 0 : wordGlow(wordProgress)

            // Refreshed Simple Lyrics strengthens held words slowly, and the final
            // word gets the larger, longer flame from the reference renderer.
            let held = max(1, duration)
            let growAmount: Double = {
                let ratio = held / 2
                let grown = ratio > 1 ? sqrt(ratio) : pow(ratio, 3)
                let lastBoost = wordIndex == words.count - 1 ? 1.6 : 1
                return min(1.2, grown * 0.6 * lastBoost)
            }()
            let blurStrength: Double = {
                let ratio = held / 3
                let grown = ratio > 1 ? sqrt(ratio) : pow(ratio, 3)
                let lastBoost = wordIndex == words.count - 1 ? 1.5 : 1
                return min(0.8, grown * 0.5 * lastBoost)
            }()
            let flameDuration = held * (wordIndex == words.count - 1 ? 1.2 : 1)

            for (index, character) in characters.enumerated() {
                // A fixed .55-em fade crosses the word as a single continuous edge.
                // Half a glyph either side closely matches the CSS background sweep.
                let glyphCentre = Double(index) + 0.5
                let edge = wordProgress * Double(count + 1) - 0.5
                let lit = isSung ? 1 : smooth((edge - glyphCentre + 0.55) / 1.1)
                let brightness = glowEnabled ? 0.4 + 0.6 * lit : 0.36 + 0.64 * lit

                let stagger = (flameDuration * 0.4 / Double(count)) * Double(index)
                let flameAt = position - word.time - stagger
                let swell = reduced || !isSinging ? 0 : emphasis(flameAt / flameDuration)
                let fromCentre = Double(count) / 2 - Double(index)
                let x = size * CGFloat(-swell * 0.03 * growAmount * fromCentre)
                let lift = size * CGFloat(-swell * 0.025 * growAmount)
                let scale = baseScale * (1 + swell * 0.1 * growAmount)
                let emphasisGlow = swell * blurStrength
                // A glyph blooms only while the sweep is entering it. The two-sided curve has
                // no box or mask edge and falls away once the letter is fully active.
                let entranceGlow = 4 * lit * (1 - lit)
                let glowRadius = max(CGFloat(7 + 5 * entranceGlow), min(size * 0.45, size * CGFloat(0.45 * blurStrength)))
                let glowAlpha = glowEnabled ? max(entranceGlow * 0.78,
                                                  max(baseGlow * entranceGlow * 0.5,
                                                      emphasisGlow * (0.28 + 0.42 * lit))) : 0

                result.append(Glyph(id: id, character: character, brightness: brightness,
                                    scale: scale, x: x, y: baseYOffset + lift,
                                    glowRadius: glowRadius, glowAlpha: glowAlpha))
                id += 1
            }
        }
        return result
    }

    var body: some View {
        WrappingGlyphLayout(trailing: trailing, glowOutset: size * 0.28) {
            ForEach(glyphs) { glyph in
                LaserGlyphView(glyph: glyph, size: size, weight: weight)
            }
        }
        // Do not rasterize this into a drawingGroup: its finite texture bounds clip shadows.
        // Cached wrapping and crest-only shadows keep this path light without imposing a
        // hard visual boundary, so the glow can naturally overflow the lyric line.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(words.map(\.text).joined())
    }
}

@available(iOS 16.0, *)
private struct LaserGlyphView: View {
    let glyph: LaserSweepText.Glyph
    let size: CGFloat
    let weight: Font.Weight

    @ViewBuilder var body: some View {
        let text = Text(String(glyph.character))
            .appFont(.system(size: size, weight: weight))
            .foregroundColor(.white.opacity(glyph.brightness))
            .scaleEffect(glyph.scale)
            .offset(x: glyph.x, y: glyph.y)
        if glyph.glowAlpha > 0.01 {
            text
                .shadow(color: .white.opacity(glyph.glowAlpha), radius: glyph.glowRadius)
                .shadow(color: .white.opacity(glyph.glowAlpha * 0.35), radius: glyph.glowRadius * 2.2)
        } else {
            text
        }
    }
}

@available(iOS 16.0, *)
private struct WrappingGlyphLayout: Layout {
    let trailing: Bool
    let glowOutset: CGFloat

    struct Cache {
        var sizes: [CGSize] = []
        var width: CGFloat = -1
        var rows: [Row] = []
    }

    struct Row {
        var range: Range<Int>
        var width: CGFloat
        var height: CGFloat
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(sizes: subviews.map { $0.sizeThatFits(.unspecified) })
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        // Scale, opacity and shadow do not affect layout. Re-measure only when the glyph count
        // or underlying font/text changes, not on every animation frame.
        if cache.sizes.count != subviews.count {
            cache.sizes = subviews.map { $0.sizeThatFits(.unspecified) }
            cache.width = -1
        }
    }

    private func rows(_ subviews: Subviews, width: CGFloat, cache: inout Cache) -> [Row] {
        if abs(cache.width - width) < 0.25, !cache.rows.isEmpty { return cache.rows }
        guard !subviews.isEmpty else { return [] }
        var result: [Row] = []
        var start = 0
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        for index in subviews.indices {
            let size = cache.sizes[index]
            if rowWidth > 0, rowWidth + size.width > width {
                result.append(Row(range: start..<index, width: rowWidth, height: rowHeight))
                start = index; rowWidth = 0; rowHeight = 0
            }
            rowWidth += size.width
            rowHeight = max(rowHeight, size.height)
        }
        result.append(Row(range: start..<subviews.endIndex, width: rowWidth, height: rowHeight))
        cache.width = width
        cache.rows = result
        return result
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let available = max(proposal.width ?? cache.sizes.reduce(0) { $0 + $1.width }, 1)
        let layoutRows = rows(subviews, width: available, cache: &cache)
        // The drawing group rasterizes to this exact rectangle. Reserve transparent room for
        // the travelling shadow so it is never cropped to the font's typographic bounds.
        return CGSize(width: available, height: layoutRows.reduce(0) { $0 + $1.height } + glowOutset * 2)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let layoutRows = rows(subviews, width: bounds.width, cache: &cache)
        var y = bounds.minY + glowOutset
        for row in layoutRows {
            var x = trailing ? bounds.maxX - row.width : bounds.minX
            for index in row.range {
                let size = cache.sizes[index]
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      anchor: .topLeading, proposal: ProposedViewSize(size))
                x += size.width
            }
            y += row.height
        }
    }
}

private extension View {
    // let the lyrics backdrop show through the status bar / navigation bar area instead of a black strip
    @ViewBuilder func lyricsbarclear() -> some View {
        if #available(iOS 16.0, *) {
            self.toolbarBackground(.hidden, for: .navigationBar).toolbarColorScheme(.dark, for: .navigationBar)
        } else { self }
    }
}

private struct LyricsBackdrop: View {
    let image: UIImage?
    let video: URL?
    @EnvironmentObject var settings: Settings
    @Environment(\.scenePhase) private var phase
    var body: some View {
        // GeometryReader + fixed frames: the blurred image must never size the parent (it used to make the screen wider than the display)
        GeometryReader { proxy in
            ZStack {
                LinearGradient(colors: [Color(red: 0.24, green: 0.12, blue: 0.30), Color(red: 0.05, green: 0.08, blue: 0.14)], startPoint: .topLeading, endPoint: .bottomTrailing)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .blur(radius: settings.lyricsbackdropblur)
                        .scaleEffect(1.22)
                        .saturation(settings.lyricsbackdropsaturation)
                }
                if let video {
                    LoopingVideoView(url: video, playing: phase == .active)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .blur(radius: settings.lyricsbackdropblur)
                        .scaleEffect(1.16)
                        .saturation(settings.lyricsbackdropsaturation)
                        .transition(.opacity)
                }
                Color.black.opacity(settings.lyricsbackdropshade)
                LinearGradient(colors: [.black.opacity(0.06), .black.opacity(0.38)], startPoint: .top, endPoint: .bottom)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .accessibilityHidden(true)
    }
}

private struct LyricCardComposer: View {
    let track: Track
    let doc: LyricsDoc
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var lyrics: LyricsStore
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<Int>
    @State private var romanpick = ""            // "" = not chosen yet, follow the song's effective romanization
    @State private var shareURL: URL?
    @State private var cover: UIImage?
    @State private var artistphoto: UIImage?
    @State private var preview: UIImage?

    init(track: Track, doc: LyricsDoc, current: Int, artwork: UIImage?) {
        self.track = track; self.doc = doc
        _cover = State(initialValue: artwork)
        let start = min(max(current, 0), max(0, doc.lines.count - 1))
        _selected = State(initialValue: Set(start..<min(doc.lines.count, start + 3)))
    }

    // the doc may have been romanized after the composer opened, so read the live one for this track
    private var lyricdoc: LyricsDoc { lyrics.doc(for: track.id) ?? doc }

    // off / replace / below. a still image can't animate, so the "current line only" style becomes small text below
    private var defaultroman: String {
        let m = lyrics.romanmode(for: track.id, library: library)
        return m == "current" ? "below" : m
    }
    private var romanchoice: String { romanpick.isEmpty ? defaultroman : romanpick }
    private func romanof(_ i: Int) -> String { lyricdoc.lines.indices.contains(i) ? (lyricdoc.lines[i].roman ?? "") : "" }

    private var bg: CardBackground { CardBackground(rawValue: settings.cardbg) ?? .cover }
    private var artistname: String { library.primaryartist(track) }
    private var artisturl: URL? { library.artistimageurl(artistname) }
    private var colorbinding: Binding<Color> {
        Binding(get: { Color(UIColor(hexstring: settings.cardcolor)) }, set: { settings.cardcolor = UIColor($0).hexstring })
    }

    // the chosen picture exists but hasn't finished loading: sharing waits so a card is never exported with a missing background
    private var waiting: Bool {
        switch bg {
        case .solid: return false
        case .cover: return track.artworkurl != nil && cover == nil
        case .artist: return artisturl != nil && artistphoto == nil
        }
    }
    private var nopicture: Bool {
        switch bg {
        case .solid: return false
        case .cover: return track.artworkurl == nil
        case .artist: return artisturl == nil
        }
    }

    private func spec() -> LyricCardSpec {
        LyricCardSpec(title: track.title, artist: track.artist,
                      lines: selected.sorted().compactMap { lyricdoc.lines.indices.contains($0) ? lyricdoc.lines[$0].text : nil },
                      romanlines: romanchoice == "off" ? nil : selected.sorted().filter { lyricdoc.lines.indices.contains($0) }.map { romanof($0) },
                      romanstyle: romanchoice == "below" ? "below" : "replace",
                      background: bg, color: UIColor(hexstring: settings.cardcolor),
                      blur: CGFloat(settings.cardblur), shade: CGFloat(settings.cardshade),
                      lyricsize: CGFloat(settings.cardsize), brand: settings.cardbrand,
                      fontname: settings.customfontname,
                      cover: cover, artistphoto: artistphoto)
    }

    // changes whenever anything that affects the card changes, so the preview redraws
    private var previewkey: String {
        "\(settings.cardbg)|\(settings.cardcolor)|\(settings.cardblur)|\(settings.cardshade)|\(settings.cardsize)|\(settings.cardbrand)|\(settings.customfontname)|\(selected.sorted())|\(cover != nil)|\(artistphoto != nil)|\(romanchoice)|\(selected.contains { !romanof($0).isEmpty })"
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    Group {
                        if let p = preview { Image(uiImage: p).resizable().scaledToFit() }
                        else { Color.gray.opacity(0.18).aspectRatio(1, contentMode: .fit).overlay(ProgressView()) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
                Section(header: Text("background"), footer: Text(nopicture ? "there's no \(bg.label) for this song yet, so the colour is used." : (bg == .artist ? "until an artist photo is found or chosen, the album cover is used. you can change the artist photo from the artist's page in the library." : ""))) {
                    Picker("background", selection: $settings.cardbg) {
                        ForEach(CardBackground.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    if bg == .solid || nopicture {
                        ColorPicker("colour", selection: colorbinding, supportsOpacity: false)
                    }
                    if bg != .solid {
                        HStack { Text("blur"); Slider(value: $settings.cardblur, in: 0...150, step: 1); Text("\(Int(settings.cardblur))").monospacedDigit().foregroundColor(.secondary).frame(minWidth: 32, alignment: .trailing) }
                        HStack { Text("darken"); Slider(value: $settings.cardshade, in: 0...0.85); Text("\(Int(settings.cardshade * 100))%").monospacedDigit().foregroundColor(.secondary).frame(minWidth: 44, alignment: .trailing) }
                    }
                }
                Section(header: Text("text"), footer: Text("current line only is shown as small text below on a card, because a still image can't animate.")) {
                    Picker("romanization", selection: Binding(get: { romanchoice }, set: { romanpick = $0 })) {
                        Text("off").tag("off"); Text("romanized").tag("replace"); Text("small text below").tag("below")
                    }
                    .pickerStyle(.segmented)
                    HStack { Text("size"); Slider(value: $settings.cardsize, in: 40...76, step: 2) }
                    Toggle("show furmuse", isOn: $settings.cardbrand)
                }
                Section(footer: Text("pick up to five lines.")) {
                    ForEach(Array(lyricdoc.lines.enumerated()), id: \.offset) { index, lyric in
                        Button { toggle(index) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: selected.contains(index) ? "checkmark.circle.fill" : "circle")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(lyric.text).foregroundColor(.primary)
                                    if romanchoice != "off", let r = lyric.roman, !r.isEmpty { Text(r).appFont(.footnote).foregroundColor(.secondary) }
                                }
                                .multilineTextAlignment(.leading)
                            }
                        }
                    }
                }
            }
            .themed()
            .navigationTitle("lyric card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("cancel") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("share") { shareURL = export() }
                        .disabled(selected.isEmpty || waiting)
                }
            }
        }
        .navigationViewStyle(.stack)
        // album cover (the lyrics screen usually hands it over already loaded)
        .task(id: track.artwork) {
            if cover == nil, let url = track.artworkurl { cover = await ArtworkLoader.shared.image(url, maxpixel: 1400) }
        }
        // artist photo: look it up on spotify once, only when the card actually uses it
        .task(id: "\(artistname)|\(bg == .artist)") {
            if bg == .artist { await library.fetchartistimage(artistname) }
        }
        .task(id: artisturl?.absoluteString ?? "") {
            artistphoto = nil
            if let url = artisturl { artistphoto = await ArtworkLoader.shared.image(url, maxpixel: 1400) }
        }
        // live preview, drawn off the main thread and slightly delayed so dragging a slider stays smooth
        .task(id: previewkey) {
            do { try await Task.sleep(nanoseconds: 120_000_000) } catch { return }
            let current = spec()
            let image = await Task.detached(priority: .userInitiated) { LyricCardRenderer.render(current, side: 720) }.value
            if !Task.isCancelled { preview = image }
        }
        .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) {
            if let url = shareURL { ShareSheet(url: url) }
        }
    }

    private func toggle(_ index: Int) {
        if selected.contains(index) { selected.remove(index) }
        else if selected.count < 5 { selected.insert(index) }
        else { ToastCenter.shared.show("choose up to five lyric lines") }
    }

    private func export() -> URL? {
        guard let data = LyricCardRenderer.render(spec()).pngData() else { ToastCenter.shared.show("couldn't create lyric card"); return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("furmuse-lyrics-\(UUID().uuidString).png")
        do { try data.write(to: url, options: .atomic); return url }
        catch { ToastCenter.shared.show("couldn't create lyric card"); return nil }
    }
}

struct DevicePickerView: View {
    @EnvironmentObject var devices: DeviceManager
    @EnvironmentObject var auth: SpotifyAuth
    @EnvironmentObject var library: LibraryStore
    @State private var renaming: SpDevice?
    @State private var alias = ""

    var body: some View {
        List {
            if !auth.connected {
                Text("connect spotify first. devices are discovered from your spotify account.").foregroundColor(.secondary)
            } else {
                Section(header: Text("selected"), footer: Text("furmuse remote-controls the speaker you pick.")) {
                    KeyValue(key: "device", value: devices.selectedname)
                    if devices.selectedmissing { Text("that speaker is offline. open spotify on it and refresh.").appFont(.footnote).foregroundColor(.orange) }
                    if devices.selectedid != nil { Button("forget selection", role: .destructive) { devices.select(nil) } }
                }
                Section(header: Text("available"), footer: Text(devices.devices.isEmpty ? "no speakers found. open spotify on one, then refresh." : "press and hold to rename.")) {
                    ForEach(devices.devices) { d in
                        Button {
                            if let id = d.id { devices.select(id) } else { ToastCenter.shared.show("this device can't be selected") }
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(devices.display(d)).foregroundColor(.primary)
                                    Text("\(d.name) · \(d.type.lowercased())\(d.is_active ? " · active" : "")\(d.is_restricted == true ? " · restricted" : "")").appFont(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                if d.id == devices.selectedid { Image(systemName: "checkmark") }
                            }
                        }
                        .contextMenu { Button("set local name") { alias = d.id.flatMap { library.data.aliases[$0] } ?? ""; renaming = d } }
                    }
                }
            }
        }
        .themed()
        .navigationTitle("connect device")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("refresh") { Task { await devices.refresh() } }.disabled(devices.loading || !auth.connected) } }
        .task { await devices.refresh() }
        .sheet(item: Binding(get: { renaming.map { IdentifiedDevice(device: $0) } }, set: { if $0 == nil { renaming = nil } })) { item in
            NavigationView {
                Form {
                    Section(footer: Text("local name for \(item.device.name). leave empty to use the real name.")) { TextField("local name", text: $alias) }
                    Button("save") { if let id = item.device.id { devices.setalias(id, alias) }; renaming = nil }
                }
                .themed().navigationTitle("rename").navigationBarTitleDisplayMode(.inline)
            }
        }
    }
}

struct IdentifiedDevice: Identifiable {
    let device: SpDevice
    var id: String { device.id ?? device.name }
}

extension IdentifiedDevice: Equatable {
    static func == (a: IdentifiedDevice, b: IdentifiedDevice) -> Bool { a.id == b.id }
}

struct RemoteView: View {
    @EnvironmentObject var devices: DeviceManager
    @State private var state: SpPlayerState?
    @State private var volume = 50.0
    @State private var loaded = false

    var body: some View {
        List {
            Section(header: Text(devices.selectedname)) {
                if let s = state, let t = s.item?.track {
                    Text(t.title); Text(t.artist).foregroundColor(.secondary)
                    Text(s.is_playing ? "playing" : "paused").appFont(.caption).foregroundColor(.secondary)
                } else {
                    Text(loaded ? "nothing is playing on that device" : "loading…").foregroundColor(.secondary)
                }
                HStack(spacing: 40) {
                    Spacer()
                    Button { act { await devices.previous() } } label: { Image(systemName: "backward.fill") }
                    Button { act { if state?.is_playing == true { await devices.pause() } else { await devices.resume() } } } label: { Image(systemName: state?.is_playing == true ? "pause.fill" : "play.fill") }
                    Button { act { await devices.next() } } label: { Image(systemName: "forward.fill") }
                    Spacer()
                }.appFont(.title2).buttonStyle(.borderless)
            }
            Section(footer: Text(state?.device?.volume_percent == nil || state?.device?.supports_volume == false ? "this speaker's volume can't be changed here." : "")) {
                Slider(value: $volume, in: 0...100, step: 1) { editing in
                    if !editing { Task { await devices.volume(Int(volume)) } }
                }
                .disabled(state?.device?.volume_percent == nil || state?.device?.supports_volume == false)
                Button("move spotify playback to this device") { act { await devices.transfer(play: true) } }
            }
        }
        .themed()
        .navigationTitle("remote")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("refresh") { act {} } } }
        .task { await reload() }
    }

    private func act(_ work: @escaping () async -> Void) {
        Task { @MainActor in
            await work()
            try? await Task.sleep(nanoseconds: 600_000_000)
            await reload()
        }
    }

    @MainActor
    private func reload() async {
        state = await devices.remotestate()
        loaded = true
        if let v = state?.device?.volume_percent { volume = Double(v) }
    }
}
