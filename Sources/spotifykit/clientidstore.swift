import Foundation

// the spotify client id the user entered during setup. it lives in the keychain and is never logged.
enum ClientIDStore {
    enum Origin: String { case entered, build, none }
    enum CheckResult { case ok, rejected, unreachable }

    private static let keychainkey = "spotify.clientid"

    static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // spotify client ids are 32 hex characters
    static func valid(_ id: String) -> Bool {
        id.count == 32 && id.allSatisfy { $0.isHexDigit }
    }

    static var entered: String? {
        guard let v = Keychain.get(keychainkey) else { return nil }
        let n = normalize(v)
        return valid(n) ? n : nil
    }

    static func save(_ id: String) { Keychain.set(normalize(id), keychainkey) }
    static func clear() { Keychain.remove(keychainkey) }

    // Playback always uses the id explicitly entered by the user. A value in an old build configuration is deliberately
    // ignored: silently authenticating against a developer id makes OAuth ownership and quota failures very hard to see.
    static func effective(bundle: Bundle = .main) -> (id: String, origin: Origin) {
        if let e = entered { return (e, .entered) }
        return ("", .none)
    }

    // asks spotify's authorize endpoint whether it knows this client id together with furmuse's redirect uri.
    // nothing is followed or stored. .unreachable (offline, odd status) never blocks saving the id.
    static func check(_ id: String) async -> CheckResult {
        var c = URLComponents(string: "https://accounts.spotify.com/authorize")!
        c.queryItems = [
            .init(name: "client_id", value: id), .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: AppConfig.spotifyredirecturi),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: String(repeating: "a", count: 43)),
            .init(name: "state", value: "check")
        ]
        guard let url = c.url else { return .unreachable }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (_, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200, 301, 302, 303, 307, 308: return .ok
            case 400: return .rejected
            default: return .unreachable
            }
        } catch {
            return .unreachable
        }
    }
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
