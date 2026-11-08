import SwiftUI
import Combine
import CoreText

final class Settings: ObservableObject {
    static let defaultcanvasurl = "https://spotify-canva.vercel.app"
    private let d = UserDefaults.standard
    private func k(_ s: String) -> String { "wolfified.pref." + s }
    private func get<T>(_ key: String, _ def: T) -> T { d.object(forKey: k(key)) as? T ?? def }
    private func put(_ v: Any, _ key: String) { d.set(v, forKey: k(key)) }

    @Published var thememode = "dark" { didSet { put(thememode, "thememode") } }
    @Published private(set) var customfontname = ""
    @Published private(set) var customfontfile = "" { didSet { put(customfontfile, "customfontfile") } }
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
    @Published var youtubebackendraw = YouTubeBackend.standard.rawValue { didSet { put(youtubebackendraw, "youtubebackend") } }
    var youtubebackend: YouTubeBackend {
        get { YouTubeBackend(rawValue: youtubebackendraw) ?? .standard }
        set { youtubebackendraw = newValue.rawValue }
    }
    @Published var endpointurl = "" { didSet { put(endpointurl, "endpointurl") } }
    @Published var offlineonly = false { didSet { put(offlineonly, "offlineonly") } }
    @Published var preferdownloads = true { didSet { put(preferdownloads, "preferdownloads") } }
    @Published var wifionly = true { didSet { put(wifionly, "wifionly") } }
    @Published var lyricson = true { didSet { put(lyricson, "lyricson") } }
    @Published var lyricsnet = true { didSet { put(lyricsnet, "lyricsnet") } }
    @Published var lyricswords = true { didSet { put(lyricswords, "lyricswords") } }
    @Published var lyricsfake = true { didSet { put(lyricsfake, "lyricsfake") } }       // estimate word timing for line-synced lyrics
    @Published var lyricsmore = true { didSet { put(lyricsmore, "lyricsmore") } }       // also try netease, qq music and kugou
    @Published var spicycommunity = true { didSet { put(spicycommunity, "spicycommunity") } }
    @Published var spicyapple = true { didSet { put(spicyapple, "spicyapple") } }
    @Published var spicyspotify = true { didSet { put(spicyspotify, "spicyspotify") } }
    @Published var lyricsproviderorder: [String] = ["spicy", "lrclib", "netease", "qq", "kugou"] { didSet { put(lyricsproviderorder, "lyricsproviderorder") } }
    @Published var lyricsdisabledproviders: [String] = [] { didSet { put(lyricsdisabledproviders, "lyricsdisabledproviders") } }
    @Published var lyricssize = 22.0 { didSet { put(lyricssize, "lyricssize") } }
    @Published var lyricsstyle = "classic" { didSet { put(lyricsstyle, "lyricsstyle") } } // classic or laser
    @Published var lyricsromanize = false { didSet { put(lyricsromanize, "lyricsromanize") } }
    @Published var lyricsromanstyle = "replace" { didSet { put(lyricsromanstyle, "lyricsromanstyle") } }   // replace, below or current
    @Published var lyricsbackground = "automatic" { didSet { put(lyricsbackground, "lyricsbackground") } } // automatic, canvas or cover
    @Published var lyricsbackdropblur = 34.0 { didSet { put(lyricsbackdropblur, "lyricsbackdropblur") } }
    @Published var lyricsbackdropshade = 0.42 { didSet { put(lyricsbackdropshade, "lyricsbackdropshade") } }
    @Published var lyricsbackdropsaturation = 1.20 { didSet { put(lyricsbackdropsaturation, "lyricsbackdropsaturation") } }
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
        // Existing users keep their saved choice; only an install with no theme preference starts dark.
        thememode = get("thememode", "dark")
        customfontfile = get("customfontfile", "")
        loadcustomfont()
        accentr = get("accentr", 0.08); accentg = get("accentg", 0.62); accentb = get("accentb", 0.88)
        speed = get("speed", 1.0); pitchlock = get("pitchlock", false); pitchsemis = get("pitchsemis", 0)
        volume = get("volume", 1.0); eqon = get("eqon", false)
        let e: [Double] = get("eq", [0, 0, 0, 0, 0]); eq = e.count == 5 ? e : [0, 0, 0, 0, 0]
        bass = get("bass", 0.0); reverbon = get("reverbon", false); reverbpreset = get("reverbpreset", 3)
        reverbmix = get("reverbmix", 25.0); repeatmode = get("repeatmode", get("repeatone", false) ? "one" : "off")
        defaultsource = get("defaultsource", "youtube")
        sourceorder = get("sourceorder", "youtube"); endpointurl = get("endpointurl", "")
        youtubebackendraw = get("youtubebackend", YouTubeBackend.standard.rawValue)
        offlineonly = get("offlineonly", false); preferdownloads = get("preferdownloads", true)
        wifionly = get("wifionly", true); lyricson = get("lyricson", true); lyricsnet = get("lyricsnet", true)
        lyricswords = get("lyricswords", true); lyricsfake = get("lyricsfake", true); lyricsmore = get("lyricsmore", true); lyricssize = get("lyricssize", 22.0)
        spicycommunity = get("spicycommunity", true); spicyapple = get("spicyapple", true); spicyspotify = get("spicyspotify", true)
        let defaultProviders = ["spicy", "lrclib", "netease", "qq", "kugou"]
        let savedOrder: [String] = get("lyricsproviderorder", [])
        lyricsproviderorder = savedOrder.isEmpty ? defaultProviders : savedOrder + defaultProviders.filter { !savedOrder.contains($0) }
        lyricsdisabledproviders = get("lyricsdisabledproviders", lyricsmore ? [] : ["netease", "qq", "kugou"])
        let savedLyricsStyle: String = get("lyricsstyle", "classic")
        lyricsstyle = ["classic", "laser"].contains(savedLyricsStyle) ? savedLyricsStyle : "classic"
        lyricsromanize = get("lyricsromanize", false)
        lyricsromanstyle = get("lyricsromanstyle", "replace")
        let savedLyricsBackground: String = get("lyricsbackground", "automatic")
        lyricsbackground = ["automatic", "canvas", "cover"].contains(savedLyricsBackground) ? savedLyricsBackground : "automatic"
        lyricsbackdropblur = get("lyricsbackdropblur", 34.0)
        lyricsbackdropshade = get("lyricsbackdropshade", 0.42)
        lyricsbackdropsaturation = get("lyricsbackdropsaturation", 1.20)
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
        thememode = "dark"; accentr = 0.08; accentg = 0.62; accentb = 0.88; speed = 1; pitchlock = false; pitchsemis = 0
        removecustomfont()
        volume = 1; eqon = false; eq = [0, 0, 0, 0, 0]; bass = 0; reverbon = false; reverbpreset = 3; reverbmix = 25
        repeatmode = "off"; defaultsource = "youtube"; sourceorder = "youtube"; youtubebackendraw = YouTubeBackend.standard.rawValue; endpointurl = ""; offlineonly = false; preferdownloads = true
        wifionly = true; lyricson = true; lyricsnet = true; lyricswords = true; lyricsfake = true; lyricsmore = true; spicycommunity = true; spicyapple = true; spicyspotify = true; lyricsproviderorder = ["spicy", "lrclib", "netease", "qq", "kugou"]; lyricsdisabledproviders = []; lyricssize = 22; lyricsstyle = "classic"; lyricsromanize = false; lyricsromanstyle = "replace"; lyricsbackground = "automatic"; lyricsbackdropblur = 34; lyricsbackdropshade = 0.42; lyricsbackdropsaturation = 1.20
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

