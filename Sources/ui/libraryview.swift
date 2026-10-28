import SwiftUI

private struct LibraryRenameTarget: Identifiable {
    let id = UUID()
    let title: String
    let current: String
    let save: (String) -> Void
}

private struct LibraryRenameSheet: View {
    let target: LibraryRenameTarget
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""

    var body: some View {
        NavigationView {
            Form { TextField(target.title, text: $value).disableAutocorrection(true) }
                .navigationTitle(target.title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("save") { target.save(value); dismiss() }
                            .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .onAppear { value = target.current }
        }
        .navigationViewStyle(.stack)
    }
}

// The library: playlists, plus every artist, album and song that is in it (played, saved, or brought in by a playlist import).
struct LibraryView: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var auth: SpotifyAuth
    @EnvironmentObject var lastfm: LastfmClient
    @State private var sub = 0              // 0 = playlists, 1 = artists, 2 = albums, 3 = all songs
    @State private var creating = false
    @State private var importkind: ImportKind?
    @State private var filter = ""
    @State private var renaming: LibraryRenameTarget?

    enum ImportKind: String, Identifiable { case spotify, file, youtubeplaylist, youtubelink; var id: String { rawValue } }

    private var songs: [Track] {
        library.allsongs.sorted {
            let a = library.shown($0)
            let b = library.shown($1)
            let title = a.title.localizedCaseInsensitiveCompare(b.title)
            return title == .orderedSame
                ? a.artist.localizedCaseInsensitiveCompare(b.artist) == .orderedAscending
                : title == .orderedAscending
        }
    }

    private func firstartist(_ t: Track) -> String { library.primaryartist(t) }

