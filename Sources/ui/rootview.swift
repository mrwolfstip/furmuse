import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var store: SetupStore
    @EnvironmentObject var toasts: ToastCenter
    @EnvironmentObject var engine: PlaybackEngine
    @EnvironmentObject var library: LibraryStore
    @ObservedObject private var web = WebPlaybackSession.shared
    @ObservedObject private var librespot = LibrespotSession.shared
    @ObservedObject private var quota = SpotifyQuotaNotice.shared
    @ObservedObject private var appleCovers = AppleCovers.shared
    @ObservedObject private var spotifyCanvas = SpotifyCanvas.shared
    @Environment(\.colorScheme) private var system
    @State private var coverColor: UIColor?
    @State private var showingLaunch = true

    private var artworkKey: String {
        guard let track = engine.current else { return "" }
        let shown = library.shown(track)
        let video = animatedURL(for: track, shown: shown)?.absoluteString ?? ""
        let order = library.animatedcoverorder(track.id) ?? settings.animatedcoverorder
        return "\(shown.artwork ?? shown.id)|\(video)|\(order)|\(settings.showanimatedplayer)"
    }

    private func animatedURL(for track: Track, shown: Track) -> URL? {
        if let custom = library.videourl(track.id) { return custom }
        guard library.data.overrides[track.id]?.artwork == nil else { return nil }
        let apple = settings.applecovers ? appleCovers.cached(artist: shown.artist, album: shown.album)?.video : nil
        let canvas = settings.spotifycanvas && track.isspotify ? spotifyCanvas.cached(trackid: track.id)?.video : nil
        if (library.animatedcoverorder(track.id) ?? settings.animatedcoverorder) == "apple" { return apple ?? canvas }
        return canvas ?? apple
    }

    private var showsloading: Bool {
        store.state.setupcompleted && (engine.loading || librespot.launchingPlayback || (settings.backend == .webplayback && (web.phase == .loading || web.phase == .connecting)))
    }

    var body: some View {
        let scheme = settings.colorscheme ?? system
        ZStack(alignment: .top) {
            AeroBackdrop().ignoresSafeArea()
            Group {
                if store.state.setupcompleted { MainView().transition(.opacity) } else { SetupView().transition(.opacity) }
            }
            .animation(.softease, value: store.state.setupcompleted)
            ToastView()
            if showsloading {
                LoadingView(text: engine.loading || librespot.launchingPlayback ? "loading…" : "connecting…")
            }
            if showingLaunch {
                LaunchSplash()
                    .zIndex(1000)
                    .transition(.opacity)
            }
        }
        .preferredColorScheme(settings.colorscheme)
        .onOpenURL { url in
            guard url.scheme?.lowercased() == AppConfig.spotifyredirectscheme else { return }
            Log.i(.lifecycle, "opened from furmuse url: \(url.host ?? "unknown")")
            // OAuth callbacks are consumed by ASWebAuthenticationSession. Player/live-activity
            // links only need to foreground the existing root, whose default tab is now playing.
        }
        .animation(.softease, value: showsloading)
        .task {
            guard showingLaunch else { return }
            try? await Task.sleep(nanoseconds: 2_100_000_000)
            withAnimation(.easeInOut(duration: 0.45)) { showingLaunch = false }
        }
        .accentColor(NowPlayingPalette(art: coverColor, dark: scheme == .dark, amoled: settings.amoled, fallback: settings.tint(scheme)).accent)
        .task(id: artworkKey) {
            guard let track = engine.current else { coverColor = nil; return }
            let shown = library.shown(track)

            if settings.showanimatedplayer, let videoURL = animatedURL(for: track, shown: shown),
               let frame = await Task.detached(priority: .utility, operation: {
                   let asset = AVURLAsset(url: videoURL)
                   let generator = AVAssetImageGenerator(asset: asset)
                   generator.appliesPreferredTrackTransform = true
                   generator.maximumSize = CGSize(width: 320, height: 320)
                   guard let cg = try? generator.copyCGImage(at: CMTime(seconds: 0.25, preferredTimescale: 600), actualTime: nil) else { return nil as UIImage? }
                   return UIImage(cgImage: cg)
               }).value {
                coverColor = ArtworkColor.average(of: frame, key: "animated:\(videoURL.absoluteString)")
                return
            }

            guard let url = shown.artworkurl else { coverColor = nil; return }
            let image = await ArtworkLoader.shared.image(url, maxpixel: 320)
            coverColor = image.map { ArtworkColor.average(of: $0, key: url.absoluteString) }
        }
        .alert("spotify needs a break", isPresented: Binding(
            get: { quota.visible && settings.backend == .webplayback },
            set: { if !$0 { quota.visible = false } }
        )) {
            Button("ok", role: .cancel) { quota.visible = false }
        } message: {
            Text("spotify says too many requests were made. furmuse will try again in about \(quota.retryAfter) seconds.")
        }
    }
}

