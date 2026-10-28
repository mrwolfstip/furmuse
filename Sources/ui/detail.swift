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
                                .font(.caption).foregroundColor(.secondary)
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
                        .font(.footnote).foregroundColor(.secondary)
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
                Button("save & close", action: saveandclose).font(.body.weight(.semibold))
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
    @State private var importing = false
    @State private var pasting = false
    @State private var syncing = false
    @State private var active = -1
    @State private var lastuser = Date.distantPast        // last time the user dragged the lyrics; auto-scroll waits a few seconds after that
    @State private var artimage: UIImage?
    @State private var sharinglyrics = false
    private let ticker = Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if let t = engine.current { content(t) } else { Text("nothing playing").foregroundColor(.white.opacity(0.65)) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LyricsBackdrop(image: artimage).ignoresSafeArea())
        .lyricsbarclear()
        .navigationTitle(engine.current.map { library.shown($0).title } ?? "lyrics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
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
                    Button("search lrclib again") { if let t = engine.current { Task { await lyrics.load(t, refetch: true) } } }
                    Button("remove my lyrics", role: .destructive) { if let t = engine.current { Task { await lyrics.removeuser(for: t) } } }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .task(id: "\(engine.current?.id ?? "")|\(settings.lyricson)|\(settings.lyricsnet)") {
            guard let t = engine.current else { artimage = nil; return }
            active = -1; lastuser = .distantPast
            async let loaded: Void = lyrics.load(t)
            if let u = library.shown(t).artworkurl { artimage = await ArtworkLoader.shared.image(u, maxpixel: 1200) }
            else { artimage = nil }
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
        var idx = -1
        for (i, l) in doc.lines.enumerated() where l.time <= pos { idx = i }
        return idx
    }

    @ViewBuilder
    private func content(_ t: Track) -> some View {
        if let doc = lyrics.doc(for: t.id) {
            let mode = lyrics.romanmode(for: t.id, library: library)
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 22) {
                            VStack(alignment: .leading, spacing: 3) {
                                AlbumLink(track: t) { Text(library.shown(t).title).font(.headline).foregroundColor(.white) }
                                ArtistLink(track: t) { Text(library.shown(t).artist).font(.subheadline).foregroundColor(.white.opacity(0.62)) }
                                if !doc.source.isEmpty {
                                    HStack(spacing: 4) {
                                        Text(doc.source)
                                        if let credit = doc.uploader, let url = URL(string: credit.url) { Text("·"); Link(credit.name, destination: url) }
                                        if let credit = doc.maker, let url = URL(string: credit.url) { Text("· synced by"); Link(credit.name, destination: url) }
                                    }
                                    .font(.caption2).foregroundColor(.white.opacity(0.45))
                                }
                                if !doc.synced { Text("these lyrics aren't timed. use sync lyrics in the … menu to time them.").font(.caption).foregroundColor(.white.opacity(0.55)).padding(.top, 2) }
                            }
                            .padding(.bottom, 18)
                            LazyVStack(alignment: .leading, spacing: 22) {
                                ForEach(Array(doc.lines.enumerated()), id: \.offset) { i, lyric in
                                    LyricLineView(lyric: lyric, index: i, active: active, synced: doc.synced,
                                                  size: min(max(CGFloat(settings.lyricssize) * 1.15, 16), 40),
                                                  words: settings.lyricswords, estimate: settings.lyricsfake,
                                                  laser: settings.lyricsstyle == "laser", mode: mode)
                                        .id(i)
                                        .onTapGesture {
                                            if doc.synced, lyric.time >= 0 { lastuser = .distantPast; engine.seek(lyric.time) }
                                        }
                                }
                            }
                        }
                        .frame(width: max(1, geometry.size.width - 40), alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.top, 24)
                        .padding(.bottom, 170)
                    }
                    // follow the song: the line being sung is kept near the upper third, unless the user is scrolling by hand
                    .onReceive(ticker) { _ in
                        guard doc.synced else { return }
                        let now = current(doc, engine.livepos())
                        guard now != active else { return }
                        active = now
                        if now >= 0, Date().timeIntervalSince(lastuser) > 3.5 {
                            withAnimation(.easeInOut(duration: 0.5)) { proxy.scrollTo(now, anchor: UnitPoint(x: 0.5, y: 0.34)) }
                            // the romanized sub-line of the current line fades in and changes the height: land once more when it has settled
                            if mode == "current" {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                    guard active == now, Date().timeIntervalSince(lastuser) > 3.5 else { return }
                                    withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(now, anchor: UnitPoint(x: 0.5, y: 0.34)) }
                                }
                            }
                        }
                    }
                    .onChange(of: mode) { _ in
                        guard active >= 0 else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { proxy.scrollTo(active, anchor: UnitPoint(x: 0.5, y: 0.34)) }
                    }
                    .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in lastuser = Date() })
                }
            }
        } else if lyrics.loadingid == t.id {
            ProgressView("finding lyrics…").tint(.white).foregroundColor(.white.opacity(0.75))
        } else {
            VStack(spacing: 8) {
                Image(systemName: "quote.bubble").font(.largeTitle)
                Text(lyrics.status.isEmpty ? "no lyrics available" : lyrics.status).font(.headline)
                Text("use the … menu to add synced lyrics.").font(.subheadline).opacity(0.6)
            }.padding()
            .foregroundColor(.white)
        }
    }

}

