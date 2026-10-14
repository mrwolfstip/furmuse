import SwiftUI

struct NewPlaylistSheet: View {
    let oncreate: (String) -> Void
    @Environment(\.presentationMode) private var presentation
    @State private var name = ""

    var body: some View {
        NavigationView {
            Form {
                TextField("playlist name", text: $name).textInputAutocapitalization(.never).disableAutocorrection(true)
                Button("create") {
                    let n = name.trimmingCharacters(in: .whitespaces)
                    if !n.isEmpty { oncreate(n) }
                    presentation.wrappedValue.dismiss()
                }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .navigationTitle("new playlist").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarLeading) { Button("cancel") { presentation.wrappedValue.dismiss() } } }
        }
        .navigationViewStyle(.stack)
    }
}

struct AddToPlaylistMenu<Label: View>: View {
    let track: Track
    @ViewBuilder let label: () -> Label
    @EnvironmentObject var library: LibraryStore
    @State private var creating = false

    var body: some View {
        Menu {
            ForEach(library.data.playlists) { p in
                Button { library.add(track, to: p.id) } label: {
                    if p.trackids.contains(track.id) { SwiftUI.Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                }
            }
            Button { creating = true } label: { SwiftUI.Label("new playlist…", systemImage: "plus") }
        } label: { label() }
        .sheet(isPresented: $creating) {
            NewPlaylistSheet { name in library.add(track, to: library.addplaylist(name)) }
        }
    }
}

struct TrackRow: View {
    let track: Track
    let all: [Track]
    let i: Int
    var showsource = false                                   // library lists show where the track plays from
    var onplay: ((Track, [Track], Int) -> Void)? = nil       // search routes taps through the source popup
    @EnvironmentObject var engine: PlaybackEngine
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var devices: DeviceManager
    @EnvironmentObject var downloads: DownloadManager
    @State private var creating = false
    @State private var pendingsource: PendingSource?

    private func playthis() { if let f = onplay { f(track, all, i) } else { engine.play(all, at: i) } }

    var body: some View {
        let s = library.shown(track)
        HStack(spacing: 8) {
            // the cover and the empty part of the row play the song; tapping the title or artist plays it too
            Button { playthis() } label: { TrackArt(track: track, size: 46).contentShape(Rectangle()) }
                .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.title).foregroundColor(.primary).lineLimit(1)
                HStack(spacing: 0) {
                    Text(s.artist).font(.caption).foregroundColor(.secondary).lineLimit(1)
                    if !s.album.isEmpty { Text(" · \(s.album)").font(.caption).foregroundColor(.secondary).lineLimit(1) }
                }
                if showsource { SourceBadge(track: track) }
            }
            .contentShape(Rectangle())
            .onTapGesture { playthis() }
            Button { playthis() } label: {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    if downloads.has(track) { Image(systemName: "arrow.down.circle.fill").font(.caption).foregroundColor(.secondary) }
                }
                .frame(maxWidth: .infinity, minHeight: 46)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Menu {
                Button { engine.enqueue(track) } label: { SwiftUI.Label("add to queue", systemImage: "text.append") }
                Button { engine.enqueue(track, next: true) } label: { SwiftUI.Label("play next", systemImage: "text.insert") }
                Button { Task { await devices.playsingle(track) } } label: { SwiftUI.Label("play on connect device", systemImage: "hifispeaker") }
                Button { library.addtolibrary(track, via: "saved") } label: { SwiftUI.Label(library.inlibrary(track.id) ? "in your library" : "save to library", systemImage: library.inlibrary(track.id) ? "heart.fill" : "heart") }
                if track.isspotify {
                    Button { pendingsource = PendingSource(track: track, all: [track], index: 0, play: false) } label: { SwiftUI.Label("choose youtube source…", systemImage: "play.rectangle") }
                }
                if downloads.has(track) {
                    Button { downloads.remove(track.id) } label: { SwiftUI.Label("remove download", systemImage: "trash") }
                } else {
                    Button { Task { await downloads.download(track) } } label: { SwiftUI.Label("download", systemImage: "arrow.down.circle") }
                }
                Menu {
                    ForEach(library.data.playlists) { p in
                        Button { library.add(track, to: p.id) } label: {
                            if p.trackids.contains(track.id) { SwiftUI.Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                        }
                    }
                    Button { creating = true } label: { SwiftUI.Label("new playlist…", systemImage: "plus") }
                } label: { SwiftUI.Label("add to playlist", systemImage: "text.badge.plus") }
            } label: {
                Image(systemName: "ellipsis").foregroundColor(.secondary).frame(width: 32, height: 40).contentShape(Rectangle())
            }
        }
        .sheet(isPresented: $creating) { NewPlaylistSheet { library.add(track, to: library.addplaylist($0)) } }
        .sourcechooser($pendingsource)
    }
}

