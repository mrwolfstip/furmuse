import SwiftUI
import Combine

final class Settings: ObservableObject {
    static let defaultcanvasurl = "https://spotify-canva.vercel.app"
    private let d = UserDefaults.standard
    private func k(_ s: String) -> String { "wolfified.pref." + s }
    private func get<T>(_ key: String, _ def: T) -> T { d.object(forKey: k(key)) as? T ?? def }
    private func put(_ v: Any, _ key: String) { d.set(v, forKey: k(key)) }

    @Published var thememode = "system" { didSet { put(thememode, "thememode") } }
    @Published var accentr = 0.08 { didSet { put(accentr, "accentr") } }
    @Published var accentg = 0.62 { didSet { put(accentg, "accentg") } }
    @Published var accentb = 0.88 { didSet { put(accentb, "accentb") } }
    @Published var speed = 1.0 { didSet { put(speed, "speed") } }
    @Published var pitchlock = false { didSet { put(pitchlock, "pitchlock") } }
    @Published var pitchsemis = 0 { didSet { put(pitchsemis, "pitchsemis") } }
    @Published var volume = 1.0 { didSet { put(volume, "volume") } }
    @Published var eqon = false { didSet { put(eqon, "eqon") } }
    @Published var eq: [Double] = [0, 0, 0, 0, 0] { didSet { put(eq, "eq") } }
    @Published var bass = 0.0 { didSet { put(bass, "bass") } }
    @Published var reverbon = false { didSet { put(reverbon, "reverbon") } }
    @Published var reverbpreset = 3 { didSet { put(reverbpreset, "reverbpreset") } }
    @Published var reverbmix = 25.0 { didSet { put(reverbmix, "reverbmix") } }
    // loop mode: "off", "all" (loop the playlist / queue) or "one"
    @Published var repeatmode = "off" { didSet { put(repeatmode, "repeatmode") } }
    func cyclerepeat() { repeatmode = repeatmode == "off" ? "all" : (repeatmode == "all" ? "one" : "off") }
    @Published var defaultsource = "youtube" { didSet { put(defaultsource, "defaultsource") } }
    @Published var sourceorder = "youtube" { didSet { put(sourceorder, "sourceorder") } }
    @Published var endpointurl = "" { didSet { put(endpointurl, "endpointurl") } }
    @Published var offlineonly = false { didSet { put(offlineonly, "offlineonly") } }
    @Published var preferdownloads = true { didSet { put(preferdownloads, "preferdownloads") } }
    @Published var wifionly = true { didSet { put(wifionly, "wifionly") } }
    @Published var lyricson = true { didSet { put(lyricson, "lyricson") } }
    @Published var lyricsnet = true { didSet { put(lyricsnet, "lyricsnet") } }
    @Published var lyricswords = true { didSet { put(lyricswords, "lyricswords") } }
    @Published var lyricsfake = true { didSet { put(lyricsfake, "lyricsfake") } }       // estimate word timing for line-synced lyrics
    @Published var lyricsmore = true { didSet { put(lyricsmore, "lyricsmore") } }       // also try netease, qq music and kugou
    @Published var lyricssize = 22.0 { didSet { put(lyricssize, "lyricssize") } }
    @Published var toastson = true { didSet { put(toastson, "toastson") } }
    @Published var applecovers = true { didSet { put(applecovers, "applecovers") } }
    @Published var applecoversurl = "https://artwork.m8tec.top" { didSet { put(applecoversurl, "applecoversurl") } }
    @Published var spotifycanvas = true { didSet { put(spotifycanvas, "spotifycanvas") } }
    @Published var spotifycanvasurl = Settings.defaultcanvasurl { didSet { put(spotifycanvasurl, "spotifycanvasurl") } }
    @Published var animatedcoverorder = "canvas" { didSet { put(animatedcoverorder, "animatedcoverorder") } }
    @Published var askforsource = true { didSet { put(askforsource, "askforsource") } }      // search: confirm the youtube source before adding / playing
    @Published var animatestatic = true { didSet { put(animatestatic, "animatestatic") } }   // lock screen: animate still covers (iOS 26)
    @Published var lockscreenlyrics = false { didSet { put(lockscreenlyrics, "lockscreenlyrics") } }
    @Published var legacyiconunlocked = false { didSet { put(legacyiconunlocked, "legacyiconunlocked") } }
    @Published var showanimatedplayer = true { didSet { put(showanimatedplayer, "showanimatedplayer") } }
    // lyric card design, remembered between cards. cardbg is solid, cover or artist; cardblur is a gaussian radius in points on the 1080 px card
    @Published var cardbg = "cover" { didSet { put(cardbg, "cardbg") } }
    @Published var cardblur = 60.0 { didSet { put(cardblur, "cardblur") } }
    @Published var cardshade = 0.40 { didSet { put(cardshade, "cardshade") } }
    @Published var cardsize = 60.0 { didSet { put(cardsize, "cardsize") } }
    @Published var cardbrand = true { didSet { put(cardbrand, "cardbrand") } }
    @Published var cardcolor = "#000000" { didSet { put(cardcolor, "cardcolor") } }
    // which engine plays the spotify source: the web playback sdk (default) or librespot (optional alternative)
    @Published var spotifybackendraw = SpotifyBackend.webplayback.rawValue { didSet { put(spotifybackendraw, "spotifybackend") } }
    var backend: SpotifyBackend {
        get { SpotifyBackend(rawValue: spotifybackendraw) ?? .webplayback }
        set { spotifybackendraw = newValue.rawValue }
    }

