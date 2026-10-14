import Foundation

struct AppConfig {
    static let spotifyclientidkey = "wolfified_spotify_client_id"
    static let lastfmapikeykey = "wolfified_lastfm_api_key"
    static let lastfmsharedsecretkey = "wolfified_lastfm_shared_secret"
    static let spotifyredirectscheme = "wolfified"
    static let spotifyredirecturi = "wolfified://callback"

    let spotifyclientid: String
    // where the active client id came from (currently the user's keychain entry or nowhere)
    let spotifyclientidorigin: ClientIDStore.Origin
    let lastfmapikey: String
    let lastfmsharedsecret: String

    var spotifyconfigured: Bool { !spotifyclientid.isEmpty }
    var spotifyclientidentered: Bool { spotifyclientidorigin == .entered }
    var lastfmconfigured: Bool { !lastfmapikey.isEmpty && !lastfmsharedsecret.isEmpty }

    var missingspotifykeys: [String] {
        spotifyclientid.isEmpty ? [AppConfig.spotifyclientidkey] : []
    }

    var missinglastfmkeys: [String] {
        var keys: [String] = []
        if lastfmapikey.isEmpty { keys.append(AppConfig.lastfmapikeykey) }
        if lastfmsharedsecret.isEmpty { keys.append(AppConfig.lastfmsharedsecretkey) }
        return keys
    }

    static func load(bundle: Bundle = .main) -> AppConfig {
        let cid = ClientIDStore.effective(bundle: bundle)
        return AppConfig(
            spotifyclientid: cid.id,
            spotifyclientidorigin: cid.origin,
            lastfmapikey: Keychain.get("lastfm.apiKey") ?? value(lastfmapikeykey, in: bundle),
            lastfmsharedsecret: Keychain.get("lastfm.sharedSecret") ?? value(lastfmsharedsecretkey, in: bundle)
        )
    }

    static func saveLastfm(apiKey: String, secret: String) {
        Keychain.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), "lastfm.apiKey")
        Keychain.set(secret.trimmingCharacters(in: .whitespacesAndNewlines), "lastfm.sharedSecret")
    }

    static func clearLastfm() { Keychain.remove("lastfm.apiKey"); Keychain.remove("lastfm.sharedSecret") }

    // an unresolved build variable survives into info.plist as "$(name)"
    static func value(_ key: String, in bundle: Bundle) -> String {
        guard let raw = bundle.object(forInfoDictionaryKey: key) as? String else { return "" }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("$(") ? "" : trimmed
    }
}