// where a library track plays from. the spotify track is the identity; this is only its source attribute.
struct SourceBadge: View {
    let track: Track
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var settings: Settings

    var body: some View {
        let s = library.sourcesummary(track, defaultsource: settings.defaultsource)
        Text(label(s)).font(.caption2).foregroundColor(s.kind == "youtube" && !s.confirmed ? .orange : .secondary).lineLimit(1)
    }

    private func label(_ s: (kind: String, detail: String, confirmed: Bool)) -> String {
        guard s.kind == "youtube" else { return s.kind }
        if s.confirmed { return "youtube · confirmed" }
        if s.detail == "not chosen yet" { return "youtube · not chosen yet" }
        if s.detail == "needs a new source" { return "youtube · needs a new source" }
        return "youtube · automatic"
    }
}

struct TrackListView: View {
    let tracks: [Track]
    var showsource = false
    var onplay: ((Track, [Track], Int) -> Void)? = nil
    var body: some View {
        ForEach(Array(tracks.enumerated()), id: \.offset) { i, t in TrackRow(track: t, all: tracks, i: i, showsource: showsource, onplay: onplay) }
    }
}

struct SearchView: View {
    @EnvironmentObject var auth: SpotifyAuth
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var engine: PlaybackEngine
    @State private var pending: PendingSource?
    @State private var query = ""
    @State private var results: [Track] = []
    @State private var busy = false
    @State private var searched = false
    @State private var provider = ""

    var body: some View {
        List {
            Section {
                TextField("search music", text: $query)
                    .submitLabel(.search)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .onSubmit { run() }
            }
            if busy {
                Text("searching…").foregroundColor(.secondary)
            } else if results.isEmpty && searched {
                Text("no results").foregroundColor(.secondary)
            } else {
                Section(footer: Text(provider == "youtube" ? "showing youtube results because spotify search isn't available." : "")) {
                    TrackListView(tracks: results) { t, all, i in choose(t, all, i) }
                }
            }
        }
        .themed()
        .navigationTitle("search")
        .navigationBarTitleDisplayMode(.inline)
        .sourcechooser($pending)
        .animation(.easeInOut(duration: 0.2), value: busy)
    }

    // youtube-sourced track without a confirmed source: pick + verify one first (then it is saved, added to the library and played)
    private func choose(_ t: Track, _ all: [Track], _ i: Int) {
        if SourcePolicy.needschoice(t, library: library, settings: settings) {
            pending = PendingSource(track: t, all: all, index: i)
        } else {
            library.addtolibrary(t, via: "search")
            engine.play(all, at: i)
        }
    }

    private func run() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        busy = true
        Task { @MainActor in
            if auth.connected {
                do {
                    results = try await Services.shared.api.search(q)
                    provider = "spotify"
                } catch {
                    results = await youtubeResults(q)
                    provider = "youtube"
                    if results.isEmpty { SpotifyAPI.report(error) }
                }
            } else {
                results = await youtubeResults(q)
                provider = "youtube"
            }
            searched = true
            busy = false
        }
    }

    private func youtubeResults(_ query: String) async -> [Track] {
        Array(await YouTubeSearch.search(query).prefix(20)).map { candidate in
            Track(
                id: Track.ytprefix + candidate.id,
                title: candidate.title,
                artist: candidate.channel.isEmpty ? "YouTube" : candidate.channel,
                album: "YouTube",
                artwork: YouTubeSearch.thumbnail(candidate.id)?.absoluteString,
                duration: candidate.duration ?? 0
            )
        }
    }
}

struct SpotifyPagedList: View {
    let title: String
    var saveas: SpPlaylist?
    let loader: (Int) async throws -> SpTrackPage
    @EnvironmentObject var library: LibraryStore
    @State private var tracks: [Track] = []
    @State private var nextOffset: Int? = 0
    @State private var busy = false
    @State private var started = false
    @State private var saving = false

