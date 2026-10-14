import SwiftUI

// asks for the user's own spotify client id, validates it, and stores it in the keychain.
// used by the setup flow (step 1) and by settings → spotify. the id is never displayed back after saving.
struct ClientIDSection: View {
    @EnvironmentObject var store: SetupStore
    @EnvironmentObject var auth: SpotifyAuth
    @State private var text = ""
    @State private var checking = false
    @State private var message: String?
    @State private var good = false

    private var originlabel: String {
        switch store.config.spotifyclientidorigin {
        case .entered: return "saved"
        case .build: return "missing"
        case .none: return "missing"
        }
    }

    var body: some View {
        Section(header: Text("spotify client id"),
                footer: Text("make a free app at developer.spotify.com/dashboard. tick \"Web Playback SDK\" and \"Web API\", add wolfified://callback as the redirect address, then paste its client id here.")) {
            KeyValue(key: "client id", value: originlabel)
            TextField("paste client id", text: $text)
                .autocapitalization(.none).disableAutocorrection(true)
            Button(checking ? "checking…" : "save") { save() }
                .disabled(checking || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let m = message { Text(m).font(.footnote).foregroundColor(good ? .green : .orange) }
        }
    }

    private func save() {
        let id = ClientIDStore.normalize(text)
        guard ClientIDStore.valid(id) else {
            good = false
            message = "that doesn't look right. copy the client id from your app in the spotify dashboard."
            return
        }
        // Persist first. Network verification is useful feedback, but a temporary Spotify outage
        // must never make a correctly entered key disappear.
        if let err = auth.setclientid(id) { good = false; message = err; return }
        store.reloadconfig()
        text = ""
        checking = true
        good = true
        message = "saved. checking with spotify…"
        Task { @MainActor in
            let result = await ClientIDStore.check(id)
            if result == .rejected {
                good = false
                message = "saved, but spotify rejected it. check the client id and redirect address, then replace it."
                checking = false
                return
            }
            good = true
            message = result == .ok
                ? "saved. now connect your spotify account."
                : "saved, but spotify couldn't be reached to check it."
            checking = false
        }
    }
}