private struct LaunchSplash: View {
    @State private var formed: CGFloat = 0
    private let bars = 29

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 18) {
                Text("furmuse")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    HStack(alignment: .center, spacing: 4) {
                        ForEach(0..<bars, id: \.self) { index in
                            let center = Double(index) - Double(bars - 1) / 2
                            let envelope = max(0.18, 1 - abs(center) / Double(bars) * 1.35)
                            let wave = 0.56 + 0.44 * sin(time * 4.2 + Double(index) * 0.72)
                            let reveal = min(max(formed * CGFloat(bars) - CGFloat(index), 0), 1)
                            Capsule()
                                .fill(Color.white.opacity(0.92))
                                .frame(width: 4, height: max(4, CGFloat(12 + 42 * envelope * wave) * reveal))
                                .opacity(Double(reveal))
                        }
                    }
                    .frame(width: 230, height: 64)
                }

                Text("loading your music one note at a time.")
                    .font(.subheadline.italic())
                    .foregroundColor(.gray)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.25)) { formed = 1 }
        }
        .allowsHitTesting(true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("furmuse. loading your music one note at a time.")
    }
}

private struct LoadingView: View {
    let text: String
    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 10) {
                ProgressView().progressViewStyle(.circular)
                Text(text).font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
            .padding(.bottom, 104)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}

struct ToastView: View {
    @EnvironmentObject var toasts: ToastCenter

    var body: some View {
        ZStack(alignment: .top) {
            if let t = toasts.current {
                Text(t.text)
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .onTapGesture {
                    toasts.current = nil
                    if let r = t.route { toasts.route = r }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.softspring, value: toasts.current?.id)
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// file picker that hands back COPIES of the picked files (asCopy). unlike SwiftUI's .fileImporter this
// doesn't depend on security-scoped access (which breaks when re-signed), and several can live on one screen.
enum CopyPicker {
    private static var live: Delegate?

    private final class Delegate: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        let onCancel: () -> Void
        init(onPick: @escaping ([URL]) -> Void, onCancel: @escaping () -> Void) { self.onPick = onPick; self.onCancel = onCancel }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            CopyPicker.live = nil
            onPick(urls)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            CopyPicker.live = nil
            onCancel()
        }
    }

    private static func topController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive } ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController ?? scene?.windows.first?.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }

    static func present(types: [UTType], multiple: Bool, onPick: @escaping ([URL]) -> Void, onCancel: @escaping () -> Void) {
        let show = {
            guard let top = topController() else { onCancel(); return }
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
            picker.allowsMultipleSelection = multiple
            let d = Delegate(onPick: onPick, onCancel: onCancel)
            live = d   // the picker only holds its delegate weakly
            picker.delegate = d
            top.present(picker, animated: true)
        }
        // let a closing menu/sheet finish first, otherwise iOS silently drops the presentation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: show)
    }
}

extension View {
    func copyPicker(isPresented: Binding<Bool>, types: [UTType], multiple: Bool = false, onPick: @escaping ([URL]) -> Void) -> some View {
        onChange(of: isPresented.wrappedValue) { on in
            guard on else { return }
            CopyPicker.present(types: types, multiple: multiple, onPick: { urls in
                isPresented.wrappedValue = false
                onPick(urls)
            }, onCancel: { isPresented.wrappedValue = false })
        }
    }
}

struct KeyValue: View {
    let key: String
    let value: String
    var body: some View {
        HStack { Text(key); Spacer(); Text(value).foregroundColor(.secondary).multilineTextAlignment(.trailing) }
    }
}