    var body: some View {
        List {
            TrackListView(tracks: tracks)
            if busy { Text("loading…").foregroundColor(.secondary) }
            else if nextOffset != nil { Button("load more") { load() } }
            else if tracks.isEmpty && started { Text("nothing here").foregroundColor(.secondary) }
        }
        .themed()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if let p = saveas {
                    Button(saving ? "saving…" : "save locally") { Task { await save(p) } }.disabled(tracks.isEmpty || saving)
                }
            }
        }
        .onAppear { if !started { started = true; load() } }
    }

    // keeps the spotify playlist id; fetches the remaining pages first so the copy is complete
    @MainActor
    private func save(_ p: SpPlaylist) async {
        saving = true
        defer { saving = false }
        var all = tracks
        var cursor = nextOffset
        while let offset = cursor {
            do {
                let r = try await loader(offset)
                all += r.tracks
                cursor = r.nextOffset
            } catch { SpotifyAPI.report(error); return }
        }
        tracks = all
        nextOffset = nil
        library.importspotify(id: p.id, name: p.name, coverurl: p.images?.first?.url, tracks: all)
        ToastCenter.shared.show("saved \(all.count) tracks to a local playlist")
    }

    private func load() {
        guard let offset = nextOffset else { return }
        busy = true
        Task { @MainActor in
            do {
                let r = try await loader(offset)
                tracks += r.tracks
                nextOffset = r.nextOffset
            } catch { SpotifyAPI.report(error); nextOffset = nil }
            busy = false
        }
    }
}

struct SpotifyPlaylistsView: View {
    @State private var items: [SpPlaylist] = []
    @State private var more = false
    @State private var busy = false
    @State private var started = false

    var body: some View {
        List {
            ForEach(items) { p in
                NavigationLink(destination: SpotifyPagedList(title: p.name, saveas: p) { off in try await Services.shared.api.playlisttracks(p.id, offset: off) }) {
                    HStack(spacing: 12) {
                        ArtworkView(url: p.images?.first.flatMap { URL(string: $0.url) }, size: 52, symbol: "music.note.list")
                        Text(p.name).lineLimit(2)
                    }
                }
            }
            if busy { Text("loading…").foregroundColor(.secondary) }
            else if more { Button("load more") { load() } }
        }
        .themed()
        .navigationTitle("spotify playlists")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if !started { started = true; load() } }
    }

    private func load() {
        busy = true
        Task { @MainActor in
            do {
                let r = try await Services.shared.api.playlists(offset: items.count)
                items += r.items
                more = r.more
            } catch { SpotifyAPI.report(error); more = false }
            busy = false
        }
    }
}

struct LocalPlaylistView: View {
    let id: String
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var engine: PlaybackEngine
    @Environment(\.presentationMode) private var presentation
    @State private var picking = false
    @State private var renaming = false
    @State private var name = ""
    @State private var confirmdelete = false