    var body: some View {
        List {
            Picker("library section", selection: $sub) {
                Text("playlists").tag(0)
                Text("artists").tag(1)
                Text("albums").tag(2)
                Text("songs").tag(3)
            }
            .pickerStyle(.segmented)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .listRowBackground(Color.clear)
            if sub == 0 { playlists } else if sub == 1 { artists } else if sub == 2 { albums } else { songlist }
        }
        .themed()
        .listStyle(.plain)
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 72) }
        .navigationTitle("library")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $filter, prompt: sub == 1 ? "artists" : (sub == 2 ? "albums" : (sub == 0 ? "playlists" : "songs")))
        .onChange(of: filter) { value in
            if value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "goontomrwolf", !settings.legacyiconunlocked {
                settings.legacyiconunlocked = true
                filter = ""
                ToastCenter.shared.show("you found the original wolf. check settings → appearance.")
            }
        }
        .refreshable { update() }
        .task(id: "\(auth.connected)|\(lastfm.loggedin)|\(library.data.library.count)") {
            guard auth.connected || lastfm.loggedin else { return }
            await library.refreshAllYouTubeServiceMetadata(api: Services.shared.api, lastfm: lastfm)
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button { update() } label: { SwiftUI.Label("update library", systemImage: "arrow.triangle.2.circlepath") }
                    Divider()
                    Button { importkind = .file } label: { SwiftUI.Label("add your own song", systemImage: "plus.circle") }
                    Button { importkind = .spotify } label: { SwiftUI.Label("spotify playlist", systemImage: "music.note.list") }
                    Button { importkind = .youtubeplaylist } label: { SwiftUI.Label("youtube playlist", systemImage: "play.rectangle.on.rectangle") }
                    Button { importkind = .youtubelink } label: { SwiftUI.Label("youtube link", systemImage: "link") }
                } label: { SwiftUI.Label("library actions", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $creating) { NewPlaylistSheet { library.addplaylist($0) } }
        .sheet(item: $importkind) { k in
            switch k {
            case .spotify: SpotifyImportView()
            case .file: AddTrackView()
            case .youtubeplaylist: YouTubeImportView()
            case .youtubelink: YouTubeSongView()
            }
        }
        .sheet(item: $renaming) { LibraryRenameSheet(target: $0) }
    }

    // pulls every song that is in a playlist into the artists / albums / songs sections
    private func update() {
        let n = library.syncfromplaylists()
        ToastCenter.shared.show(n == 0 ? "library is up to date" : "added \(n) \(n == 1 ? "song" : "songs") to your library")
    }

    // ---- playlists (default) ---------------------------------------------------------------------------------------------
    @ViewBuilder private var playlists: some View {
        Section {
            Button { creating = true } label: { SwiftUI.Label("new playlist", systemImage: "plus") }
        }
        Section {
            if library.data.playlists.isEmpty {
                Text("no playlists yet. use import in the top right to bring in a spotify playlist.").foregroundColor(.secondary)
            }
            ForEach(library.data.playlists.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }) { p in
                NavigationLink(destination: LocalPlaylistView(id: p.id)) {
                    HStack(spacing: 12) {
                        PlaylistCover(playlist: p, size: 52)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name).lineLimit(1)
                            Text("\(p.trackids.count) tracks\(p.spotifyid != nil ? " · from spotify" : (p.youtubeid != nil ? " · from youtube" : ""))").font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
            }
            .onDelete { offsets in
                let ids = offsets.map { library.data.playlists[$0].id }
                ids.forEach { library.removeplaylist($0) }
            }
        }
    }

    // ---- artists ------------------------------------------------------------------------------------------------------------
    @ViewBuilder private var artists: some View {
        let grouped = Dictionary(grouping: songs, by: { firstartist($0) })
        let names = grouped.keys
            .filter { filter.isEmpty || $0.localizedCaseInsensitiveContains(filter) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        if names.isEmpty {
            Text("nothing here yet. songs you play or import show up in your library automatically. use the update button if a playlist's songs are missing.").foregroundColor(.secondary)
        }
        ForEach(names, id: \.self) { n in
            NavigationLink(destination: ArtistTracksView(name: n)) {
                HStack(spacing: 12) {
                    ArtworkView(url: library.artistphoto(n) ?? grouped[n]?.first.flatMap { library.shown($0).artworkurl }, size: 52, corner: 26, symbol: "person.fill")
                    Text(n).lineLimit(1)
                    Spacer()
                    Text("\(grouped[n]?.count ?? 0)").foregroundColor(.secondary)
                }
            }
            .contextMenu {
                Button {
                    let ids = (grouped[n] ?? []).map(\.id)
                    renaming = LibraryRenameTarget(title: "rename artist", current: n) { library.renameartist(n, trackids: ids, to: $0) }
                } label: { Label("rename artist", systemImage: "pencil") }
            }
        }
    }

    // ---- albums -------------------------------------------------------------------------------------------------------------
    @ViewBuilder private var albums: some View {
        let groups = library.albumgroups(songs).filter {
            filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) || $0.artist.localizedCaseInsensitiveContains(filter)
        }
        if groups.isEmpty {
            Text(songs.isEmpty ? "nothing here yet. songs you play or import show up in your library automatically." : "no albums found").foregroundColor(.secondary)
        }
        ForEach(groups) { g in
            NavigationLink(destination: AlbumTracksView(key: g.id)) {
                HStack(spacing: 12) {
                    AlbumArtworkView(group: g, size: 52, corner: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(g.name).lineLimit(1)
                        Text("\(g.artist) · \(g.tracks.count) \(g.tracks.count == 1 ? "song" : "songs")").font(.caption).foregroundColor(.secondary).lineLimit(1)
                    }
                }
            }
            .contextMenu {
                Button {
                    let ids = g.tracks.map(\.id)
                    renaming = LibraryRenameTarget(title: "rename album", current: g.name) { library.renamealbum(g.id, trackids: ids, artist: g.artist, to: $0) }
                } label: { Label("rename album", systemImage: "pencil") }
            }
        }
    }

    // ---- songs --------------------------------------------------------------------------------------------------------------
    @ViewBuilder private var songlist: some View {
        let all = songs.filter { filter.isEmpty || library.shown($0).title.localizedCaseInsensitiveContains(filter) || firstartist($0).localizedCaseInsensitiveContains(filter) }
        if all.isEmpty {
            Text(songs.isEmpty ? "songs appear here after you play or import them." : "no matches").foregroundColor(.secondary)
        } else {
            ForEach(Array(all.enumerated()), id: \.element.id) { i, t in
                TrackRow(track: t, all: all, i: i)
                    .listRowBackground(Color.clear)
            }
        }
    }
}

// An artist's page: the artist's photo as a big cover across the full width, fading into a blurred backdrop, with their name at
// the bottom; then play / shuffle and every song by them. the photo is the one you picked, else the one found on spotify, else the
// cover of their latest song. all of it can be changed from the menu in the top right.
struct ArtistTracksView: View {
    let name: String
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var auth: SpotifyAuth
    @State private var picking = false
    @State private var cropsource: CropSource?
    @State private var spotifytracks: [Track] = []
    @State private var renaming: LibraryRenameTarget?
    @Environment(\.dismiss) private var dismiss

    private var tracks: [Track] {
        library.allsongs.filter { library.primaryartist($0) == name }
            .sorted { library.shown($0).title.lowercased() < library.shown($1).title.lowercased() }
    }
    private var hascustom: Bool { library.data.artists[name]?.photo != nil }

