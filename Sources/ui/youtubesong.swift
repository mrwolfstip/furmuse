import SwiftUI

// import one youtube video as a song: paste a link or id (or search), check the name, optionally match it to a spotify track,
// add it to the library and offer to put it in a playlist. nothing is added until the user taps "add to library".
struct YouTubeSongView: View {
    @EnvironmentObject var auth: SpotifyAuth
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var resolver: ResolverManager
    @Environment(\.presentationMode) private var presentation
    private let planner = YouTubeImportPlanner()

    @State private var link = ""
    @State private var query = ""
    @State private var results: [YouTubeCandidate] = []
    @State private var looking = false
    @State private var searching = false

    @State private var video: YouTubeVideo?
    @State private var title = ""
    @State private var artist = ""
    @State private var album = ""

    @State private var usespotify = false
    @State private var matching = false
    @State private var item: YouTubeImportPlanner.Item?
    @State private var editing = false

    @State private var added: Track?

    private var spotifymatched: Bool { usespotify && item?.spotifymatched == true }
    private var canadd: Bool {
        guard video != nil, !matching else { return false }
        return spotifymatched || !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationView {
            Group {
                if let t = added { doneview(t) } else { form }
            }
            .themed()
            .navigationTitle("add from youtube").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button(added == nil ? "cancel" : "done") { presentation.wrappedValue.dismiss() } }
            }
        }
        .navigationViewStyle(.stack)
    }

    // ---- form --------------------------------------------------------------------------------------------------------
    private var form: some View {
        Form {
            Section(header: Text("youtube link"), footer: Text("paste a youtube link or a video id.")) {
                HStack {
                    TextField("link or id", text: $link).autocapitalization(.none).disableAutocorrection(true).keyboardType(.URL)
                        .submitLabel(.go).onSubmit { lookup() }
                    if looking { ProgressView() }
                    else { Button("look up") { lookup() }.disabled(YouTubeSearch.videoid(from: link) == nil) }
                }
            }
            Section(header: Text("search youtube")) {
                HStack {
                    TextField("search youtube", text: $query).autocapitalization(.none).disableAutocorrection(true)
                        .submitLabel(.search).onSubmit { search() }
                    if searching { ProgressView() }
                    else if !query.trimmingCharacters(in: .whitespaces).isEmpty { Button("search") { search() } }
                }
                ForEach(results) { c in
                    Button { select(c) } label: { candidaterow(c) }.buttonStyle(.plain)
                }
            }
            if let v = video {
                Section(header: Text("selected video")) { candidaterow(v.candidate) }
                if auth.connected {
                    Section(footer: Text("matching uses the spotify track for the name, cover and album. the video stays the source.")) {
                        Toggle("match to a spotify track", isOn: $usespotify)
                        if usespotify {
                            if matching {
                                HStack(spacing: 10) { ProgressView(); Text("matching…").foregroundColor(.secondary) }
                            } else if let it = item, it.spotifymatched {
                                HStack(spacing: 12) {
                                    TrackArt(track: it.track, size: 44)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(it.track.title).lineLimit(2)
                                        Text(it.track.artist).font(.caption).foregroundColor(.secondary).lineLimit(1)
                                    }
                                }
                                Button("change match") { editing = true }
                            } else if item != nil {
                                Text("no spotify match found. it will be added as a youtube-only track.").font(.footnote).foregroundColor(.secondary)
                                Button("search spotify") { editing = true }
                            }
                        }
                    }
                }
                if !spotifymatched {
                    Section(header: Text("details")) {
                        TextField("song name", text: $title)
                        TextField("artist", text: $artist)
                        TextField("album (optional)", text: $album)
                    }
                }
                Section {
                    Button("add to library") { save() }.disabled(!canadd)
                }
            }
        }
        .onChange(of: usespotify) { on in
            if on { matchnow() } else { item = nil; matching = false }
        }
        .sheet(isPresented: $editing) {
            if item != nil { ImportItemEditor(item: Binding(get: { item! }, set: { item = $0 })) }
        }
    }

    private func candidaterow(_ c: YouTubeCandidate) -> some View {
        HStack(spacing: 10) {
            AsyncImage(url: YouTubeSearch.thumbnail(c.id)) { img in img.resizable().aspectRatio(contentMode: .fill) } placeholder: { Color.gray.opacity(0.2) }
                .frame(width: 72, height: 40).clipShape(RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 2) {
                Text(c.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text("\(c.channel) · \(c.duration.map { fmttime($0) } ?? "?")").font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    // ---- after adding ------------------------------------------------------------------------------------------------
    private func doneview(_ t: Track) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundColor(.green)
            Text(t.title).font(.headline).multilineTextAlignment(.center).padding(.horizontal, 30)
            Text("added to your library").foregroundColor(.secondary)
            AddToPlaylistMenu(track: t) {
                SwiftUI.Label("add to a playlist", systemImage: "text.badge.plus")
            }
            .buttonStyle(.bordered)
            Button("add another") { reset() }
            Spacer()
        }
    }

    // ---- actions -----------------------------------------------------------------------------------------------------
    private func lookup() {
        guard let id = YouTubeSearch.videoid(from: link) else { ToastCenter.shared.show("that isn't a youtube link or id"); return }
        looking = true
        Task { @MainActor in
            let hit = await YouTubeSearch.search(id).first(where: { $0.id == id })
            looking = false
            select(hit ?? YouTubeCandidate(id: id, title: "youtube video \(id)", channel: "", duration: nil))
            link = ""
        }
    }

    private func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true
        Task { @MainActor in
            results = Array(await YouTubeSearch.search(q).prefix(15))
            searching = false
            if results.isEmpty { ToastCenter.shared.show("no results") }
        }
    }

    private func select(_ c: YouTubeCandidate) {
        let v = YouTubeVideo(id: c.id, title: c.title, channel: c.channel, duration: c.duration)
        let p = YouTubeImportPlanner.parse(v)
        video = v
        title = p.title
        artist = p.artist ?? c.channel
        album = ""
        usespotify = false
        item = nil
        matching = false
    }

    private func matchnow() {
        guard let v = video, auth.connected else { usespotify = false; return }
        matching = true
        Task { @MainActor in
            let planned = await planner.plan(v, api: Services.shared.api)
            guard usespotify, video?.id == v.id else { return }      // switched off or another video picked meanwhile
            item = planned
            matching = false
        }
    }

    private func save() {
        guard let v = video else { return }
        let track: Track
        if spotifymatched, let it = item {
            track = it.track
            library.addtolibrary(track, via: "youtube import")
            library.confirmsource(track, video: it.source, realduration: it.verified?.realduration, score: it.sourcescore ?? it.verified?.score, auto: false)
        } else {
            let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            let by = artist.trimmingCharacters(in: .whitespacesAndNewlines)
            track = Track(id: Track.ytprefix + v.id, title: name, artist: by.isEmpty ? v.channel : by, album: album.trimmingCharacters(in: .whitespacesAndNewlines),
                          artwork: YouTubeSearch.thumbnail(v.id)?.absoluteString, duration: v.duration ?? 0)
            library.addtolibrary(track, via: "youtube import")
            // the confirmed mapping is what makes it play from exactly this video
            library.confirmsource(track, video: v.candidate, realduration: v.duration, score: nil, auto: false)
        }
        resolver.forget(track.id)
        ToastCenter.shared.show("added \(track.title)")
        added = track
    }

    private func reset() {
        added = nil; video = nil; item = nil; usespotify = false; matching = false
        title = ""; artist = ""; album = ""; link = ""
    }
}
