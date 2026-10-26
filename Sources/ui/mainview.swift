import SwiftUI
import UIKit
import AVFoundation
import MediaPlayer

private enum PlayerSheet: Identifiable {
    case source(Track), edit(Track), speed
    var id: String {
        switch self { case .source(let t): return "source-\(t.id)"; case .edit(let t): return "edit-\(t.id)"; case .speed: return "speed" }
    }
}

struct MainView: View {
    @EnvironmentObject var toasts: ToastCenter
    @EnvironmentObject var engine: PlaybackEngine

    var body: some View {
        TabView {
            NavigationView {
                PlayerView()
                    .themed()
                    .navigationBarHidden(true)
            }
            .navigationViewStyle(.stack)
            .tabItem { Label("home", systemImage: "house.fill") }

            NavigationView { LibraryView() }
                .navigationViewStyle(.stack)
                .tabItem { Label("library", systemImage: "books.vertical.fill") }

            NavigationView { SettingsView() }
                .navigationViewStyle(.stack)
                .tabItem { Label("settings", systemImage: "gearshape.fill") }
        }
        .background(AeroBackdrop().ignoresSafeArea())
        .modifier(TransparentTabBar())
        .sheet(item: $toasts.route) { r in
            NavigationView { routeview(r).themed().navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("done") { toasts.route = nil } } } }
                .navigationViewStyle(.stack)
        }
    }

    @ViewBuilder
    private func routeview(_ r: Route) -> some View {
        switch r {
        case .spotify: SpotifySettingsView()
        case .lastfm: LastfmSettingsView()
        case .source: SourceSettingsView()
        case .devices: SpotifySettingsView()
        case .downloads: DownloadsSettingsView()
        case .mapping:
            if let t = engine.current { MappingView(track: t) } else { SourceSettingsView() }
        }
    }
}

private struct TransparentTabBar: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.toolbarBackground(.hidden, for: .tabBar)
        } else {
            content
        }
    }
}

struct PlayerView: View {
    @EnvironmentObject var engine: PlaybackEngine
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var downloads: DownloadManager
    @Environment(\.accessibilityReduceMotion) private var reducemotion
    @Environment(\.colorScheme) private var scheme
    @State private var scrub = 0.0
    @State private var dragging = false
    @State private var artimage: UIImage?
    @State private var artcolor: UIColor?
    @State private var sheet: PlayerSheet?
    @State private var covervideo: URL?         // apple animated cover or spotify canvas for the song on screen
    @State private var webPlaybackTaps: [Date] = []
    @State private var showWebPlaybackHelp = false

    private var coverkey: String {
        let perSong = engine.current.flatMap { library.animatedcoverorder($0.id) } ?? "default"
        return "\(engine.current?.id ?? "")|\(settings.applecovers)|\(settings.applecoversurl)|\(settings.spotifycanvas)|\(settings.spotifycanvasurl)|\(settings.animatedcoverorder)|\(perSong)"
    }
    private var shownid: String { engine.current.map { (library.shown($0).artwork ?? $0.id) + "-\(settings.showanimatedplayer)-\(covervideo?.absoluteString ?? "")" } ?? "" }
    private var dark: Bool { scheme == .dark }
    // text: plain white on the dark scrim / black on the light one, so it never depends on the artwork or the accent
    private var fg: Color { dark ? .white : .black }
    private var sub: Color { (dark ? Color.white : Color.black).opacity(0.72) }
    private var palette: NowPlayingPalette { NowPlayingPalette(art: artcolor, dark: dark, amoled: settings.amoled, fallback: settings.tint(scheme)) }

