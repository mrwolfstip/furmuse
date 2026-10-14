import SwiftUI

// the source-selection popup. the Spotify track is the identity; this picks (and verifies) the YouTube video that provides its audio.
// used from search (confirm, add to library, play) and from the playlist import review (change one item). nothing is saved here:
// onchoose is only called after the video was checked against the track and, if the check wasn't clean, the user said "use anyway".
struct YouTubeSourcePicker: View {
    let track: Track
    var currentvideo: String?
    let onchoose: (YouTubeCandidate, SourceVerdict) -> Void
    @Environment(\.presentationMode) private var presentation

    @State private var candidates: [YouTubeCandidate] = []
    @State private var selected: YouTubeCandidate?
    @State private var query = ""
    @State private var link = ""
    @State private var loading = true
    @State private var verifying = false
    @State private var warning: (c: YouTubeCandidate, v: SourceVerdict)?
    @State private var rejected: String?

    private func dur(_ d: Double?) -> String { d.map { fmttime($0) } ?? "?" }

    private func order(_ cs: [YouTubeCandidate]) -> [YouTubeCandidate] {
        // good matches first (best score first), then the rest in search order
        let scored = cs.enumerated().map { (i, c) in (i, c, SourceVerifier.quick(c, for: track)) }
        let good = scored.filter { $0.2.good }.sorted { ($0.2.score ?? 0) > ($1.2.score ?? 0) }
        let rest = scored.filter { !$0.2.good }
        return (good + rest).map { $0.1 }
    }

    private func load(_ q: String? = nil) async {
        loading = true
        let found = q == nil ? await YouTubeSearch.candidates(for: track) : await YouTubeSearch.search(q!)
        candidates = order(found)
        if selected == nil {
            if let cur = currentvideo, let c = candidates.first(where: { $0.id == cur }) { selected = c }
            else if let first = candidates.first, SourceVerifier.quick(first, for: track).good { selected = first }   // preselected, never auto-saved
        }
        loading = false
    }

    private func usepasted() {
        guard let id = YouTubeSearch.videoid(from: link) else { ToastCenter.shared.show("that isn't a youtube link or id"); return }
        Task { @MainActor in
            loading = true
            let hit = await YouTubeSearch.search(id).first(where: { $0.id == id })
            let c = hit ?? YouTubeCandidate(id: id, title: "youtube video \(id)", channel: "", duration: nil)
            if !candidates.contains(where: { $0.id == id }) { candidates.insert(c, at: 0) }
            selected = c
            link = ""
            loading = false
        }
    }

    private func confirm(_ c: YouTubeCandidate) {
        verifying = true
        Task { @MainActor in
            let v = await SourceVerifier.verify(c, for: track)
            verifying = false
            switch v.level {
            case .verified: onchoose(c, v); presentation.wrappedValue.dismiss()
            case .uncertain: warning = (c, v)
            case .rejected: rejected = v.reasons.first ?? "that video can't be used"
            }
        }
    }

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("spotify track")) {
                    HStack(spacing: 12) {
                        TrackArt(track: track, size: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title).font(.headline).lineLimit(2)
                            Text(track.artist).font(.subheadline).foregroundColor(.secondary).lineLimit(1)
                            Text("\(track.album.isEmpty ? "" : track.album + " · ")\(fmttime(track.duration))").font(.caption).foregroundColor(.secondary).lineLimit(1)
                        }
                    }
                }
                Section(header: Text("search youtube"), footer: Text("your pick is checked before it's saved.")) {
                    HStack {
                        TextField("search for a different video", text: $query).submitLabel(.search).autocapitalization(.none).disableAutocorrection(true)
                            .onSubmit { let q = query.trimmingCharacters(in: .whitespaces); if !q.isEmpty { Task { await load(q) } } }
                        if !query.isEmpty { Button("search") { let q = query; Task { await load(q) } } }
                    }
                    HStack {
                        TextField("or paste a youtube link / id", text: $link).autocapitalization(.none).disableAutocorrection(true).keyboardType(.URL)
                        if !link.isEmpty { Button("use") { usepasted() } }
                    }
                }
                Section(header: Text(loading ? "searching…" : "results")) {
                    if !loading && candidates.isEmpty { Text("no youtube results").foregroundColor(.secondary) }
                    ForEach(candidates) { c in
                        let q = SourceVerifier.quick(c, for: track)
                        Button { selected = c } label: {
                            HStack(spacing: 12) {
                                AsyncImage(url: YouTubeSearch.thumbnail(c.id)) { img in img.resizable().aspectRatio(contentMode: .fill) } placeholder: { Color.gray.opacity(0.2) }
                                    .frame(width: 96, height: 54).clipShape(RoundedRectangle(cornerRadius: 6))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.title).foregroundColor(.primary).lineLimit(2).font(.subheadline)
                                    Text("\(c.channel.isEmpty ? "unknown channel" : c.channel) · \(dur(c.duration))").font(.caption).foregroundColor(.secondary).lineLimit(1)
                                    Text(q.good ? "good match" : q.text).font(.caption2.weight(.semibold)).foregroundColor(q.good ? .green : .orange)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: selected?.id == c.id ? "checkmark.circle.fill" : "circle").foregroundColor(selected?.id == c.id ? .accentColor : .secondary)
                            }
                        }
                    }
                }
            }
            .themed()
            .navigationTitle("choose youtube source").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("cancel") { presentation.wrappedValue.dismiss() }.disabled(verifying) }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if verifying { ProgressView() }
                    else { Button("use this") { if let c = selected { confirm(c) } }.disabled(selected == nil) }
                }
            }
            .confirmationDialog("this video may not match", isPresented: Binding(get: { warning != nil }, set: { if !$0 { warning = nil } }), titleVisibility: .visible) {
                Button("use anyway") {
                    if let w = warning { onchoose(w.c, w.v); presentation.wrappedValue.dismiss() }
                    warning = nil
                }
                Button("choose another", role: .cancel) { warning = nil }
            } message: { Text((warning?.v.reasons ?? []).joined(separator: "\n")) }
            .alert("can't use this video", isPresented: Binding(get: { rejected != nil }, set: { if !$0 { rejected = nil } })) {
                Button("ok", role: .cancel) { rejected = nil }
            } message: { Text(rejected ?? "") }
        }
        .navigationViewStyle(.stack)
        .task { if candidates.isEmpty { await load() } }
    }
}

// "tap a search result -> maybe ask for a source -> add to library -> play". shared by search and the track menu.
struct PendingSource: Identifiable {
    let track: Track
    let all: [Track]
    let index: Int
    var play = true
    var id: String { track.id }
}

extension View {
    func sourcechooser(_ pending: Binding<PendingSource?>) -> some View { modifier(SourceChooserModifier(pending: pending)) }
}

private struct SourceChooserModifier: ViewModifier {
    @Binding var pending: PendingSource?
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var engine: PlaybackEngine
    @EnvironmentObject var resolver: ResolverManager

    func body(content: Content) -> some View {
        content.sheet(item: $pending) { p in
            YouTubeSourcePicker(track: p.track, currentvideo: library.data.mappings[p.track.id]?.videoid) { c, v in
                library.confirmsource(p.track, video: c, realduration: v.realduration, score: v.score, auto: false)
                library.addtolibrary(p.track, via: "search")
                resolver.forget(p.track.id)
                ToastCenter.shared.show("source saved, added to your library")
                if p.play { engine.play(p.all, at: p.index) }
            }
        }
    }
}