// one lyric line. the active line lights up word by word: real word timing when the lyrics have it, otherwise an estimate
// spread over the line (so line-synced lrc still gets a sweep). words are joined as Text so the line wraps like normal text.
// laser: lines blur with their distance from the active line; a romanized sub-line and an ad-lib line follow the same blur and dimming.
private struct LyricLineView: View {
    let lyric: LyricLine
    let index: Int
    let active: Int
    let synced: Bool
    let size: CGFloat
    let words: Bool
    let estimate: Bool
    let laser: Bool
    let mode: String            // off, replace, below or current
    @EnvironmentObject var engine: PlaybackEngine

    private var isactive: Bool {
        guard synced else { return true }
        let position = engine.livepos()
        return lyric.time <= position && position < lyric.end
    }
    private var distance: Int { abs(index - active) }
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
        if replaced {
            if !lyric.words.isEmpty { return lyric.words.map { LyricWord(time: $0.time, end: $0.end, text: $0.roman ?? $0.text) } }
            guard estimate else { return [] }
            var l = lyric
            l.text = lyric.roman ?? lyric.text
            return LyricsParser.estimatedwords(l)
        }
        if !lyric.words.isEmpty { return lyric.words }
        return estimate ? LyricsParser.estimatedwords(lyric) : []
    }

    private var timedbackground: [LyricWord] {
        guard synced, words, let background = lyric.backgroundwords, !background.isEmpty else { return [] }
        return background
    }

    // opacity of the whole line; classic keeps its old values
    private var dim: Double {
        if !synced || isactive { return 1 }
        if laser { return index < active ? 0.3 : 0.45 }
        return index < active ? 0.3 : 0.5
    }

    // blur grows with the distance from the active line (1.5, 3, 4.5, capped at 6); far outside the visible area there is no blur at all
    private var blurradius: CGFloat {
        guard laser, synced, distance > 0, distance <= 14 else { return 0 }
        return min(6, 1.5 * CGFloat(distance))
    }

    private var lineanimation: Animation? {
        if laser { return UIAccessibility.isReduceMotionEnabled ? nil : .easeInOut(duration: 0.4) }
        return .easeOut(duration: 0.25)
    }

    var body: some View {
        let ws = timedwords
        let bws = timedbackground
        VStack(alignment: lyric.opposite ? .trailing : .leading, spacing: 4) {
            if synced, isactive, !ws.isEmpty {
                TimelineView(.animation(minimumInterval: 1.0 / 24)) { _ in
                    sweep(ws, engine.livepos()).font(.system(size: size, weight: .bold))
                }
            } else {
                Text(shown)
                    .font(.system(size: size, weight: isactive ? .bold : .semibold))
                    .foregroundColor(.white)
                    .opacity(dim)
            }
            if showsub, let r = romanline {
                Text(r)
                    .font(.system(size: size * 0.6, weight: .medium))
                    .foregroundColor(.white)
                    .opacity(dim * 0.6)
                    .transition(.opacity)
            }
            if let a = adlib {
                if synced, isactive, !bws.isEmpty {
                    TimelineView(.animation(minimumInterval: 1.0 / 24)) { _ in
                        sweep(bws, engine.livepos()).font(.system(size: size * 0.65, weight: .semibold)).opacity(0.82)
                    }
                } else {
                    Text(a).font(.system(size: size * 0.65, weight: .semibold)).foregroundColor(.white).opacity(dim * 0.55)
                }
            }
        }
        .multilineTextAlignment(lyric.opposite ? .trailing : .leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: lyric.opposite ? .trailing : .leading)
        .contentShape(Rectangle())
        .scaleEffect(laser && synced && !isactive ? 0.96 : 1, anchor: lyric.opposite ? .trailing : .leading)
        .blur(radius: blurradius)
        .shadow(color: laser && isactive ? .white.opacity(0.65) : .clear, radius: laser && isactive ? 10 : 0)
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
    var body: some View {
        // GeometryReader + fixed frames: the blurred image must never size the parent (it used to make the screen wider than the display)
        GeometryReader { proxy in
            ZStack {
                LinearGradient(colors: [Color(red: 0.24, green: 0.12, blue: 0.30), Color(red: 0.05, green: 0.08, blue: 0.14)], startPoint: .topLeading, endPoint: .bottomTrailing)
                if let image = image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .blur(radius: 72)
                        .scaleEffect(1.35)
                        .opacity(0.72)
                }
                Color.black.opacity(0.38)
                LinearGradient(colors: [.black.opacity(0.10), .black.opacity(0.48)], startPoint: .top, endPoint: .bottom)
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
                      cover: cover, artistphoto: artistphoto)
    }

    // changes whenever anything that affects the card changes, so the preview redraws
    private var previewkey: String {
        "\(settings.cardbg)|\(settings.cardcolor)|\(settings.cardblur)|\(settings.cardshade)|\(settings.cardsize)|\(settings.cardbrand)|\(selected.sorted())|\(cover != nil)|\(artistphoto != nil)|\(romanchoice)|\(selected.contains { !romanof($0).isEmpty })"
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
                                    if romanchoice != "off", let r = lyric.roman, !r.isEmpty { Text(r).font(.footnote).foregroundColor(.secondary) }
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
                    if devices.selectedmissing { Text("that speaker is offline. open spotify on it and refresh.").font(.footnote).foregroundColor(.orange) }
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
                                    Text("\(d.name) · \(d.type.lowercased())\(d.is_active ? " · active" : "")\(d.is_restricted == true ? " · restricted" : "")").font(.caption).foregroundColor(.secondary)
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
                    Text(s.is_playing ? "playing" : "paused").font(.caption).foregroundColor(.secondary)
                } else {
                    Text(loaded ? "nothing is playing on that device" : "loading…").foregroundColor(.secondary)
                }
                HStack(spacing: 40) {
                    Spacer()
                    Button { act { await devices.previous() } } label: { Image(systemName: "backward.fill") }
                    Button { act { if state?.is_playing == true { await devices.pause() } else { await devices.resume() } } } label: { Image(systemName: state?.is_playing == true ? "pause.fill" : "play.fill") }
                    Button { act { await devices.next() } } label: { Image(systemName: "forward.fill") }
                    Spacer()
                }.font(.title2).buttonStyle(.borderless)
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