    var body: some View {
        content
        .background(NowPlayingBackground(image: artimage, palette: palette, reducemotion: reducemotion))
        .accentColor(palette.accent)
        .animation(reducemotion ? nil : .easeInOut(duration: 0.35), value: shownid)
        .task(id: shownid) {
            guard let t = engine.current else { artimage = nil; artcolor = nil; return }
            guard let u = library.shown(t).artworkurl else { artimage = nil; artcolor = nil; return }
            let img = await ArtworkLoader.shared.image(u, maxpixel: 1600)
            artimage = img
            if settings.showanimatedplayer, let video = library.videourl(t.id) ?? covervideo, !reducemotion {
                let frame = await Task.detached(priority: .utility) { () -> UIImage? in
                    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video)); generator.appliesPreferredTrackTransform = true
                    return (try? generator.copyCGImage(at: CMTime(seconds: 0.25, preferredTimescale: 600), actualTime: nil)).map(UIImage.init(cgImage:))
                }.value
                artcolor = frame.map { ArtworkColor.average(of: $0, key: video.absoluteString) } ?? img.map { ArtworkColor.average(of: $0, key: u.absoluteString) }
            } else { artcolor = img.map { ArtworkColor.average(of: $0, key: u.absoluteString) } }
        }
        .task(id: coverkey) {
            let requestedKey = coverkey
            covervideo = nil
            guard let t = engine.current, library.videourl(t.id) == nil,
                  library.data.overrides[t.id]?.artwork == nil else { return }
            let found = await AnimatedCovers.resolve(for: t, shown: library.shown(t), settings: settings, library: library)
            guard !Task.isCancelled, engine.current?.id == t.id, coverkey == requestedKey else {
                Log.i(.artwork, "ignored stale animated-cover result for \(t.id)")
                return
            }
            covervideo = found?.video
            if found?.fellback == true, library.animatedcoverorder(t.id) != nil, let provider = found?.provider {
                ToastCenter.shared.show("your preferred animated cover wasn't available, using \(provider) instead")
            }
        }
        .sheet(item: $sheet) { item in
            NavigationView {
                Group {
                    switch item {
                    case .source(let track): MappingView(track: track)
                    case .edit(let track): OverrideView(track: track)
                    case .speed: SpeedSheet()
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        if case .edit = item { EmptyView() }
                        else { Button("done") { sheet = nil } }
                    }
                }
            }
            .navigationViewStyle(.stack)
            .speedsheetsize(item)
        }
        .alert("hey! web playback sdk might be having issues.", isPresented: $showWebPlaybackHelp) {
            Button("test with effects") {
                settings.backend = .librespot
                ToastCenter.shared.show("switched to with effects. sign in under settings → spotify player if asked.")
            }
            Button("keep standard", role: .cancel) {}
        } message: {
            Text("wanna test librespot / with effects?")
        }
    }

    private func togglePlayback() {
        if settings.backend == .webplayback {
            let now = Date()
            webPlaybackTaps = webPlaybackTaps.filter { now.timeIntervalSince($0) < 8 }
            webPlaybackTaps.append(now)
            if webPlaybackTaps.count >= 5 {
                webPlaybackTaps.removeAll()
                showWebPlaybackHelp = true
            }
        } else { webPlaybackTaps.removeAll() }
        engine.toggle()
    }

    private var content: some View {
        GeometryReader { geometry in
            VStack(spacing: 12) {
                if let t = engine.current {
                    let s = library.shown(t)
                    NowPlayingArt(image: artimage, video: settings.showanimatedplayer ? (library.videourl(t.id) ?? covervideo) : nil, reducemotion: reducemotion)
                        .id(shownid)
                        .transition(.opacity)
                        .frame(width: geometry.size.width)
                        .frame(maxHeight: .infinity)          // the cover takes whatever height the controls leave, down to the tab bar

                    VStack(spacing: 14) {
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                AlbumLink(track: t) { Text(s.title).font(.title2.weight(.bold)).foregroundColor(fg).lineLimit(1) }
                                ArtistLink(track: t) { Text(s.artist).font(.headline).foregroundColor(sub).lineLimit(1) }
                            }
                            Spacer(minLength: 8)
                            Button { Haptic.tap(); withAnimation(.softspring) { library.toggleliked(t) } } label: {
                                Image(systemName: library.isliked(t.id) ? "heart.fill" : "heart")
                                    .font(.title2)
                                    .scaleEffect(library.isliked(t.id) ? 1.12 : 1)
                            }
                            .buttonStyle(PressableStyle())
                            .accessibilityLabel(library.isliked(t.id) ? "remove from liked songs" : "add to liked songs")
                            Menu {
                                if library.videourl(t.id) != nil || covervideo != nil {
                                    Button { settings.showanimatedplayer.toggle() } label: {
                                        Label(settings.showanimatedplayer ? "use still cover" : "use animated cover", systemImage: settings.showanimatedplayer ? "photo" : "play.rectangle")
                                    }
                                }
                                Menu("animated cover priority") {
                                    Button { library.setanimatedcoverorder(t.id, "canvas") } label: {
                                        if library.animatedcoverorder(t.id) == "canvas" { Label("spotify canvas first", systemImage: "checkmark") }
                                        else { Text("spotify canvas first") }
                                    }
                                    Button { library.setanimatedcoverorder(t.id, "apple") } label: {
                                        if library.animatedcoverorder(t.id) == "apple" { Label("apple music cover first", systemImage: "checkmark") }
                                        else { Text("apple music cover first") }
                                    }
                                    Button { library.setanimatedcoverorder(t.id, nil) } label: {
                                        if library.animatedcoverorder(t.id) == nil { Label("use app default", systemImage: "checkmark") }
                                        else { Text("use app default") }
                                    }
                                }
                                Button { sheet = .speed } label: { Label(String(format: "playback speed (%.2fx)", settings.speed), systemImage: "speedometer") }
                                Menu("reverb") {
                                    Button(settings.reverbon ? "turn reverb off" : "turn reverb on") { settings.reverbon.toggle(); if settings.reverbon { settings.backend = .librespot } }
                                    ForEach(reverbnames.indices, id: \.self) { index in
                                        Button { settings.reverbpreset = index; settings.reverbon = true; settings.backend = .librespot } label: {
                                            if settings.reverbon && settings.reverbpreset == index { Label(reverbnames[index], systemImage: "checkmark") }
                                            else { Text(reverbnames[index]) }
                                        }
                                    }
                                }
                                Button { sheet = .source(t) } label: { Label("audio source", systemImage: "waveform") }
                                Button { sheet = .edit(t) } label: { Label("edit song", systemImage: "pencil") }
                                if downloads.has(t) {
                                    Button { downloads.remove(t.id) } label: { Label("remove download", systemImage: "trash") }
                                } else {
                                    Button { Task { await downloads.download(t) } } label: { Label("download", systemImage: "arrow.down.circle") }
                                }
                                if let u = t.weburl { Button { UIApplication.shared.open(u) } label: { Label("open original", systemImage: "arrow.up.right.square") } }
                            } label: {
                                Image(systemName: "ellipsis.circle.fill").font(.title2).foregroundColor(fg.opacity(0.86))
                            }
                        }

                        VStack(spacing: 2) {
                            Slider(value: $scrub, in: 0...max(engine.duration, 1)) { editing in
                                dragging = editing
                                if !editing { engine.seek(scrub) }
                            }
                            HStack { Text(fmttime(dragging ? scrub : engine.position)); Spacer(); Text(fmttime(engine.duration)) }.font(.caption).foregroundColor(sub)
                        }
                        .onReceive(engine.$position) { if !dragging { scrub = $0 } }

                        HStack(spacing: 56) {
                            Button { Haptic.tap(); engine.previous() } label: { Image(systemName: "backward.fill").font(.system(size: 28)) }.buttonStyle(PressableStyle())
                            Button { Haptic.firm(); togglePlayback() } label: {
                                Image(systemName: engine.isplaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 34, weight: .semibold))
                                    .frame(width: 62, height: 62)
                            }
                            .buttonStyle(PressableStyle(scale: 0.9))
                            Button { Haptic.tap(); engine.next() } label: { Image(systemName: "forward.fill").font(.system(size: 28)) }.buttonStyle(PressableStyle())
                        }

                        HStack(spacing: 10) {
                            Image(systemName: "speaker.fill").font(.caption).foregroundColor(sub)
                            SystemVolumeSlider().frame(height: 24)
                            Image(systemName: "speaker.wave.3.fill").font(.caption).foregroundColor(sub)
                        }
                        .accessibilityElement(children: .contain)

                        HStack {
                            Button { Haptic.select(); withAnimation(.softspring) { settings.cyclerepeat() } } label: {
                                Image(systemName: settings.repeatmode == "one" ? "repeat.1" : "repeat").foregroundColor(settings.repeatmode == "off" ? sub : palette.accent)
                            }
                            Spacer()
                            NavigationLink(destination: LyricsView()) { Image(systemName: "quote.bubble").font(.title3) }
                            Spacer()
                            AddToPlaylistMenu(track: t) { Image(systemName: "text.badge.plus").font(.title3) }
                            Spacer()
                            NavigationLink(destination: QueueView()) { Image(systemName: "list.bullet").font(.title3) }
                            Spacer()
                            NavigationLink(destination: SearchView()) { Image(systemName: "magnifyingglass").font(.title3) }
                        }
                        .foregroundColor(fg)
                        .padding(.horizontal, 20)
                    }
                    .padding(.horizontal, 24)
                    Color.clear.frame(height: 10)             // the small gap between the controls and the tab bar
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "music.note").font(.system(size: 56)).foregroundColor(sub)
                        Text("nothing playing").font(.title3.weight(.semibold)).foregroundColor(fg)
                        Text("search for something, or pick it from your library").foregroundColor(sub).multilineTextAlignment(.center)
                        NavigationLink(destination: SearchView()) { Label("search", systemImage: "magnifyingglass").font(.headline) }.padding(.top, 8)
                    }
                    .padding(.top, 100)
                    .padding(.horizontal, 20)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: geometry.size.height, alignment: .top)
        }
        .ignoresSafeArea(edges: .top)
    }
}

private struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        // Keep this row slider-only; AirPlay routing already lives in the system Now Playing UI.
        view.subviews.compactMap { $0 as? UIButton }.forEach { $0.isHidden = true }
        return view
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

// speed as a slider (0.5x to 2x) instead of preset steps
private struct SpeedSheet: View {
    @EnvironmentObject var settings: Settings
    var body: some View {
        VStack(spacing: 18) {
            Text(String(format: "%.2fx", settings.speed)).font(.system(size: 44, weight: .bold, design: .rounded)).monospacedDigit()
            HStack(spacing: 10) {
                Text("0.5x").font(.caption).foregroundColor(.secondary)
                Slider(value: $settings.speed, in: 0.5...2.0, step: 0.05)
                Text("2x").font(.caption).foregroundColor(.secondary)
            }
            Button("reset to 1.00x") { settings.speed = 1 }.disabled(abs(settings.speed - 1) < 0.001)
            Spacer(minLength: 0)
        }
        .padding(24)
        .navigationTitle("playback speed")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private extension View {
    @ViewBuilder func speedsheetsize(_ item: PlayerSheet) -> some View {
        if case .speed = item { compactdetent() } else { self }
    }

    @ViewBuilder private func compactdetent() -> some View {
        if #available(iOS 16.0, *) { self.presentationDetents([.height(300)]) } else { self }
    }
}

// colours for the Now Playing screen only. the accent comes from the cover, then is pushed lighter (dark UI) or darker
// (light UI) until it reaches 4.5:1 against the background it is actually drawn on (theme background + cover tint).
struct NowPlayingPalette {
    let accent: Color
    let tint: Color?          // cover colour used for the background wash
    let tintalpha: Double

    init(art: UIColor?, dark: Bool, amoled: Bool, fallback: Color) {
        let alpha = dark ? 0.30 : 0.16
        tintalpha = alpha
        guard let art = art else { accent = fallback; tint = nil; return }
        tint = Color(art)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        art.getRed(&r, green: &g, blue: &b, alpha: &a)
        // background the accent sits on: base colour blended with the cover colour at `alpha`
        let base: Double = dark ? (amoled ? 0 : 0.07) : 0.95
        let br = base * (1 - alpha) + Double(r) * alpha, bg = base * (1 - alpha) + Double(g) * alpha, bb = base * (1 - alpha) + Double(b) * alpha
        let bgl = Settings.relluminance(br, bg, bb)
        var h: CGFloat = 0, sat: CGFloat = 0, br0: CGFloat = 0
        art.getHue(&h, saturation: &sat, brightness: &br0, alpha: &a)
        // keep the hue, make it vivid enough to read as an accent
        let c = UIColor(hue: h, saturation: min(1, max(sat, 0.45)), brightness: dark ? max(br0, 0.75) : min(br0, 0.45), alpha: 1)
        var cr: CGFloat = 0, cg: CGFloat = 0, cb: CGFloat = 0
        c.getRed(&cr, green: &cg, blue: &cb, alpha: &a)
        let toward: Double = dark ? 1 : 0
        var rr = Double(cr), gg = Double(cg), bb2 = Double(cb), t = 0.0
        while t < 1, Settings.contrast(Settings.relluminance(rr, gg, bb2), bgl) < 4.5 {
            t = min(1, t + 0.05)
            rr = Double(cr) + (toward - Double(cr)) * t; gg = Double(cg) + (toward - Double(cg)) * t; bb2 = Double(cb) + (toward - Double(cb)) * t
        }
        accent = Color(.sRGB, red: rr, green: gg, blue: bb2, opacity: 1)
    }
}

// the big artwork. natural aspect ratio is kept (fit, never stretched, never cropped) at full screen width, and the top and
// bottom edges fade into the background. animated artwork plays muted and looping in the same frame; with reduced motion
// (or no video) the static image / first frame is shown. sized with aspectRatio, so it can't overflow the screen width.
struct NowPlayingArt: View {
    let image: UIImage?
    let video: URL?
    let reducemotion: Bool
    @Environment(\.scenePhase) private var phase

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                    if let i = image {
                        Image(uiImage: i).resizable().scaledToFill()
                            .frame(width: proxy.size.width, height: proxy.size.height).clipped()
                        if let v = video, !reducemotion, phase == .active { LoopingVideoView(url: v, playing: true) }
                    } else {
                        ZStack { Color.gray.opacity(0.18); Image(systemName: "music.note").font(.system(size: 64)).foregroundColor(.secondary) }
                    }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .overlay(alignment: .top) { LinearGradient(colors: [.black.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom).frame(height: 110) }
        }
        .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.55), .init(color: .black.opacity(0.7), location: 0.75), .init(color: .black.opacity(0.3), location: 0.9), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
        .accessibilityHidden(true)
    }
}

// subtle background derived from the artwork: the cover colour at low strength over the theme background, plus a very soft
// blurred copy of the image, then a scrim toward the bottom so the controls always sit on a calm, dark (or pale) area.
struct NowPlayingBackground: View {
    let image: UIImage?
    let palette: NowPlayingPalette
    let reducemotion: Bool
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject var settings: Settings

    var body: some View {
        ZStack {
            settings.background
            if let c = palette.tint { c.opacity(palette.tintalpha) }
            if let i = image {
                Color.clear.overlay(Image(uiImage: i).resizable().scaledToFill().blur(radius: 60).opacity(scheme == .dark ? 0.14 : 0.08)).clipped()
            }
            LinearGradient(colors: [settings.background.opacity(0), settings.background.opacity(0.7)], startPoint: .center, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .animation(reducemotion ? nil : .easeInOut(duration: 0.5), value: palette.tintalpha)
        .accessibilityHidden(true)
    }
}
