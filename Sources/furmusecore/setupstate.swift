import Foundation

struct SetupState: Codable, Equatable {
    var setupcompleted = false
    var spotifyconfigured = false
    var spotifyauthenticated = false
    var selecteddeviceid: String?
    var lastfmconfigured = false
    var resolverconfigured = false
    var acknowledgednotices: [String] = []
    var spotifyintegrationenabled = true
    var privatemirrorenabled = false
    var lastfmlinkedtospotify: Bool?
    var lastfmscrobbleownplays = false      // legacy single toggle; kept in sync (true if any source is on)
    var lastfmscrobblespotify = false
    var lastfmscrobblelocal = false
    var lastfmscrobbleyoutube = false
    var lastfmdoublescrobbleconfirmed = false

    init() {}

    private enum CodingKeys: String, CodingKey {
        case setupcompleted
        case spotifyconfigured
        case spotifyauthenticated
        case selecteddeviceid
        case lastfmconfigured
        case resolverconfigured
        case acknowledgednotices
        case spotifyintegrationenabled
        case privatemirrorenabled
        case lastfmlinkedtospotify
        case lastfmscrobbleownplays
        case lastfmscrobblespotify
        case lastfmscrobblelocal
        case lastfmscrobbleyoutube
        case lastfmdoublescrobbleconfirmed
    }

    // decodeIfPresent keeps older saved state readable when fields are added later
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        setupcompleted = try c.decodeIfPresent(Bool.self, forKey: .setupcompleted) ?? false
        spotifyconfigured = try c.decodeIfPresent(Bool.self, forKey: .spotifyconfigured) ?? false
        spotifyauthenticated = try c.decodeIfPresent(Bool.self, forKey: .spotifyauthenticated) ?? false
        selecteddeviceid = try c.decodeIfPresent(String.self, forKey: .selecteddeviceid)
        lastfmconfigured = try c.decodeIfPresent(Bool.self, forKey: .lastfmconfigured) ?? false
        resolverconfigured = try c.decodeIfPresent(Bool.self, forKey: .resolverconfigured) ?? false
        acknowledgednotices = try c.decodeIfPresent([String].self, forKey: .acknowledgednotices) ?? []
        spotifyintegrationenabled = try c.decodeIfPresent(Bool.self, forKey: .spotifyintegrationenabled) ?? true
        privatemirrorenabled = try c.decodeIfPresent(Bool.self, forKey: .privatemirrorenabled) ?? false
        lastfmlinkedtospotify = try c.decodeIfPresent(Bool.self, forKey: .lastfmlinkedtospotify)
        lastfmscrobbleownplays = try c.decodeIfPresent(Bool.self, forKey: .lastfmscrobbleownplays) ?? false
        // migration: before 0.2.1 the one toggle covered every furmuse play, which then meant youtube/downloaded audio.
        // spotify-source scrobbling is new and stays off until the user enables it (and confirms the duplicate warning).
        lastfmscrobblespotify = try c.decodeIfPresent(Bool.self, forKey: .lastfmscrobblespotify) ?? false
        lastfmscrobblelocal = try c.decodeIfPresent(Bool.self, forKey: .lastfmscrobblelocal) ?? lastfmscrobbleownplays
        lastfmscrobbleyoutube = try c.decodeIfPresent(Bool.self, forKey: .lastfmscrobbleyoutube) ?? lastfmscrobbleownplays
        lastfmdoublescrobbleconfirmed = try c.decodeIfPresent(Bool.self, forKey: .lastfmdoublescrobbleconfirmed) ?? false
    }
}
