import SwiftUI

// The Now Playing look for artist, album and playlist pages: the picture spans the full width and fades into the page, and behind
// the whole screen sits the same softly blurred, picture-tinted backdrop the player uses. It reuses NowPlayingArt and
// NowPlayingBackground, so the two can't drift apart.
//
//   CoverPage(url: someImageURL) { image in
//       List { CoverHeader(image: image, title: "…", subtitle: "…").listRowInsets(EdgeInsets()).listRowBackground(Color.clear); … }
//   }
//
// the page loads the image itself and hands it to the content; navigation title / toolbar modifiers go on the CoverPage.
struct CoverPage<Content: View>: View {
    let url: URL?
    let content: (UIImage?) -> Content
    @State private var image: UIImage?
    @EnvironmentObject var settings: Settings
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reducemotion

    init(url: URL?, @ViewBuilder content: @escaping (UIImage?) -> Content) {
        self.url = url
        self.content = content
    }

    private var palette: NowPlayingPalette {
        NowPlayingPalette(art: image.map { ArtworkColor.average(of: $0, key: url?.absoluteString ?? "cover") },
                          dark: scheme == .dark, amoled: settings.amoled, fallback: settings.tint(scheme))
    }

    var body: some View {
        content(image)
            .modifier(CoverScreen(background: NowPlayingBackground(image: image, palette: palette, reducemotion: reducemotion)))
            .task(id: url?.absoluteString ?? "") {
                guard let u = url else { image = nil; return }
                image = await ArtworkLoader.shared.image(u, maxpixel: 1600)
            }
    }
}

// same as .themed(), but the backdrop is the blurred cover instead of a flat colour
private struct CoverScreen<Background: View>: ViewModifier {
    let background: Background

    @ViewBuilder
    func body(content: Content) -> some View {
        // plain list style: rows run the full width (an inset-grouped list would put the cover in a rounded, indented card), and the
        // list ignores the top safe area so the cover starts at the very top of the screen, under the status bar, like Now Playing.
        // the title is blank because the cover already shows the name; back and menu buttons float over the picture.
        if #available(iOS 16.0, *) {
            content
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .toolbarBackground(.hidden, for: .navigationBar)
                .ignoresSafeArea(edges: .top)
                .background(background)
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
        } else {
            content
                .listStyle(.plain)
                .ignoresSafeArea(edges: .top)
                .background(background)
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// the big cover with the title centred at the bottom, sitting on the faded part of the picture. full width, running under the status
// bar, sized by aspect ratio so it can never overflow the screen width. use it as a list row with .coverrow().
struct CoverHeader: View {
    let image: UIImage?
    let title: String
    var subtitle = ""
    var album: AlbumGroup? = nil

    var body: some View {
        Color.clear
            .aspectRatio(0.82, contentMode: .fit)      // taller than square, like the player: the picture fills it edge to edge
            .overlay {
                if let album {
                    AlbumArtworkView(group: album, size: nil, corner: 0)
                        .mask(
                            LinearGradient(
                                stops: [
                                    .init(color: .black, location: 0),
                                    .init(color: .black, location: 0.55),
                                    .init(color: .black.opacity(0.7), location: 0.75),
                                    .init(color: .black.opacity(0.3), location: 0.9),
                                    .init(color: .clear, location: 1)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                } else {
                    NowPlayingArt(image: image, video: nil, reducemotion: true)
                }
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 4) {
                    Text(title)
                        .font(.system(size: 32, weight: .bold))
                        .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.6)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.subheadline.weight(.medium)).foregroundColor(.secondary).lineLimit(1)
                    }
                }
                // a soft halo in the page colour keeps the title readable over whatever part of the picture is still showing
                .shadow(color: Color(UIColor.systemBackground).opacity(0.85), radius: 8)
                .padding(.horizontal, 24).padding(.bottom, 14)
            }
            .clipped()
            .accessibilityElement(children: .combine)
    }
}

extension View {
    // makes a list row the full-bleed cover: no insets, no row background, no separator
    func coverrow() -> some View {
        self.listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden)
    }
}

// play / shuffle row used under the header
struct PlayShuffleRow: View {
    let tracks: [Track]
    @EnvironmentObject var engine: PlaybackEngine

    var body: some View {
        HStack(spacing: 16) {
            Button { engine.play(tracks, at: 0) } label: { SwiftUI.Label("play", systemImage: "play.fill") }.buttonStyle(.bordered)
            Button { engine.play(tracks.shuffled(), at: 0) } label: { SwiftUI.Label("shuffle", systemImage: "shuffle") }.buttonStyle(.bordered)
        }
        .disabled(tracks.isEmpty).frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .listRowSeparator(.hidden)
    }
}
