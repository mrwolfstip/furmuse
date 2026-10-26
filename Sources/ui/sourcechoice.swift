import SwiftUI
import UniformTypeIdentifiers

// per-track audio source: attach a local file and/or pin a source. all of this is furmuse-local overlay data;
// the spotify id is never touched, and local or youtube playback sends nothing to spotify.
struct TrackSourceSection: View {
    let track: Track
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var auth: SpotifyAuth
    @State private var importing = false

    private var choice: SourceChoice? { library.data.sources[track.id] }

    var body: some View {
        Section(header: Text("play this song from"), footer: Text("attached files are copied into furmuse.")) {
            Picker("source", selection: Binding(get: { library.preferred(track.id)?.rawValue ?? "default" }, set: { library.setpreferred(track.id, SourceKind(rawValue: $0)) })) {
                Text("default").tag("default")
                Text("spotify").tag(SourceKind.spotify.rawValue)
                Text("local file").tag(SourceKind.local.rawValue)
                Text("youtube").tag(SourceKind.youtube.rawValue)
            }
            if library.preferred(track.id) == .spotify, let why = LibrespotSession.shared.blocker(auth: auth) {
                Text("spotify isn't ready: \(why)").font(.footnote).foregroundColor(.orange)
            }
            if let n = choice?.localname { KeyValue(key: "local file", value: n) }
            Button(choice?.localaudio == nil ? "attach an audio file" : "replace audio file") { importing = true }
            if choice?.localaudio != nil { Button("remove file", role: .destructive) { library.detachlocal(track.id) } }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let u = urls.first else { return }
            Task { @MainActor in
                if await library.attachlocalasync(track.id, from: u) { ToastCenter.shared.show("file attached") }
                else { ToastCenter.shared.show("couldn't read that file") }
            }
        }
    }
}

struct DiagnosticsView: View {
    @State private var lines: [String] = []
    @State private var exportURL: URL?
    @State private var sharing = false

    var body: some View {
        List {
            Section(footer: Text("passwords and keys are hidden from this report.")) {
                Button("refresh") { load() }
                Button("share report") { Log.shared.exportfile { exportURL = $0; sharing = $0 != nil } }
                Button("clear report", role: .destructive) { Log.shared.clear(); lines = [] }
            }
            Section(header: Text("recent")) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                    Text(l).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                }
            }
        }
        .themed().navigationTitle("problem report").navigationBarTitleDisplayMode(.inline)
        .onAppear { load() }
        .sheet(isPresented: $sharing) { if let u = exportURL { ShareSheet(url: u) } }
    }

    private func load() { Log.shared.tail(200) { lines = $0.reversed() } }
}