    var body: some View {
        let all = tracks
        CoverPage(url: library.artistimageurl(name)) { image in
            List {
                CoverHeader(image: image, title: name, subtitle: "\(all.count) \(all.count == 1 ? "song" : "songs")")
                    .coverrow()
                Section { PlayShuffleRow(tracks: all) }.listRowBackground(Color.clear)
                Section { ForEach(Array(all.enumerated()), id: \.element.id) { i, t in TrackRow(track: t, all: all, i: i, showsource: true) } }.listRowBackground(Color.clear)
                // more by this artist from spotify (not just what's in the library), so an artist opened from a search result isn't empty
                let ids = Set(all.map { $0.id })
                let extra = spotifytracks.filter { !ids.contains($0.id) }
                if !extra.isEmpty {
                    Section(header: Text("more on spotify")) {
                        ForEach(Array(extra.enumerated()), id: \.element.id) { i, t in TrackRow(track: t, all: extra, i: i) }
                    }.listRowBackground(Color.clear)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        let ids = tracks.map(\.id)
                        renaming = LibraryRenameTarget(title: "rename artist", current: name) {
                            library.renameartist(name, trackids: ids, to: $0)
                            dismiss()
                        }
                    } label: { SwiftUI.Label("rename artist", systemImage: "pencil") }
                    Button { picking = true } label: { SwiftUI.Label("choose photo", systemImage: "photo") }
                    Button { Task { await findphoto() } } label: { SwiftUI.Label("find photo on spotify", systemImage: "magnifyingglass") }
                    if hascustom {
                        Button(role: .destructive) { library.clearartistphoto(name) } label: { SwiftUI.Label("remove my photo", systemImage: "trash") }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        // the photo is looked up on spotify once (and remembered); until then the latest song's cover stands in
        .task(id: name) { await library.fetchartistimage(name) }
        .task(id: name) { if auth.connected { spotifytracks = (try? await Services.shared.api.artisttracks(name)) ?? [] } }
        .sheet(isPresented: $picking) { ImagePicker { img in DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { cropsource = CropSource(kind: .image(img)) } } }
        .sheet(item: $cropsource) { src in
            ArtworkCropView(source: src, ondone: { rect, _ in await finishcrop(src, rect) }, oncancel: { cropsource = nil })
        }
        .sheet(item: $renaming) { LibraryRenameSheet(target: $0) }
    }

    @MainActor private func findphoto() async {
        await library.fetchartistimage(name, force: true)
        ToastCenter.shared.show(library.data.artists[name]?.imageurl != nil ? "found a photo on spotify" : "no photo found on spotify")
    }

    // applies the normalized crop to the real pixels, then stores the result
    @MainActor private func finishcrop(_ src: CropSource, _ n: CGRect) async {
        defer { cropsource = nil }
        guard case .image(let img) = src.kind, let cg = img.normalizedup().cgImage else { return }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let r = CGRect(x: n.minX * w, y: n.minY * h, width: n.width * w, height: n.height * h).integral
        if let c = cg.cropping(to: r) { library.setartistphoto(name, image: UIImage(cgImage: c)) }
        else { ToastCenter.shared.show("couldn't crop that image") }
    }
}

// An album's page: same look as the artist page, with the album cover and songs alphabetically.
struct AlbumTracksView: View {
    let key: String
    @EnvironmentObject var library: LibraryStore
    @State private var pickingArtwork = false
    @State private var pickingAnimatedArtwork = false
    @State private var renaming: LibraryRenameTarget?
    @Environment(\.dismiss) private var dismiss

    private var group: AlbumGroup? { library.albumgroups(library.allsongs).first { $0.id == key } }

    var body: some View {
        let g = group
        let all = (g?.tracks ?? []).sorted {
            library.shown($0).title.localizedCaseInsensitiveCompare(library.shown($1).title) == .orderedAscending
        }
        CoverPage(url: all.lazy.compactMap { library.shown($0).artworkurl }.first) { image in
            List {
                CoverHeader(image: image, title: g?.name ?? "album", subtitle: g.map { "\($0.artist) · \(all.count) \(all.count == 1 ? "song" : "songs")" } ?? "", album: g)
                    .coverrow()
                Section { PlayShuffleRow(tracks: all) }.listRowBackground(Color.clear)
                Section { ForEach(Array(all.enumerated()), id: \.element.id) { i, t in TrackRow(track: t, all: all, i: i, showsource: true) } }.listRowBackground(Color.clear)
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    if let g {
                        Button {
                            let ids = g.tracks.map(\.id)
                            renaming = LibraryRenameTarget(title: "rename album", current: g.name) {
                                library.renamealbum(g.id, trackids: ids, artist: g.artist, to: $0)
                                dismiss()
                            }
                        } label: { Label("rename album", systemImage: "pencil") }
                    }
                    Button { pickingArtwork = true } label: { Label("choose still album cover", systemImage: "photo") }
                    Button { pickingAnimatedArtwork = true } label: { Label("choose animated album cover", systemImage: "play.rectangle") }
                    if library.data.albumart[key] != nil {
                        Button(role: .destructive) { library.clearalbumartwork(key) } label: { Label("use original covers", systemImage: "arrow.uturn.backward") }
                    }
                    if library.data.albumvideo[key] != nil {
                        Button(role: .destructive) { library.clearalbumvideo(key) } label: { Label("remove animated album cover", systemImage: "video.slash") }
                    }
                } label: { Image(systemName: "ellipsis.circle.fill") }
            }
        }
        .sheet(isPresented: $pickingArtwork) {
            ImagePicker { image in
                guard let square = image.cropped(toAspect: 1) else { ToastCenter.shared.show("couldn't use that image"); return }
                library.setalbumartwork(key, image: square)
                ToastCenter.shared.show("album cover updated")
            }
        }
        .sheet(isPresented: $pickingAnimatedArtwork) {
            VideoPicker { url in
                library.setalbumvideo(key, source: url)
                try? FileManager.default.removeItem(at: url)
                ToastCenter.shared.show("animated album cover updated")
            }
        }
        .sheet(item: $renaming) { LibraryRenameSheet(target: $0) }
    }
}

// Spotify playlist import: pick one of your playlists, or paste any playlist link. the playlist's order, name, cover and spotify id
// are kept, every track keeps its spotify metadata, and everything lands in the library.
struct SpotifyImportView: View {
    @EnvironmentObject var auth: SpotifyAuth
    @EnvironmentObject var library: LibraryStore
    @Environment(\.presentationMode) private var presentation
    @State private var items: [SpPlaylist] = []
    @State private var more = false
    @State private var loading = false
    @State private var started = false
    @State private var link = ""
    @State private var busyid: String?
    @State private var status = ""

    var body: some View {
        NavigationView {
            List {
                if !auth.connected {
                    Section { Text("connect spotify in settings first.").foregroundColor(.orange) }
                }
                Section(header: Text("from a link"), footer: Text(status.isEmpty ? "paste a spotify playlist link." : status)) {
                    TextField("spotify playlist link", text: $link).autocapitalization(.none).disableAutocorrection(true).keyboardType(.URL)
                    Button("import") { Task { await importlink() } }.disabled(SpotifyAPI.playlistid(from: link) == nil || busyid != nil || !auth.connected)
                }
                Section(header: Text("your spotify playlists")) {
                    ForEach(items) { p in
                        HStack(spacing: 12) {
                            ArtworkView(url: p.images?.first.flatMap { URL(string: $0.url) }, size: 44, symbol: "music.note.list")
                            Text(p.name).lineLimit(2)
                            Spacer()
                            if busyid == p.id { ProgressView() }
                            else if library.data.playlists.contains(where: { $0.spotifyid == p.id }) { Button("refresh") { Task { await importone(p) } }.buttonStyle(.bordered) }
                            else { Button("import") { Task { await importone(p) } }.buttonStyle(.borderedProminent) }
                        }
                        .disabled(busyid != nil && busyid != p.id)
                    }
                    if loading { Text("loading…").foregroundColor(.secondary) }
                    else if more { Button("load more") { Task { await load() } } }
                }
            }
            .themed()
            .navigationTitle("import spotify playlist").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("done") { presentation.wrappedValue.dismiss() } } }
            .onAppear { if !started, auth.connected { started = true; Task { await load() } } }
        }
        .navigationViewStyle(.stack)
    }