    var appfont: Font? {
        customfontname.isEmpty ? nil : .custom(customfontname, size: 17, relativeTo: .body)
    }

    var customfontlabel: String {
        customfontname.isEmpty ? "system default" : customfontname
    }

    func installcustomfont(from source: URL) throws {
        let ext = source.pathExtension.lowercased()
        guard ["ttf", "otf", "ott"].contains(ext) else { throw CustomFontError.unsupported }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let folder = try customfontfolder()
        let destination = folder.appendingPathComponent("app-font-\(UUID().uuidString).\(ext)")
        let manager = FileManager.default
        try manager.copyItem(at: source, to: destination)

        do {
            let name = try fontname(at: destination)
            let oldURL = customfontfile.isEmpty ? nil : folder.appendingPathComponent(customfontfile)
            if let oldURL { CTFontManagerUnregisterFontsForURL(oldURL as CFURL, .process, nil) }
            do {
                try registercustomfont(at: destination)
            } catch {
                if let oldURL { try? registercustomfont(at: oldURL) }
                throw error
            }
            if let oldURL { try? manager.removeItem(at: oldURL) }
            customfontfile = destination.lastPathComponent
            customfontname = name
            applycustomfonttouikit()
        } catch {
            try? manager.removeItem(at: destination)
            throw error
        }
    }

