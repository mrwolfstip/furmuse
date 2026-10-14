import Foundation
import AuthenticationServices
import CryptoKit
import Network
import UIKit

// sign-in used only for librespot (spotify playback). furmuse's own client id (spotifyauth.swift) is for the Web API.
//
// why a second sign-in: librespot asks spotify's login5 service for tokens using the session's client id, and
// clienttoken.spotify.com only accepts spotify's own client ids (a custom developer-app id gets HTTP 400, and a token
// minted for one id gets INVALID_CREDENTIALS when presented under another). so playback uses librespot's built-in
// "keymaster" client id, exactly like the librespot command line's --enable-oauth.
// that id's registered redirect is http://127.0.0.1:8898/login, so a tiny loopback listener catches the code.
// the refresh token lives in the keychain; the access token is memory only. nothing here is ever logged.
final class LibrespotAuth: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = LibrespotAuth()
    static let clientid = "65b708073fc0480ea92a077233ca87bd"
    static let redirect = "http://127.0.0.1:8898/login"
    static let port: UInt16 = 8898
    // the scopes librespot's own oauth login requests (main.rs OAUTH_SCOPES); spotify's client id allows them all
    static let scopes = ["app-remote-control", "playlist-read", "playlist-read-collaborative", "playlist-read-private", "streaming",
                         "user-library-read", "user-modify-playback-state", "user-read-currently-playing", "user-read-playback-state",
                         "user-read-private", "user-read-email"]

    @Published private(set) var connected = Keychain.get("librespot.refresh") != nil
    @Published private(set) var busy = false
    @Published var lasterror: String?

    private var listener: NWListener?
    private var web: ASWebAuthenticationSession?
    private var access: String?
    private var expiry = Date.distantPast
    private var verifier = ""
    private var state = ""
    private var gotcode = false

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap { $0.windows }.first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }

    private static func b64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    @MainActor
    func connect() {
        guard !busy else { return }
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        verifier = String((0..<96).map { _ in chars[Int.random(in: 0..<chars.count)] })
        state = UUID().uuidString
        gotcode = false
        lasterror = nil
        var c = URLComponents(string: "https://accounts.spotify.com/authorize")!
        c.queryItems = [
            .init(name: "client_id", value: Self.clientid), .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Self.redirect), .init(name: "scope", value: Self.scopes.joined(separator: " ")),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: Self.b64url(Data(SHA256.hash(data: Data(verifier.utf8))))),
            .init(name: "state", value: state)
        ]
        busy = true
        do { try startlistener() } catch {
            busy = false; lasterror = "couldn't open the local sign-in port \(Self.port): \(error.localizedDescription)"
            Log.e(.auth, "librespot sign-in listener failed: \(error.localizedDescription)")
            return
        }
        // the page redirects to http://127.0.0.1, which this in-app browser loads from our listener.
        // the callback scheme is never used; the session is cancelled as soon as the listener has the code.
        let s = ASWebAuthenticationSession(url: c.url!, callbackURLScheme: "wolfified-librespot-unused") { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self = self, !self.gotcode else { return }
                self.stoplistener(); self.busy = false     // user closed the sheet
            }
        }
        s.presentationContextProvider = self
        s.prefersEphemeralWebBrowserSession = false
        web = s
        Log.i(.auth, "librespot sign-in started (keymaster client id, loopback redirect)")
        if !s.start() { stoplistener(); busy = false; lasterror = "could not open spotify sign-in" }
    }

    func disconnect() {
        Keychain.remove("librespot.refresh")
        access = nil; expiry = .distantPast; connected = false
        Log.i(.auth, "librespot sign-in removed")
    }

    private func startlistener() throws {
        stoplistener()
        let l = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: Self.port)!)
        l.newConnectionHandler = { [weak self] conn in self?.serve(conn) }
        l.start(queue: .main)
        listener = l
    }

    private func stoplistener() { listener?.cancel(); listener = nil }

    private func serve(_ conn: NWConnection) {
        conn.start(queue: .main)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self = self else { conn.cancel(); return }
            var status = "404 Not Found", body = ""
            if let data = data, let text = String(data: data, encoding: .utf8), let line = text.components(separatedBy: "\r\n").first {
                let parts = line.split(separator: " ")
                if parts.count >= 2, parts[1].hasPrefix("/login"), let comps = URLComponents(string: "http://127.0.0.1" + parts[1]) {
                    status = "200 OK"
                    let items = comps.queryItems ?? []
                    if items.first(where: { $0.name == "state" })?.value == self.state, let code = items.first(where: { $0.name == "code" })?.value {
                        body = "signed in. you can close this and go back to furmuse."
                        self.gotcode = true
                        DispatchQueue.main.async { self.finish(code: code) }
                    } else {
                        body = "sign-in failed. close this and try again."
                        let why = items.first(where: { $0.name == "error" })?.value ?? "state mismatch"
                        DispatchQueue.main.async { self.web?.cancel(); self.stoplistener(); self.busy = false; self.lasterror = "spotify sign-in failed (\(why))" }
                    }
                }
            }
            let html = "<html><head><meta name=viewport content='width=device-width,initial-scale=1'></head><body style='font-family:-apple-system;padding:40px;text-align:center'>\(body)</body></html>"
            let resp = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
            conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
        }
    }

    @MainActor
    private func finish(code: String) {
        web?.cancel(); web = nil
        stoplistener()
        Task { @MainActor in
            do {
                try await self.exchange(["grant_type": "authorization_code", "code": code, "redirect_uri": Self.redirect,
                                         "client_id": Self.clientid, "code_verifier": self.verifier])
                Log.i(.auth, "librespot sign-in complete")
            } catch {
                if self.lasterror == nil { self.lasterror = "spotify token exchange failed" }
                Log.e(.auth, "librespot sign-in token exchange failed")
            }
            self.busy = false
        }
    }

    // a valid access token for librespot's login; refreshed from the keychain refresh token when needed
    func token() async throws -> String {
        if let a = access, expiry > Date().addingTimeInterval(60) { return a }
        guard let r = Keychain.get("librespot.refresh") else { throw SpotifyError.notconnected }
        try await exchange(["grant_type": "refresh_token", "refresh_token": r, "client_id": Self.clientid])
        guard let a = access else { throw SpotifyError.badresponse }
        return a
    }

    @MainActor
    private func exchange(_ form: [String: String]) async throws {
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        req.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&").data(using: .utf8)
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let a = j["access_token"] as? String else {
            if status == 400 || status == 401, form["grant_type"] == "refresh_token" { disconnect(); lasterror = "spotify playback sign-in expired, sign in again" }
            throw SpotifyError.http(status, "token")
        }
        access = a
        expiry = Date().addingTimeInterval((j["expires_in"] as? Double) ?? 3600)
        if let r = j["refresh_token"] as? String { Keychain.set(r, "librespot.refresh") }
        connected = Keychain.get("librespot.refresh") != nil
        let granted = ((j["scope"] as? String) ?? "").split(separator: " ")
        Log.i(.auth, "librespot token ok, expires in \(Int(expiry.timeIntervalSinceNow))s, streaming scope: \(granted.contains("streaming") ? "yes" : "no")")
    }
}