    @MainActor private func load() async {
        loading = true
        do { let r = try await Services.shared.api.playlists(offset: items.count); items += r.items; more = r.more }
        catch { SpotifyAPI.report(error); more = false }
        loading = false
    }

    @MainActor private func importone(_ p: SpPlaylist) async {
        busyid = p.id
        defer { busyid = nil }
        var all: [Track] = []
        var offset: Int? = 0
        while let pageOffset = offset {
            do {
                let r = try await Services.shared.api.playlisttracks(p.id, offset: pageOffset)
                all += r.tracks; offset = r.nextOffset
                status = "\(p.name): \(all.count) tracks…"
            } catch { SpotifyAPI.report(error); status = "couldn't finish \(p.name)"; return }
        }
        library.importspotify(id: p.id, name: p.name, coverurl: p.images?.first?.url, tracks: all)
        status = "imported \(all.count) tracks from \(p.name)"
        ToastCenter.shared.show("imported \(all.count) tracks from \(p.name)")
    }

    @MainActor private func importlink() async {
        guard let id = SpotifyAPI.playlistid(from: link) else { return }
        busyid = id
        defer { busyid = nil }
        do {
            let p = try await Services.shared.api.playlist(id)
            link = ""
            await importone(p)
        } catch { SpotifyAPI.report(error) }
    }
}
