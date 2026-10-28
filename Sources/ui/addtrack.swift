import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

// what an audio file says about itself (id3 / mp4 tags)
struct AudioMeta {
    var title: String?
    var artist: String?
    var album: String?
    var artwork: UIImage?
}

enum AudioMetaReader {
    static func read(_ url: URL) async -> AudioMeta {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var meta = AudioMeta()
        let items = (try? await AVURLAsset(url: url).load(.commonMetadata)) ?? []
        func clean(_ s: String?) -> String? {
            let t = s?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return t.isEmpty ? nil : t
        }
        for item in items {
            if item.commonKey == .commonKeyTitle { meta.title = clean(try? await item.load(.stringValue)) }
            else if item.commonKey == .commonKeyArtist { meta.artist = clean(try? await item.load(.stringValue)) }
            else if item.commonKey == .commonKeyAlbumName { meta.album = clean(try? await item.load(.stringValue)) }
            else if item.commonKey == .commonKeyArtwork, meta.artwork == nil {
                if let d = try? await item.load(.dataValue) { meta.artwork = UIImage(data: d) }
            }
        }
        return meta
    }
}

// add songs that only exist as files on this phone (unreleased, a demo...).
// needs the audio file and a name; artist, album, cover and lyrics are optional (the file's own tags are used when it has them).
struct AddTrackView: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var lyrics: LyricsStore
    @Environment(\.presentationMode) private var presentation
    @State private var audios: [URL] = []
    @State private var cover: UIImage?
    @State private var title = ""
    @State private var artist = ""
    @State private var album = ""
    @State private var lyricstext = ""
    @State private var pickingaudio = false
    @State private var pickingcover = false
    @State private var saving = false
    @State private var importstates: [String: String] = [:]

    private var single: Bool { audios.count == 1 }

    // several files get their names from the files themselves, so only a single file needs a typed title
    private var ready: Bool {
        !audios.isEmpty && (audios.count > 1 || !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("song file")) {
                    Button { pickingaudio = true } label: {
                        HStack {
                            Image(systemName: audios.isEmpty ? "waveform.badge.plus" : "checkmark.circle.fill")
                                .foregroundColor(audios.isEmpty ? .accentColor : .green)
                            Text(audios.isEmpty ? "choose audio files" : (single ? audios[0].lastPathComponent : "\(audios.count) files chosen")).lineLimit(1)
                        }
                    }
                    if saving {
                        ForEach(audios, id: \.self) { url in
                            HStack {
                                Text(url.lastPathComponent).lineLimit(1)
                                Spacer()
                                Text(importstates[url.absoluteString] ?? "waiting").font(.caption).foregroundColor(.secondary)
                                if importstates[url.absoluteString] == "copying" { ProgressView().controlSize(.small) }
                            }
                        }
                    }
                }
                if audios.count <= 1 {
                Section(header: Text("cover (optional)")) {
                    Button { pickingcover = true } label: {
                        HStack(spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.gray.opacity(0.2))
                                if let c = cover {
                                    Image(uiImage: c).resizable().scaledToFill()
                                } else {
                                    Image(systemName: "photo").foregroundColor(.secondary)
                                }
                            }
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            Text(cover == nil ? "choose a picture" : "change picture")
                        }
                    }
                }
                }
                Section(header: Text("details"), footer: Text(audios.count > 1 ? "each song takes its name, cover and tags from its own file. artist and album, when filled in, apply to every file." : "filled in from the file when it has tags. only the name is needed.")) {
                    if audios.count <= 1 { TextField("song name", text: $title) }
                    TextField("artist (optional)", text: $artist)
                    TextField("album (optional)", text: $album)
                }
                if audios.count <= 1 {
                Section(header: Text("lyrics (optional)"), footer: Text("plain words (saved as unsynced), or lrc lines with timestamps like [00:12.00].")) {
                    TextEditor(text: $lyricstext).frame(minHeight: 120)
                }
                }
            }
            .animation(.softease, value: ready)
            .navigationTitle(audios.count > 1 ? "add songs" : "add a song")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("cancel") { presentation.wrappedValue.dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) { Button("add") { add() }.disabled(!ready || saving) }
            }
            .copyPicker(isPresented: $pickingaudio, types: [.audio], multiple: true) { urls in
                guard !urls.isEmpty else { return }
                audios = urls
                title = ""; cover = nil
                if urls.count == 1 { artist = ""; album = ""; Task { await prefill(urls[0]) } }
            }
            .sheet(isPresented: $pickingcover) { ImagePicker { cover = $0 } }
        }
        .navigationViewStyle(.stack)
    }

    // fill the form from the file's tags (and its embedded artwork); the file name is the fallback title
    private func prefill(_ url: URL) async {
        let m = await AudioMetaReader.read(url)
        guard audios == [url] else { return }          // the user picked something else meanwhile
        title = m.title ?? url.deletingPathExtension().lastPathComponent
        if artist.trimmingCharacters(in: .whitespaces).isEmpty { artist = m.artist ?? "" }
        if album.trimmingCharacters(in: .whitespaces).isEmpty { album = m.album ?? "" }
        if cover == nil { cover = m.artwork }
    }

    private func add() {
        guard !audios.isEmpty else { return }
        saving = true
        let files = audios
        let one = single
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let by = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let release = album.trimmingCharacters(in: .whitespacesAndNewlines)
        let picked = cover
        let words = lyricstext.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            var added = 0
            var lasttrack: Track?
            for url in files {
                guard !Task.isCancelled else { break }
                importstates[url.absoluteString] = "reading"
                var t = name, a = by, al = release, c = picked
                if !one {
                    let m = await AudioMetaReader.read(url)
                    t = m.title ?? url.deletingPathExtension().lastPathComponent
                    if a.isEmpty { a = m.artist ?? "" }
                    if al.isEmpty { al = m.album ?? "" }
                    c = m.artwork
                }
                importstates[url.absoluteString] = "copying"
                // The security-scoped copy and decode check run off the main thread. A failure
                // removes the partial copy and leaves the other selected files untouched.
                if let track = await library.addlocaltrackasync(title: t, artist: a, album: al, cover: c, audio: url) {
                    added += 1; lasttrack = track; importstates[url.absoluteString] = "added"
                } else {
                    importstates[url.absoluteString] = "failed"
                }
            }
            guard added > 0 else {
                ToastCenter.shared.show(one ? "couldn't read that audio file" : "couldn't read those audio files")
                saving = false
                return
            }
            if one, let track = lasttrack, !words.isEmpty { await lyrics.save(words, ext: "lrc", for: track) }
            if one { ToastCenter.shared.show("added \(name)") }
            else { ToastCenter.shared.show(added == files.count ? "added \(added) songs" : "added \(added) of \(files.count) songs") }
            presentation.wrappedValue.dismiss()
        }
    }
}