    init() { load() }

    private func load() {
        // Remove preferences and the local file from the short-lived wallpaper experiment.
        if let old = d.string(forKey: k("wallpaperfile")), !old.isEmpty { ArtworkStore.remove(old) }
        for oldkey in ["wallpaperfile", "wallpaperblur", "wallpaperdark"] { d.removeObject(forKey: k(oldkey)) }
        thememode = get("thememode", "system")
        accentr = get("accentr", 0.08); accentg = get("accentg", 0.62); accentb = get("accentb", 0.88)
        speed = get("speed", 1.0); pitchlock = get("pitchlock", false); pitchsemis = get("pitchsemis", 0)
        volume = get("volume", 1.0); eqon = get("eqon", false)
        let e: [Double] = get("eq", [0, 0, 0, 0, 0]); eq = e.count == 5 ? e : [0, 0, 0, 0, 0]
        bass = get("bass", 0.0); reverbon = get("reverbon", false); reverbpreset = get("reverbpreset", 3)
        reverbmix = get("reverbmix", 25.0); repeatmode = get("repeatmode", get("repeatone", false) ? "one" : "off")
        defaultsource = get("defaultsource", "youtube")
        sourceorder = get("sourceorder", "youtube"); endpointurl = get("endpointurl", "")
        offlineonly = get("offlineonly", false); preferdownloads = get("preferdownloads", true)
        wifionly = get("wifionly", true); lyricson = get("lyricson", true); lyricsnet = get("lyricsnet", true)
        lyricswords = get("lyricswords", true); lyricsfake = get("lyricsfake", true); lyricsmore = get("lyricsmore", true); lyricssize = get("lyricssize", 22.0)
        toastson = get("toastson", true)
        animatestatic = get("animatestatic", true)
        lockscreenlyrics = get("lockscreenlyrics", false)
        legacyiconunlocked = get("legacyiconunlocked", false)
        showanimatedplayer = get("showanimatedplayer", true)
        cardbg = get("cardbg", "cover"); cardblur = get("cardblur", 60.0); cardshade = get("cardshade", 0.40)
        cardsize = get("cardsize", 60.0); cardbrand = get("cardbrand", true); cardcolor = get("cardcolor", "#000000")
        askforsource = get("askforsource", true)
        spotifybackendraw = get("spotifybackend", SpotifyBackend.webplayback.rawValue)
        applecovers = get("applecovers", true); applecoversurl = get("applecoversurl", "https://artwork.m8tec.top")
        spotifycanvas = get("spotifycanvas", true)
        spotifycanvasurl = get("spotifycanvasurl", Settings.defaultcanvasurl)
        animatedcoverorder = get("animatedcoverorder", "canvas")
        if spotifycanvasurl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { spotifycanvasurl = Settings.defaultcanvasurl }
    }

    func resetall() {
        for key in d.dictionaryRepresentation().keys where key.hasPrefix("wolfified.pref.") { d.removeObject(forKey: key) }
        thememode = "system"; accentr = 0.08; accentg = 0.62; accentb = 0.88; speed = 1; pitchlock = false; pitchsemis = 0
        volume = 1; eqon = false; eq = [0, 0, 0, 0, 0]; bass = 0; reverbon = false; reverbpreset = 3; reverbmix = 25
        repeatmode = "off"; defaultsource = "youtube"; sourceorder = "youtube"; endpointurl = ""; offlineonly = false; preferdownloads = true
        wifionly = true; lyricson = true; lyricsnet = true; lyricswords = true; lyricsfake = true; lyricsmore = true; lyricssize = 22
        toastson = true; animatestatic = true; lockscreenlyrics = false; legacyiconunlocked = false; showanimatedplayer = true; askforsource = true; applecovers = true; applecoversurl = "https://artwork.m8tec.top"
        spotifycanvas = true; spotifycanvasurl = Settings.defaultcanvasurl; animatedcoverorder = "canvas"
        spotifybackendraw = SpotifyBackend.webplayback.rawValue
        cardbg = "cover"; cardblur = 60; cardshade = 0.40; cardsize = 60; cardbrand = true; cardcolor = "#000000"
        if UIApplication.shared.supportsAlternateIcons { UIApplication.shared.setAlternateIconName(nil) }
    }

