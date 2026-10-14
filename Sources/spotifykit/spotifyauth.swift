import Foundation
import AuthenticationServices
import CryptoKit
import UIKit

enum SpotifyError: Error {
    case notconnected, premiumrequired, nodevice, quota, rate(Int), http(Int, String), badresponse, network
}

final class SpotifyAuth: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published private(set) var connected = false
    @Published private(set) var busy = false
    @Published var lasterror: String?
    @Published private(set) var account: String?
    @Published private(set) var verified = false
    // true once spotify has granted the streaming scope (needed by librespot); older logins lack it and must reconnect once
    @Published private(set) var streamingscope = UserDefaults.standard.bool(forKey: "wolfified.spotify.streaming")

    // the user's own client id (see ClientIDStore). it can change while the app runs, so it is not a constant.
    private(set) var clientid: String
    // scopes spotify says it granted, saved so a login made before the web playback sdk was added can be detected
    @Published private(set) var grantedscopes: Set<String>? = SpotifyAuth.loadscopes()
    private var session: ASWebAuthenticationSession?
    private var access: String?
    private var expiry = Date.distantPast
    private let tokenRefresh = SpotifyTokenRefresh()
    // the web playback sdk needs streaming + user-read-email + user-read-private; the rest is furmuse's existing api use
    static let requiredscopes = ["streaming", "user-read-email", "user-read-private", "user-read-playback-state", "user-modify-playback-state"]
    private let scopes = "user-read-private user-read-email user-read-playback-state user-modify-playback-state user-read-currently-playing user-library-read playlist-read-private playlist-read-collaborative streaming"

    init(clientid: String) {
        self.clientid = clientid
        super.init()
        connected = Keychain.get("spotify.refresh") != nil
    }

    private static func loadscopes() -> Set<String>? {
        guard let s = UserDefaults.standard.string(forKey: "wolfified.spotify.scopes") else { return nil }
        return Set(s.split(separator: " ").map(String.init))
    }

    // nil = unknown yet (a token refresh fills it in); false = a required scope is missing, reconnect once
    var scopesok: Bool? {
        guard let g = grantedscopes else { return nil }
        return SpotifyAuth.requiredscopes.allSatisfy { g.contains($0) }
    }

    var missingscopes: [String] {
        guard let g = grantedscopes else { return [] }
        return SpotifyAuth.requiredscopes.filter { !g.contains($0) }
    }

    // stores the id the user entered. a different id means the old tokens belong to another app, so the login is dropped.
    // returns nil on success, otherwise the reason it was refused.
    @discardableResult
    func setclientid(_ raw: String) -> String? {
        let id = ClientIDStore.normalize(raw)
        guard ClientIDStore.valid(id) else { return "a spotify client id is 32 characters (0-9, a-f)" }
        if id != clientid {
            if connected { disconnect() }
            ClientIDStore.save(id)
            objectWillChange.send()
            clientid = id
            lasterror = nil
            Log.i(.auth, "spotify client id changed (length \(id.count))")
        } else {
            ClientIDStore.save(id)
        }
        return nil
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap { $0.windows }.first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }

    private static func b64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    func connect() {
        guard !clientid.isEmpty else { lasterror = "enter your spotify client id first (setup, or settings → spotify)"; return }
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let verifier = String((0..<96).map { _ in chars[Int.random(in: 0..<chars.count)] })
        let challenge = SpotifyAuth.b64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = UUID().uuidString
        var c = URLComponents(string: "https://accounts.spotify.com/authorize")!
        c.queryItems = [
            .init(name: "client_id", value: clientid), .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: AppConfig.spotifyredirecturi), .init(name: "scope", value: scopes),
            .init(name: "code_challenge_method", value: "S256"), .init(name: "code_challenge", value: challenge),
            .init(name: "state", value: state)
        ]
        busy = true
        lasterror = nil
        let s = ASWebAuthenticationSession(url: c.url!, callbackURLScheme: AppConfig.spotifyredirectscheme) { [weak self] url, error in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if let error = error {
                    self.busy = false
                    if (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin { self.lasterror = error.localizedDescription }
                    return
                }
                let items = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
                guard items.first(where: { $0.name == "state" })?.value == state,
                      let code = items.first(where: { $0.name == "code" })?.value else {
                    self.busy = false
                    self.lasterror = items.first(where: { $0.name == "error" })?.value ?? "spotify sign-in failed (state mismatch)"
                    return
                }
                Task { @MainActor in
                    do {
                        try await self.exchange(["grant_type": "authorization_code", "code": code, "redirect_uri": AppConfig.spotifyredirecturi, "client_id": self.clientid, "code_verifier": verifier])
                    } catch {
                        if self.lasterror == nil { self.lasterror = "spotify token exchange failed" }
                    }
                    self.busy = false
                    await self.verify()
                }
            }
        }
        s.presentationContextProvider = self
        s.prefersEphemeralWebBrowserSession = false
        session = s
        if !s.start() { busy = false; lasterror = "could not open spotify sign-in" }
    }

    func disconnect() {
        Keychain.remove("spotify.refresh")
        access = nil
        expiry = .distantPast
        connected = false
        account = nil
        verified = false
        streamingscope = false
        grantedscopes = nil
        UserDefaults.standard.removeObject(forKey: "wolfified.spotify.scopes")
        UserDefaults.standard.set(false, forKey: "wolfified.spotify.streaming")
        Task { await tokenRefresh.cancel() }
        Log.i(.auth, "spotify disconnected")
    }

    // a refresh token alone proves nothing: ask spotify who we are
    @MainActor
    func verify() async {
        guard connected else { return }
        do {
            let tok = try await token()
            var req = URLRequest(url: URL(string: "https://api.spotify.com/v1/me")!)
            req.setValue("Bearer " + tok, forHTTPHeaderField: "Authorization")
            req.timeoutInterval = 15
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200:
                let j = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
                account = (j["display_name"] as? String) ?? (j["id"] as? String)
                verified = true
                lasterror = nil
            case 401:
                disconnect()
                fail("spotify rejected the saved login, connect again")
            case 403:
                verified = false
                fail("spotify refused this account for this app (add it under users in the spotify developer dashboard)")
            default:
                verified = false
                fail("couldn't check the spotify account (\(code))")
            }
        } catch {
            verified = false   // offline etc: not proof the login is bad
        }
    }

    private func fail(_ text: String) {
        lasterror = text
        ToastCenter.shared.show(text, route: .spotify)
    }

    @MainActor
    private func exchange(_ form: [String: String]) async throws {
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }.joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let at = j["access_token"] as? String else {
            let desc = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error_description"] as? String
            if code == 400 || code == 401 { disconnect() }
            if let d = desc { lasterror = "spotify: \(d)" }
            throw SpotifyError.http(code, "token")
        }
        access = at
        expiry = Date().addingTimeInterval((j["expires_in"] as? Double ?? 3600) - 60)
        if let r = j["refresh_token"] as? String { Keychain.set(r, "spotify.refresh") }
        if let sc = j["scope"] as? String {
            grantedscopes = Set(sc.split(separator: " ").map(String.init))
            UserDefaults.standard.set(sc, forKey: "wolfified.spotify.scopes")
            streamingscope = sc.split(separator: " ").contains("streaming")
            UserDefaults.standard.set(streamingscope, forKey: "wolfified.spotify.streaming")
        }
        connected = true
    }

    func token(force: Bool = false) async throws -> String {
        if !force, let a = access, expiry > Date() { return a }
        guard let r = Keychain.get("spotify.refresh") else { throw SpotifyError.notconnected }
        return try await tokenRefresh.value { [weak self] in
            guard let self = self else { throw SpotifyError.notconnected }
            // A request may have joined the refresh after another caller already completed it.
            if !force, let a = self.access, self.expiry > Date() { return a }
            Log.i(.auth, "refreshing spotify access token")
            try await self.exchange(["grant_type": "refresh_token", "refresh_token": r, "client_id": self.clientid])
            guard let a = self.access else { throw SpotifyError.notconnected }
            return a
        }
    }
}

// The SDK bridge, startup verification and Web API can all ask for a token at once. Spotify refresh tokens may rotate,
// so those callers must share one refresh operation rather than racing several token endpoint requests.
private actor SpotifyTokenRefresh {
    private var inflight: Task<String, Error>?

    func value(_ operation: @escaping () async throws -> String) async throws -> String {
        if let inflight = inflight { return try await inflight.value }
        let task = Task { try await operation() }
        inflight = task
        do {
            let token = try await task.value
            inflight = nil
            return token
        } catch {
            inflight = nil
            throw error
        }
    }

    func cancel() {
        inflight?.cancel()
        inflight = nil
    }
}
