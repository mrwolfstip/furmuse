import SwiftUI

// YouTube playlist import: fetch -> match every video to a Spotify track + the most likely YouTube source -> show ALL of it for review
// (uncertain ones flagged) -> nothing is added until the user confirms.
struct YouTubeImportView: View {
    @EnvironmentObject var auth: SpotifyAuth
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var resolver: ResolverManager
    @Environment(\.presentationMode) private var presentation
    @StateObject private var planner = YouTubeImportPlanner()
    @State private var link = ""
    @State private var onlyreview = false
    @State private var editing: UUID?
    @State private var task: Task<Void, Never>?

    var body: some View {
        NavigationView {
            Group {
                switch planner.phase {
                case .idle: startview
                case .fetching: progressview(title: "reading the playlist…", detail: "\(planner.found) videos found", value: nil)
                case .matching: progressview(title: "matching tracks…", detail: "\(planner.done) of \(planner.total)", value: Double(planner.done) / Double(max(planner.total, 1)))
                case .ready: reviewview
                case .failed(let why): failedview(why)
                }
            }
            .themed()
            .navigationTitle("import youtube playlist").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarLeading) { Button("cancel") { task?.cancel(); planner.cancel(); presentation.wrappedValue.dismiss() } } }
        }
        .navigationViewStyle(.stack)
    }

    private var startview: some View {
        Form {
            Section(footer: Text("paste a youtube playlist link. you can review everything before it's added.")) {
                TextField("youtube playlist link", text: $link).autocapitalization(.none).disableAutocorrection(true).keyboardType(.URL)
                Button("find tracks") { start() }.disabled(YouTubePlaylist.playlistid(from: link) == nil)
            }
            if !auth.connected {
                Section { Text("connect spotify in settings first.").foregroundColor(.orange).font(.footnote) }
            }
        }
    }

    private func start() {
        guard auth.connected else { ToastCenter.shared.show("connect spotify in settings first", route: .spotify); return }
        task = Task { await planner.run(link: link, api: Services.shared.api) }
    }

    private func progressview(title: String, detail: String, value: Double?) -> some View {
        VStack(spacing: 16) {
            Spacer()
            if let v = value { ProgressView(value: v).padding(.horizontal, 40) } else { ProgressView() }
            Text(title).font(.headline)
            Text(detail).foregroundColor(.secondary)
            Button("stop", role: .destructive) { task?.cancel(); planner.cancel() }
            Spacer()
        }
    }

    private func failedview(_ why: String) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundColor(.orange)
            Text(why).multilineTextAlignment(.center).padding(.horizontal, 30)
            Button("try again") { start() }.buttonStyle(.bordered)
            Spacer()
        }
    }

    // ---- review --------------------------------------------------------------------------------------------------------
    private var shown: [YouTubeImportPlanner.Item] { onlyreview ? planner.items.filter { $0.confidence != .good } : planner.items }

    private var reviewview: some View {
        List {
            Section(footer: Text("\(planner.items.count) videos found. green = good match, orange = please check, grey = no spotify match. tap a row to change it. only ticked songs are added.")) {
                Toggle("show only tracks that need checking (\(planner.reviewcount))", isOn: $onlyreview)
            }
            Section {
                ForEach($planner.items) { $it in
                    if !onlyreview || it.confidence != .good {
                        HStack(spacing: 10) {
                            Button { it.include.toggle() } label: {
                                Image(systemName: it.include ? "checkmark.circle.fill" : "circle").foregroundColor(it.include ? .accentColor : .secondary).font(.title3)
                            }.buttonStyle(.plain)
                            Button { editing = it.id } label: { row(it) }.buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button { confirm() } label: {
                Text("import \(planner.includedcount) tracks").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent).padding(.horizontal, 16).padding(.bottom, 8)
            .disabled(planner.includedcount == 0)
        }
        .sheet(item: Binding(get: { editing.map { EditTarget(id: $0) } }, set: { editing = $0?.id })) { t in
            if let i = planner.items.firstIndex(where: { $0.id == t.id }) {
                ImportItemEditor(item: $planner.items[i])
            }
        }
    }

    private struct EditTarget: Identifiable { let id: UUID }

    private func badge(_ c: YouTubeImportPlanner.Confidence) -> (String, Color) {
        switch c {
        case .good: return ("good match", .green)
        case .review: return ("check this", .orange)
        case .nospotify: return ("no spotify match", .gray)
        }
    }

    private func row(_ it: YouTubeImportPlanner.Item) -> some View {
        let b = badge(it.confidence)
        return HStack(spacing: 10) {
            AsyncImage(url: YouTubeSearch.thumbnail(it.source.id)) { img in img.resizable().aspectRatio(contentMode: .fill) } placeholder: { Color.gray.opacity(0.2) }
                .frame(width: 72, height: 40).clipShape(RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 2) {
                Text(it.track.title).font(.subheadline.weight(.semibold)).foregroundColor(.primary).lineLimit(1)
                Text(it.track.artist).font(.caption).foregroundColor(.secondary).lineLimit(1)
                Text("▶ \(it.source.title) · \(it.source.channel) · \(it.source.duration.map { fmttime($0) } ?? "?")").font(.caption2).foregroundColor(.secondary).lineLimit(1)
                Text(([b.0] + it.notes).joined(separator: " · ")).font(.caption2.weight(.semibold)).foregroundColor(b.1).lineLimit(2)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
        }
        .contentShape(Rectangle())
    }

    private func confirm() {
        let chosen = planner.items.filter { $0.include }
        // spotify-matched tracks keep their spotify identity; youtube-only ones are saved under a yt_ id. each gets its confirmed source.
        library.importyoutube(id: planner.playlistid, name: planner.playlisttitle,
                              items: chosen.map { (track: $0.track, video: $0.source, realduration: $0.verified?.realduration, score: $0.sourcescore ?? $0.verified?.score) })
        chosen.forEach { resolver.forget($0.track.id) }
        ToastCenter.shared.show("imported \(chosen.count) tracks into \"\(planner.playlisttitle)\"")
        presentation.wrappedValue.dismiss()
    }
}

// change one item: its Spotify match and/or its YouTube source
struct ImportItemEditor: View {
    @Binding var item: YouTubeImportPlanner.Item
    @Environment(\.presentationMode) private var presentation
    @State private var choosingsource = false
    @State private var query = ""
    @State private var results: [Track] = []
    @State private var searching = false

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("the playlist's video")) {
                    Text(item.video.title).lineLimit(3)
                    Text("\(item.video.channel) · \(item.video.duration.map { fmttime($0) } ?? "?")").font(.caption).foregroundColor(.secondary)
                }
                Section(header: Text(item.spotifymatched ? "spotify track" : "no spotify match yet")) {
                    HStack(spacing: 12) {
                        TrackArt(track: item.track, size: 50)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.track.title).font(.headline).lineLimit(2)
                            Text(item.track.artist).font(.subheadline).foregroundColor(.secondary)
                            Text(fmttime(item.track.duration)).font(.caption).foregroundColor(.secondary)
                        }
                    }
                    HStack {
                        TextField("search spotify for the right track", text: $query).submitLabel(.search).autocapitalization(.none).disableAutocorrection(true)
                            .onSubmit { search() }
                        if searching { ProgressView() } else if !query.isEmpty { Button("search") { search() } }
                    }
                    ForEach(results) { t in
                        Button { usespotify(t) } label: {
                            HStack(spacing: 12) {
                                TrackArt(track: t, size: 40)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(t.title).foregroundColor(.primary).lineLimit(1)
                                    Text("\(t.artist) · \(fmttime(t.duration))").font(.caption).foregroundColor(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                }
                Section(header: Text("youtube source"), footer: Text(item.verified.map { $0.level == .verified ? "verified against the spotify track" : "chosen by you; \($0.reasons.joined(separator: ", "))" } ?? "")) {
                    Text(item.source.title).lineLimit(3)
                    Text("\(item.source.channel) · \(item.source.duration.map { fmttime($0) } ?? "?")").font(.caption).foregroundColor(.secondary)
                    Button("choose a different youtube video") { choosingsource = true }
                }
            }
            .themed()
            .navigationTitle("edit match").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("done") { presentation.wrappedValue.dismiss() } } }
            .sheet(isPresented: $choosingsource) {
                YouTubeSourcePicker(track: item.track, currentvideo: item.source.id) { c, v in
                    item.source = c
                    item.verified = v
                    item.sourcescore = v.score
                    item.confidence = item.spotifymatched ? (v.level == .verified ? .good : .review) : .nospotify
                    item.notes = v.level == .verified ? ["source chosen and verified by you"] : ["source chosen by you"] + v.reasons
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear { query = "\(item.track.artist.components(separatedBy: ",").first ?? "") \(item.track.title)".trimmingCharacters(in: .whitespaces) }
    }

    private func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true
        Task { @MainActor in
            results = (try? await Services.shared.api.search(q)) ?? []
            searching = false
        }
    }

    // the spotify track becomes canonical; the video stays the source and is re-scored against the new track
    private func usespotify(_ t: Track) {
        item.track = t
        item.spotifymatched = true
        item.verified = nil
        let s = YouTubeMatcher.score(item.source, for: t)
        item.sourcescore = s.score
        item.confidence = (s.score ?? 0) >= 0.85 ? .good : .review
        item.notes = ["spotify match chosen by you"] + ((s.score ?? 0) >= YouTubeMatcher.threshold ? [] : ["the video may not match this track: \(s.reason.isEmpty ? "weak match" : s.reason)"])
        results = []
    }
}
