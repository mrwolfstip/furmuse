import SwiftUI

// tappable title / artist / album text. a title opens the album the song is from, an artist name opens that artist's page.
// used wherever a song is listed: search and library rows, the queue, the player, lyrics. the rest of a row still plays the song.
//
// each link owns a hidden NavigationLink, so it pushes onto whichever NavigationView the screen is in.

// does this track have an album page to go to? youtube-only imports have no album.
func trackhasalbum(_ t: Track) -> Bool {
    t.isspotify && !t.album.trimmingCharacters(in: .whitespaces).isEmpty
}

struct AlbumLink<Label: View>: View {
    let track: Track
    @ViewBuilder let label: () -> Label
    @State private var go = false

    var body: some View {
        if trackhasalbum(track) {
            Button { go = true } label: { label() }
                .buttonStyle(.plain)
                .background(NavigationLink(destination: TrackAlbumPage(track: track), isActive: $go) { EmptyView() }.hidden())
        } else {
            label()
        }
    }
}

struct ArtistLink<Label: View>: View {
    let track: Track
    @ViewBuilder let label: () -> Label
    @EnvironmentObject var library: LibraryStore
    @State private var go = false

    var body: some View {
        Button { go = true } label: { label() }
            .buttonStyle(.plain)
            .background(NavigationLink(destination: ArtistTracksView(name: library.primaryartist(track)), isActive: $go) { EmptyView() }.hidden())
    }
}

// ---- album page --------------------------------------------------------------------------------------------------------------
// the full album from spotify (every track, in order). when spotify can't be reached, or the song has no spotify album id, the
// songs of that album that are in the library are shown instead.
struct TrackAlbumPage: View {
    let track: Track
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var auth: SpotifyAuth
    @State private var album: SpotifyAlbum?
    @State private var loading = false
    @State private var started = false
    @State private var failed = false

    private var group: AlbumGroup? {
        guard let k = library.albumkey(track) else { return nil }
        return library.albumgroups(library.allsongs).first { $0.id == k }
    }

    var body: some View {
        let fromspotify = album?.tracks ?? []
        let local = (group?.tracks ?? []).sorted {
            let a = $0.tracknumber ?? Int.max, b = $1.tracknumber ?? Int.max
            return a != b ? a < b : library.shown($0).title.lowercased() < library.shown($1).title.lowercased()
        }
        let all = fromspotify.isEmpty ? local : fromspotify
        let name = album?.name ?? library.shown(track).album
        let artist = album?.artist ?? library.shown(track).artist
        CoverPage(url: album?.artwork.flatMap { URL(string: $0) } ?? track.artworkurl) { image in
            List {
                CoverHeader(image: image, title: name, subtitle: "\(artist) · \(all.count) \(all.count == 1 ? "song" : "songs")").coverrow()
                Section { PlayShuffleRow(tracks: all) }.listRowBackground(Color.clear)
                Section {
                    ForEach(Array(all.enumerated()), id: \.element.id) { i, t in TrackRow(track: t, all: all, i: i, showsource: true) }
                    if loading { Text("loading the album…").foregroundColor(.secondary) }
                    else if failed && fromspotify.isEmpty {
                        Text(local.isEmpty ? "couldn't load this album from spotify." : "couldn't reach spotify, so only the songs of this album that are in your library are shown.")
                            .font(.footnote).foregroundColor(.secondary)
                    }
                }.listRowBackground(Color.clear)
            }
        }
        .onAppear { if !started { started = true; Task { await load() } } }
    }

    @MainActor private func load() async {
        guard track.isspotify, auth.connected else { failed = true; return }
        loading = true
        defer { loading = false }
        do {
            var id = track.albumid
            if id == nil { id = try await Services.shared.api.albumid(of: track.id) }
            guard let aid = id else { failed = true; return }
            album = try await Services.shared.api.album(aid)
        } catch { failed = true }
    }
}
