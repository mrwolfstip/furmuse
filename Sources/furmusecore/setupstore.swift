import Foundation

final class SetupStore: ObservableObject {
    @Published private(set) var state: SetupState
    @Published private(set) var config: AppConfig

    private let defaults: UserDefaults
    private let storagekey = "wolfified.setupstate.v1"

    init(defaults: UserDefaults = .standard, config: AppConfig = AppConfig.load()) {
        self.defaults = defaults
        self.config = config
        if let data = defaults.data(forKey: storagekey),
           let saved = try? JSONDecoder().decode(SetupState.self, from: data) {
            state = saved
        } else {
            state = SetupState()
        }
        refreshfromconfig()
    }

    // duplicates can only happen for the spotify source: those plays are real spotify plays, so a last.fm account
    // that is linked to spotify may also scrobble them. local and youtube plays never reach spotify.
    var doublescrobblepending: Bool {
        state.lastfmlinkedtospotify != false
            && state.lastfmscrobblespotify
            && !state.lastfmdoublescrobbleconfirmed
    }

    func scrobbleenabled(_ kind: SourceKind) -> Bool {
        switch kind {
        case .spotify: return state.lastfmscrobblespotify
        case .local: return state.lastfmscrobblelocal
        case .youtube: return state.lastfmscrobbleyoutube
        }
    }

    func scrobbleallowed(_ kind: SourceKind?) -> Bool {
        guard let k = kind else { return false }
        if k == .spotify && doublescrobblepending { return false }
        return scrobbleenabled(k)
    }

    func setscrobble(_ kind: SourceKind, _ enabled: Bool) {
        update {
            switch kind {
            case .spotify: $0.lastfmscrobblespotify = enabled
            case .local: $0.lastfmscrobblelocal = enabled
            case .youtube: $0.lastfmscrobbleyoutube = enabled
            }
            $0.lastfmscrobbleownplays = $0.lastfmscrobblespotify || $0.lastfmscrobblelocal || $0.lastfmscrobbleyoutube
            if !($0.lastfmscrobblespotify && $0.lastfmlinkedtospotify != false) { $0.lastfmdoublescrobbleconfirmed = false }
        }
        Log.i(.lastfm, "scrobble \(kind.rawValue) source \(enabled ? "on" : "off")")
    }

    func update(_ change: (inout SetupState) -> Void) {
        var next = state
        change(&next)
        guard next != state else { return }
        state = next
        persist()
    }

    // the client id changed (entered in setup or settings): re-read it so every screen sees the new value
    func reloadconfig() {
        config = AppConfig.load()
        refreshfromconfig()
    }

    func completesetup() {
        update { $0.setupcompleted = true }
    }

    func resetlocalsetup() {
        defaults.removeObject(forKey: storagekey)
        state = SetupState()
        refreshfromconfig()
    }

    func setlastfmlinked(_ linked: Bool) {
        update {
            $0.lastfmlinkedtospotify = linked
            if !(linked && $0.lastfmscrobblespotify) { $0.lastfmdoublescrobbleconfirmed = false }
        }
    }

    func confirmdoublescrobble() {
        update { $0.lastfmdoublescrobbleconfirmed = true }
    }

    func acknowledgenotice(_ id: String) {
        update {
            if !$0.acknowledgednotices.contains(id) {
                $0.acknowledgednotices.append(id)
            }
        }
    }

    private func refreshfromconfig() {
        update { s in
            s.spotifyconfigured = config.spotifyconfigured
            s.lastfmconfigured = config.lastfmconfigured
            s.resolverconfigured = false
            if !config.spotifyconfigured {
                s.spotifyauthenticated = false
            }
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: storagekey)
    }
}
