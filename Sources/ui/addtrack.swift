import SwiftUI
import UniformTypeIdentifiers

// add a song that only exists as a file on this phone (unreleased, a demo...).
// needs the audio file, a cover, a name and an artist. lyrics are optional.
struct AddTrackView: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var lyrics: LyricsStore
    @Environment(\.presentationMode) private var presentation
    @State private var audio: URL?
    @State private var cover: UIImage?
    @State private var title = ""
    @State private var artist = ""
    @State private var album = ""
    @State private var lyricstext = ""
    @State private var pickingaudio = false
    @State private var pickingcover = false
    @State private var saving = false

    private var ready: Bool {
        audio != nil && cover != nil
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("song file")) {
                    Button { pickingaudio = true } label: {
                        HStack {
                            Image(systemName: audio == nil ? "waveform.badge.plus" : "checkmark.circle.fill")
                                .foregroundColor(audio == nil ? .accentColor : .green)
                            Text(audio?.lastPathComponent ?? "choose audio file").lineLimit(1)
                        }
                    }
                }
                Section(header: Text("cover")) {
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
                Section(header: Text("details")) {
                    TextField("song name", text: $title)
                    TextField("artist", text: $artist)
                    TextField("album", text: $album)
                }
                Section(header: Text("lyrics (optional)"), footer: Text("plain words, or lines with timestamps like [00:12.00].")) {
                    TextEditor(text: $lyricstext).frame(minHeight: 120)
                }
            }
            .animation(.softease, value: ready)
            .navigationTitle("add a song")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("cancel") { presentation.wrappedValue.dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) { Button("add") { add() }.disabled(!ready || saving) }
            }
            .fileImporter(isPresented: $pickingaudio, allowedContentTypes: [.audio], allowsMultipleSelection: false) { result in
                guard case .success(let urls) = result, let u = urls.first else { return }
                audio = u
                if title.trimmingCharacters(in: .whitespaces).isEmpty { title = u.deletingPathExtension().lastPathComponent }
            }
            .sheet(isPresented: $pickingcover) { ImagePicker { cover = $0 } }
        }
        .navigationViewStyle(.stack)
    }

    private func add() {
        guard let audio = audio, let cover = cover else { return }
        saving = true
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let by = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let release = album.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let track = library.addlocaltrack(title: name, artist: by, album: release, cover: cover, audio: audio) else {
            ToastCenter.shared.show("couldn't read that audio file")
            saving = false
            return
        }
        let words = lyricstext.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            if !words.isEmpty { await lyrics.save(words, ext: "lrc", for: track) }
            ToastCenter.shared.show("added \(name)")
            presentation.wrappedValue.dismiss()
        }
    }
}