    func removecustomfont() {
        if !customfontfile.isEmpty, let folder = try? customfontfolder() {
            let url = folder.appendingPathComponent(customfontfile)
            CTFontManagerUnregisterFontsForURL(url as CFURL, .process, nil)
            try? FileManager.default.removeItem(at: url)
        }
        customfontfile = ""
        customfontname = ""
        applycustomfonttouikit()
    }

    private func loadcustomfont() {
        guard !customfontfile.isEmpty, let folder = try? customfontfolder() else { return }
        let url = folder.appendingPathComponent(customfontfile)
        guard FileManager.default.fileExists(atPath: url.path),
              let name = try? fontname(at: url),
              (try? registercustomfont(at: url)) != nil else {
            customfontfile = ""
            return
        }
        customfontname = name
        applycustomfonttouikit()
    }

    private func customfontfolder() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let folder = base.appendingPathComponent("Furmuse/CustomFont", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func fontname(at url: URL) throws -> String {
        guard let provider = CGDataProvider(url: url as CFURL),
              let cgfont = CGFont(provider),
              let name = cgfont.postScriptName as String?, !name.isEmpty else { throw CustomFontError.invalid }
        return name
    }

    private func registercustomfont(at url: URL) throws {
        var unmanagedError: Unmanaged<CFError>?
        let registered = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &unmanagedError)
        if !registered {
            let error = unmanagedError?.takeRetainedValue()
            // Registering an already active font returns false, but it is still usable.
            if (error as Error?)?._code != CTFontManagerError.alreadyRegistered.rawValue { throw CustomFontError.invalid }
        }
    }

    private func applycustomfonttouikit() {
        let body = customfontname.isEmpty ? UIFont.systemFont(ofSize: 10, weight: .semibold) : UIFont(name: customfontname, size: 10)
        let control = customfontname.isEmpty ? UIFont.systemFont(ofSize: 15, weight: .semibold) : UIFont(name: customfontname, size: 15)
        let menu = customfontname.isEmpty ? UIFont.systemFont(ofSize: 17) : UIFont(name: customfontname, size: 17)
        let title = customfontname.isEmpty ? UIFont.systemFont(ofSize: 17, weight: .semibold) : UIFont(name: customfontname, size: 17)
        let large = customfontname.isEmpty ? UIFont.systemFont(ofSize: 34, weight: .bold) : UIFont(name: customfontname, size: 34)
        if let menu {
            // SwiftUI menus, confirmation dialogs and alerts are rendered by UIKit and do not
            // inherit SwiftUI's font environment. Their visible titles are UILabel-backed.
            UILabel.appearance().font = menu
            UIBarButtonItem.appearance().setTitleTextAttributes([.font: menu], for: .normal)
            UIBarButtonItem.appearance().setTitleTextAttributes([.font: menu], for: .highlighted)
        }
        if let control {
            UISegmentedControl.appearance().setTitleTextAttributes([.font: control], for: .normal)
            UISegmentedControl.appearance().setTitleTextAttributes([.font: control], for: .selected)
        }
        if let body {
            UITabBarItem.appearance().setTitleTextAttributes([.font: body], for: .normal)
            UITabBarItem.appearance().setTitleTextAttributes([.font: body], for: .selected)
            let tabbar = UITabBar.appearance()
            for appearance in [tabbar.standardAppearance, tabbar.scrollEdgeAppearance].compactMap({ $0 }) {
                for item in [appearance.stackedLayoutAppearance, appearance.inlineLayoutAppearance, appearance.compactInlineLayoutAppearance] {
                    item.normal.titleTextAttributes[.font] = body
                    item.selected.titleTextAttributes[.font] = body
                }
            }
        }
        let navbar = UINavigationBar.appearance()
        for appearance in [navbar.standardAppearance, navbar.scrollEdgeAppearance, navbar.compactAppearance].compactMap({ $0 }) {
            if let title { appearance.titleTextAttributes[.font] = title }
            if let large { appearance.largeTitleTextAttributes[.font] = large }
        }
    }