    var body: some View {
        if let p = library.playlist(id) {
            let tracks = p.trackids.compactMap { library.data.tracks[$0] }
            CoverPage(url: library.playlistcoverurl(p)) { image in
                List {
                    CoverHeader(image: image, title: p.name, subtitle: "\(p.trackids.count) tracks\(p.spotifyid != nil ? " · imported from spotify" : (p.youtubeid != nil ? " · imported from youtube" : ""))")
                        .coverrow()
                    Section { PlayShuffleRow(tracks: tracks) }.listRowBackground(Color.clear)
                    Section {
                        if p.trackids.isEmpty { Text("empty. use the … menu on any track to add it here.").foregroundColor(.secondary) }
                        ForEach(Array(p.trackids.enumerated()), id: \.offset) { _, tid in
                            if let t = library.data.tracks[tid] {
                                TrackRow(track: t, all: tracks, i: tracks.firstIndex(of: t) ?? 0)
                            }
                        }
                        .onDelete { library.remove(trackat: $0, from: id) }
                        .onMove { library.move(from: $0, to: $1, in: id) }
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        EditButton()
                        Menu {
                            Button { name = p.name; renaming = true } label: { Label("rename", systemImage: "pencil") }
                            Button { picking = true } label: { Label("choose cover", systemImage: "photo") }
                            if p.coverfile != nil { Button { library.setplaylistcover(id, image: nil) } label: { Label("remove custom cover", systemImage: "xmark") } }
                            Button(role: .destructive) { confirmdelete = true } label: { Label("delete playlist", systemImage: "trash") }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                }
            }
            .sheet(isPresented: $picking) { ImagePicker { library.setplaylistcover(id, image: $0) } }
            .sheet(isPresented: $renaming) {
                NavigationView {
                    Form {
                        TextField("name", text: $name).textInputAutocapitalization(.never).disableAutocorrection(true)
                        Button("save") {
                            let n = name.trimmingCharacters(in: .whitespaces)
                            if !n.isEmpty { library.renameplaylist(id, n) }
                            renaming = false
                        }
                    }
                    .navigationTitle("rename").navigationBarTitleDisplayMode(.inline)
                }
                .navigationViewStyle(.stack)
            }
            .confirmationDialog("delete this playlist?", isPresented: $confirmdelete, titleVisibility: .visible) {
                Button("delete", role: .destructive) { library.removeplaylist(id); presentation.wrappedValue.dismiss() }
                Button("cancel", role: .cancel) {}
            }
        } else {
            Text("playlist not found").foregroundColor(.secondary)
        }
    }
}

struct QueueView: View {
    @EnvironmentObject var engine: PlaybackEngine
    @EnvironmentObject var library: LibraryStore
    @Environment(\.editMode) private var editmode

    private var hascurrent: Bool { engine.queue.indices.contains(engine.index) }
    private var upnext: [Int] { hascurrent && engine.index + 1 < engine.queue.count ? Array((engine.index + 1)..<engine.queue.count) : [] }
    private var earlier: [Int] { hascurrent && engine.index > 0 ? Array(0..<engine.index) : [] }
    private var remaining: Double { upnext.reduce(0) { $0 + engine.queue[$1].duration } }

    var body: some View {
        Group {
            if !hascurrent {
                VStack(spacing: 10) {
                    Image(systemName: "list.bullet").font(.system(size: 44)).foregroundColor(.secondary)
                    Text("the queue is empty").font(.headline)
                    Text("play something and what's coming next shows up here").font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
                }.padding()
            } else {
                List {
                    Section(header: QueueHeader(title: "now playing")) {
                        QueueRow(track: engine.queue[engine.index], playing: true, dimmed: false, isplaying: engine.isplaying)
                            .listRowBackground(NowPlayingCardBackground())
                            .listRowSeparator(.hidden)
                    }
                    if !upnext.isEmpty {
                        Section(header: QueueHeader(title: "up next", detail: "\(upnext.count) \(upnext.count == 1 ? "song" : "songs") · \(queuetime(remaining))")) {
                            ForEach(upnext, id: \.self) { i in
                                QueueRow(track: engine.queue[i], playing: false, dimmed: false, isplaying: false) { engine.jump(to: i) }
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                            }
                            .onDelete { engine.remove(at: IndexSet($0.map { $0 + engine.index + 1 })) }
                            .onMove { from, to in engine.move(from: IndexSet(from.map { $0 + engine.index + 1 }), to: to + engine.index + 1) }
                        }
                    }
                    if !earlier.isEmpty {
                        Section(header: QueueHeader(title: "played")) {
                            ForEach(earlier, id: \.self) { i in
                                QueueRow(track: engine.queue[i], playing: false, dimmed: true, isplaying: false) { engine.jump(to: i) }
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                            }
                            .onDelete { engine.remove(at: $0) }
                            .onMove { engine.move(from: $0, to: $1) }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .themed()
        .navigationTitle("queue")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { if hascurrent && engine.queue.count > 1 { EditButton() } } }
    }

    private func queuetime(_ s: Double) -> String {
        let m = Int(s) / 60
        return m >= 60 ? "\(m / 60) hr \(m % 60) min" : "\(max(m, 1)) min"
    }
}

private struct QueueHeader: View {
    let title: String
    var detail = ""
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.footnote.weight(.semibold)).textCase(.uppercase).foregroundColor(.secondary)
            Spacer()
            if !detail.isEmpty { Text(detail).font(.caption).foregroundColor(.secondary) }
        }
        .padding(.horizontal, 4)
    }
}

private struct NowPlayingCardBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.accentColor.opacity(0.16))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.accentColor.opacity(0.35), lineWidth: 1))
            .padding(.vertical, 2)
    }
}

private struct QueueRow: View {
    let track: Track
    let playing: Bool
    let dimmed: Bool
    let isplaying: Bool
    var onplay: (() -> Void)? = nil           // tapping the cover or the empty part of the row; the title and artist are links
    @EnvironmentObject var library: LibraryStore

    var body: some View {
        let s = library.shown(track)
        HStack(spacing: 12) {
            TrackArt(track: track, size: playing ? 56 : 48, corner: 10)
                .overlay(
                    Group {
                        if playing {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.35))
                                Image(systemName: isplaying ? "waveform" : "pause.fill").font(.system(size: 18, weight: .semibold)).foregroundColor(.white)
                            }
                        }
                    }
                )
                .contentShape(Rectangle())
                .onTapGesture { onplay?() }
            VStack(alignment: .leading, spacing: 3) {
                Text(s.title).font(.body.weight(playing ? .bold : .semibold)).foregroundColor(playing ? .accentColor : .primary).lineLimit(1)
                Text(s.artist).font(.subheadline).foregroundColor(.secondary).lineLimit(1)
            }
            .contentShape(Rectangle())
            .onTapGesture { onplay?() }
            HStack(spacing: 0) {
                Spacer(minLength: 8)
                if track.duration > 0 { Text(fmttime(track.duration)).font(.caption).monospacedDigit().foregroundColor(.secondary) }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
            .onTapGesture { onplay?() }
        }
        .padding(.vertical, playing ? 6 : 3)
        .opacity(dimmed ? 0.5 : 1)
    }
}