    var colorscheme: ColorScheme? {
        switch thememode {
        case "light": return .light
        case "dark", "amoled": return .dark
        default: return nil
        }
    }

    var amoled: Bool { thememode == "amoled" }
    var background: Color { amoled ? .black : Color(UIColor.systemGroupedBackground) }
    var luminance: Double { 0.299 * accentr + 0.587 * accentg + 0.114 * accentb }

    var accentcolor: Color { Color(.sRGB, red: accentr, green: accentg, blue: accentb, opacity: 1) }

    var accentbinding: Binding<Color> {
        Binding(
            get: { self.accentcolor },
            set: { c in
                var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
                UIColor(c).getRed(&r, green: &g, blue: &b, alpha: &a)
                self.accentr = Double(r); self.accentg = Double(g); self.accentb = Double(b)
            }
        )
    }

    func setaccent(_ r: Double, _ g: Double, _ b: Double) { accentr = r; accentg = g; accentb = b }

    // ---- accent contrast -------------------------------------------------------------------------------------------
    // the user's accent is a preference, but it has to stay usable: tint() nudges it toward white (dark UI) or black (light UI)
    // until it reaches 4.5:1 against the screen background, which covers text, sliders, progress, toggles and selected
    // controls. onaccent() is the readable foreground for anything filled with the accent.
    private static func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    static func relluminance(_ r: Double, _ g: Double, _ b: Double) -> Double { 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b) }
    static func contrast(_ l1: Double, _ l2: Double) -> Double { (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05) }

    private func backgroundluminance(_ scheme: ColorScheme) -> Double {
        if scheme == .dark { return amoled ? 0 : 0.012 }
        return 0.88   // systemGroupedBackground (light) is about #F2F2F7 = 0.89
    }

    func tintrgb(_ scheme: ColorScheme, target: Double = 4.5) -> (Double, Double, Double) {
        var r = accentr, g = accentg, b = accentb
        let bg = backgroundluminance(scheme)
        let toward: Double = scheme == .dark ? 1 : 0
        var t = 0.0
        while t < 1, Settings.contrast(Settings.relluminance(r, g, b), bg) < target {
            t = min(1, t + 0.05)
            r = accentr + (toward - accentr) * t; g = accentg + (toward - accentg) * t; b = accentb + (toward - accentb) * t
        }
        return (r, g, b)
    }

    func tint(_ scheme: ColorScheme) -> Color {
        let (r, g, b) = tintrgb(scheme)
        return Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }

    // foreground for content drawn on top of a tint-filled shape (e.g. a filled button): black or white, whichever reads better
    func onaccent(_ scheme: ColorScheme) -> Color {
        let (r, g, b) = tintrgb(scheme)
        let l = Settings.relluminance(r, g, b)
        return Settings.contrast(l, 0) >= Settings.contrast(l, 1) ? .black : .white
    }

    // dimmer accent for secondary fills (tracks, unselected states) that still keeps 3:1 for non-text UI
    func tintsoft(_ scheme: ColorScheme) -> Color {
        let (r, g, b) = tintrgb(scheme, target: 3)
        return Color(.sRGB, red: r, green: g, blue: b, opacity: 0.55)
    }

    static func styleuikit() {
        UITableView.appearance().backgroundColor = .clear
        UICollectionView.appearance().backgroundColor = .clear
        let scroll = UINavigationBarAppearance()
        scroll.configureWithTransparentBackground()
        scroll.backgroundEffect = nil
        scroll.backgroundColor = .clear
        scroll.shadowColor = .clear
        UINavigationBar.appearance().standardAppearance = scroll
        UINavigationBar.appearance().scrollEdgeAppearance = scroll
        UINavigationBar.appearance().compactAppearance = scroll
        UINavigationBar.appearance().isTranslucent = true
        let tab = UITabBarAppearance()
        tab.configureWithTransparentBackground()
        tab.backgroundEffect = nil
        tab.backgroundColor = .clear
        tab.shadowColor = .clear
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
        UITabBar.appearance().isTranslucent = true
    }
}

struct ThemedScreen: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content
                .scrollContentBackground(.hidden)
                .toolbarBackground(.hidden, for: .navigationBar)
                .background(AeroBackdrop().ignoresSafeArea())
        } else {
            content.background(AeroBackdrop().ignoresSafeArea())
        }
    }
}

// Screen chrome is deliberately neutral. Album artwork supplies colour where it is meaningful;
// a permanent blue wash made every library and settings screen look unrelated to its content.
struct AeroBackdrop: View {
    var body: some View {
        Color(uiColor: .systemBackground).accessibilityHidden(true)
    }
}

private struct AeroGlassCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(LinearGradient(colors: [.white.opacity(0.72), .white.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
            .shadow(color: .cyan.opacity(0.12), radius: 18, x: 0, y: 8)
    }
}

extension View {
    func themed() -> some View { modifier(ThemedScreen()) }
    func aeroCard() -> some View { modifier(AeroGlassCard()) }
}