    private enum CustomFontError: LocalizedError {
        case unsupported, invalid
        var errorDescription: String? {
            switch self {
            case .unsupported: return "choose a .ttf, .otf or .ott font file"
            case .invalid: return "that file doesn't contain a font this device can use"
            }
        }
    }

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

private struct AppFontNameKey: EnvironmentKey {
    static let defaultValue = ""
}

extension EnvironmentValues {
    var appFontName: String {
        get { self[AppFontNameKey.self] }
        set { self[AppFontNameKey.self] = newValue }
    }
}

struct AppFontSpec {
    private let fallback: Font
    private let size: CGFloat
    private let relativeTo: Font.TextStyle?
    private var weight: Font.Weight?
    private var italicized = false
    private var monospaced = false

    private init(_ fallback: Font, size: CGFloat, relativeTo: Font.TextStyle?, weight: Font.Weight? = nil) {
        self.fallback = fallback
        self.size = size
        self.relativeTo = relativeTo
        self.weight = weight
    }

    static let largeTitle = AppFontSpec(.largeTitle, size: 34, relativeTo: .largeTitle)
    static let title = AppFontSpec(.title, size: 28, relativeTo: .title)
    static let title2 = AppFontSpec(.title2, size: 22, relativeTo: .title2)
    static let title3 = AppFontSpec(.title3, size: 20, relativeTo: .title3)
    static let headline = AppFontSpec(.headline, size: 17, relativeTo: .headline, weight: .semibold)
    static let body = AppFontSpec(.body, size: 17, relativeTo: .body)
    static let callout = AppFontSpec(.callout, size: 16, relativeTo: .callout)
    static let subheadline = AppFontSpec(.subheadline, size: 15, relativeTo: .subheadline)
    static let footnote = AppFontSpec(.footnote, size: 13, relativeTo: .footnote)
    static let caption = AppFontSpec(.caption, size: 12, relativeTo: .caption)
    static let caption2 = AppFontSpec(.caption2, size: 11, relativeTo: .caption2)

    static func system(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> AppFontSpec {
        AppFontSpec(.system(size: size, weight: weight, design: design), size: size, relativeTo: nil, weight: weight)
    }

    func weight(_ value: Font.Weight) -> AppFontSpec {
        var copy = self
        copy.weight = value
        return copy
    }

    func bold() -> AppFontSpec { weight(.bold) }

    func italic() -> AppFontSpec {
        var copy = self
        copy.italicized = true
        return copy
    }

    func monospacedDigit() -> AppFontSpec {
        var copy = self
        copy.monospaced = true
        return copy
    }

    fileprivate func resolve(name: String) -> Font {
        guard !name.isEmpty else { return fallback }
        var font = relativeTo.map { Font.custom(name, size: size, relativeTo: $0) } ?? Font.custom(name, fixedSize: size)
        if let weight { font = font.weight(weight) }
        if italicized { font = font.italic() }
        if monospaced { font = font.monospacedDigit() }
        return font
    }
}

private struct AppFontModifier: ViewModifier {
    @Environment(\.appFontName) private var name
    let spec: AppFontSpec
    func body(content: Content) -> some View {
        content.font(spec.resolve(name: name))
    }
}

extension View {
    func appFont(_ spec: AppFontSpec) -> some View {
        modifier(AppFontModifier(spec: spec))
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
