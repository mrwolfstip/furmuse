import SwiftUI

struct SetupView: View {
    @EnvironmentObject var store: SetupStore
    @EnvironmentObject var auth: SpotifyAuth
    @EnvironmentObject var devices: DeviceManager
    @EnvironmentObject var lastfm: LastfmClient
    @EnvironmentObject var resolver: ResolverManager
    @EnvironmentObject var settings: Settings
    @State private var step = 0

    var body: some View {
        NavigationView {
            List {
                Section {
                    Text("welcome to furmuse!").font(.largeTitle.bold())
                    Text("we require some details to fully complete the furmuse experience.")
                        .font(.subheadline).foregroundColor(.secondary)
                    ProgressView(value: Double(step + 1), total: 5)
                    Text("step \(step + 1) of 5").font(.caption).foregroundColor(.secondary)
                }
                if step == 0 {
                    Section(header: Text("spotify")) {
                        ClientIDSection()
                        Button("continue") { step = 1 }.disabled(!store.config.spotifyclientidentered)
                    }
                } else if step == 1 {
                    Section(header: Text("your account"), footer: Text("free accounts can connect for search and playlist importing. spotify playback itself may require premium.")) {
                        KeyValue(key: "status", value: auth.connected ? "connected" : "not connected")
                        if auth.connected { Button("continue") { step = 2 } }
                        else { Button(auth.busy ? "waiting…" : "connect spotify") { auth.connect() }.disabled(auth.busy) }
                    }
                } else if step == 2 {
                    Section(header: Text("last.fm (optional)"), footer: Text("tracks what you listen to.")) {
                        NavigationLink("set up last.fm", destination: LastfmSettingsView())
                        Button(lastfm.loggedin ? "continue" : "skip for now") { step = 3 }
                    }
                } else if step == 3 {
                    Section(header: Text("music"), footer: Text("youtube works right away.")) {
                        NavigationLink("choose where songs play from", destination: SourceSettingsView())
                        Button("continue") { step = 4 }
                    }
                } else {
                    Section(header: Text("all set"), footer: Text("you can change everything later in settings.")) {
                        Button("start listening") { store.completesetup() }
                    }
                }
                if step > 0 {
                    Section { Button("back") { step -= 1 } }
                }
                Section {
                    Button("skip setup for now") { store.completesetup() }
                        .foregroundColor(.secondary)
                }
            }
            .animation(.easeInOut(duration: 0.28), value: step)
            .themed()
            .navigationBarHidden(true)
        }
        .navigationViewStyle(.stack)
    }
}
