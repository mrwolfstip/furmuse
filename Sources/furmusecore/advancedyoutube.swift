import Foundation
import CryptoKit
import WebKit
import SwiftUI

enum YouTubeBackend: String, CaseIterable {
    case standard
    case advanced
}

@MainActor
final class GoogleYouTubeAuth: ObservableObject {
    static let shared = GoogleYouTubeAuth()
    private static let key = "youtube.google.cookies"

    @Published private(set) var connected = Keychain.get(key) != nil
    @Published private(set) var lastError: String?

    var cookieHeader: String? { Keychain.get(Self.key) }

    func save(_ cookies: [HTTPCookie]) -> Bool {
        let usable = cookies.filter {
            ($0.domain.hasSuffix("youtube.com") || $0.domain.hasSuffix("google.com")) &&
            ($0.expiresDate == nil || $0.expiresDate! > Date())
        }
        let names = Set(usable.map(\.name))
        guard names.contains("SAPISID") || names.contains("__Secure-3PAPISID") else {
            lastError = "Google sign-in did not return a YouTube session. Open YouTube Music in the sign-in window and try again."
            return false
        }
        let header = usable.sorted { $0.name < $1.name }.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        Keychain.set(header, Self.key)
        connected = true
        lastError = nil
        return true
    }

    func disconnect() {
        Keychain.remove(Self.key)
        connected = false
        lastError = nil
    }
}

struct GoogleYouTubeSignInView: View {
    @Environment(\.presentationMode) private var presentation
    @ObservedObject private var auth = GoogleYouTubeAuth.shared
    @State private var checking = false

    var body: some View {
        NavigationView {
            GoogleYouTubeWebView()
                .navigationTitle("Google sign in")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) { Button("cancel") { presentation.wrappedValue.dismiss() } }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(checking ? "checking…" : "done") { finish() }.disabled(checking)
                    }
                }
        }
        .navigationViewStyle(.stack)
    }

    private func finish() {
        checking = true
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            DispatchQueue.main.async {
                checking = false
                if auth.save(cookies) { presentation.wrappedValue.dismiss() }
                else { ToastCenter.shared.show(auth.lastError ?? "Google sign-in was not completed") }
            }
        }
    }
}

private struct GoogleYouTubeWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        let target = "https://music.youtube.com/"
        let login = "https://accounts.google.com/ServiceLogin?continue=" + (target.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? target)
        view.load(URLRequest(url: URL(string: login)!))
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator: NSObject, WKNavigationDelegate {}
}

private struct AdvancedPlayerResponse: Decodable {
    struct Playability: Decodable { let status: String?; let reason: String? }
    struct Streaming: Decodable {
        struct Format: Decodable {
            let url: String?
            let mimeType: String
            let bitrate: Int?
            let averageBitrate: Int?
            let signatureCipher: String?
        }
        let expiresInSeconds: String?
        let adaptiveFormats: [Format]?
        let formats: [Format]?
    }
    let playabilityStatus: Playability?
    let streamingData: Streaming?
}

enum AdvancedYouTubeClient {
    private static let origin = "https://music.youtube.com"
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    // Public values shipped by the YouTube Music web client. They are only used
    // when Google's iOS-facing bootstrap response omits ytcfg entirely.
    private static let fallbackAPIKey = "AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30"
    private static let fallbackClientVersion = "1.20261025.12.00"

    private struct WebSession {
        let apiKey: String
        let clientVersion: String
        let visitorData: String?
        let authUser: String
        let pageID: String?
    }

    static func search(_ query: String, limit: Int = 20) async -> [YouTubeCandidate] {
        let web: WebSession
        if let cookie = await MainActor.run(body: { GoogleYouTubeAuth.shared.cookieHeader }),
           let configured = try? await bootstrap(cookie: cookie) {
            web = configured
        } else {
            web = WebSession(apiKey: fallbackAPIKey, clientVersion: fallbackClientVersion,
                             visitorData: nil, authUser: "0", pageID: nil)
        }
        var components = URLComponents(string: "\(origin)/youtubei/v1/search")!
        components.queryItems = [.init(name: "key", value: web.apiKey), .init(name: "prettyPrint", value: "false")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue("67", forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue(web.clientVersion, forHTTPHeaderField: "X-Youtube-Client-Version")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        var client: [String: Any] = ["clientName": "WEB_REMIX", "clientVersion": web.clientVersion, "hl": "en", "gl": "GB"]
        if let visitor = web.visitorData { client["visitorData"] = visitor }
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "context": ["client": client], "query": query,
            // YouTube Music's Songs filter; avoids videos, playlists and profiles.
            "params": "EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D"
        ])
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var results: [YouTubeCandidate] = []
        collectMusicResults(json, into: &results)
        var seen = Set<String>()
        return Array(results.filter { seen.insert($0.id).inserted }.prefix(limit))
    }

    static func stream(videoID: String) async throws -> ResolvedSource {
        guard let cookie = await MainActor.run(body: { GoogleYouTubeAuth.shared.cookieHeader }),
              let sapisid = cookieValue("SAPISID", in: cookie) ?? cookieValue("__Secure-3PAPISID", in: cookie) else {
            throw ResolveError.unavailable("sign in to Google for Advanced YouTube")
        }
        guard cookieValue("LOGIN_INFO", in: cookie) != nil else {
            throw ResolveError.unavailable("the saved Google session has expired; sign in again")
        }
        let web = try await bootstrap(cookie: cookie)
        let timestamp = Int(Date().timeIntervalSince1970)
        var authorizations = [authorization(scheme: "SAPISIDHASH", value: sapisid, timestamp: timestamp)]
        if let value = cookieValue("__Secure-1PAPISID", in: cookie) {
            authorizations.append(authorization(scheme: "SAPISID1PHASH", value: value, timestamp: timestamp))
        }
        if let value = cookieValue("__Secure-3PAPISID", in: cookie) {
            authorizations.append(authorization(scheme: "SAPISID3PHASH", value: value, timestamp: timestamp))
        }
        var components = URLComponents(string: "\(origin)/youtubei/v1/player")!
        components.queryItems = [.init(name: "key", value: web.apiKey), .init(name: "prettyPrint", value: "false")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(authorizations.joined(separator: " "), forHTTPHeaderField: "Authorization")
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue(origin, forHTTPHeaderField: "X-Origin")
        request.setValue(origin + "/", forHTTPHeaderField: "Referer")
        request.setValue(web.authUser, forHTTPHeaderField: "X-Goog-AuthUser")
        request.setValue("true", forHTTPHeaderField: "X-Youtube-Bootstrap-Logged-In")
        request.setValue("67", forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue(web.clientVersion, forHTTPHeaderField: "X-Youtube-Client-Version")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let visitor = web.visitorData { request.setValue(visitor, forHTTPHeaderField: "X-Goog-Visitor-Id") }
        if let pageID = web.pageID { request.setValue(pageID, forHTTPHeaderField: "X-Goog-PageId") }
        var client: [String: Any] = [
            "clientName": "WEB_REMIX", "clientVersion": web.clientVersion,
            "platform": "DESKTOP", "hl": "en", "gl": "GB",
            "originalUrl": origin + "/", "userAgent": userAgent
        ]
        if let visitor = web.visitorData { client["visitorData"] = visitor }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "context": ["client": client, "user": ["lockedSafetyMode": false], "request": ["useSsl": true]],
            "videoId": videoID,
            "contentCheckOk": true,
            "racyCheckOk": true
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 200, let decoded = try? JSONDecoder().decode(AdvancedPlayerResponse.self, from: data),
           decoded.playabilityStatus?.status == "OK", let source = resolved(decoded, videoID: videoID, client: "web-remix") {
            return source
        }
        do { return try await visionOSStream(videoID: videoID, web: web) }
        catch {
            let webReason: String
            if status != 200 { webReason = "WEB_REMIX HTTP \(status): \(errorMessage(data))" }
            else if let decoded = try? JSONDecoder().decode(AdvancedPlayerResponse.self, from: data) {
                webReason = decoded.playabilityStatus?.reason ?? "WEB_REMIX returned no playable audio"
            } else { webReason = "WEB_REMIX returned an unreadable player response" }
            let fallbackReason = (error as? ResolveError)?.text ?? error.localizedDescription
            throw ResolveError.unplayable("\(webReason); direct fallback: \(fallbackReason)")
        }
    }

    // Metrolist/InnerTubeX's visitor-backed, direct-audio iOS-compatible fallback.
    private static func visionOSStream(videoID: String, web: WebSession) async throws -> ResolvedSource {
        var components = URLComponents(string: "\(origin)/youtubei/v1/player")!
        components.queryItems = [.init(name: "key", value: fallbackAPIKey), .init(name: "prettyPrint", value: "false")]
        let visionAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_6) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"
        var client: [String: Any] = [
            "clientName": "VISIONOS", "clientVersion": "0.1", "osName": "VISION_OS", "osVersion": "1.3",
            "deviceMake": "Apple", "deviceModel": "RealityDevice14,1", "platform": "MOBILE", "hl": "en", "gl": "GB"
        ]
        // Never combine the signed-in WEB_REMIX visitor with an unsigned native
        // profile. InnerTube treats that mixed identity as suspicious and replies
        // "Sign in to confirm you're not a bot". Obtain a clean Music visitor for
        // the direct client, as InnerTubeX does for visitor-backed legacy playback.
        if let visitor = await anonymousVisitorData(web: web) ?? web.visitorData { client["visitorData"] = visitor }
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("101", forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue("0.1", forHTTPHeaderField: "X-Youtube-Client-Version")
        request.setValue(visionAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "context": ["client": client], "videoId": videoID, "contentCheckOk": true, "racyCheckOk": true
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw ResolveError.unavailable("VISIONOS HTTP \(status): \(errorMessage(data))") }
        let decoded = try JSONDecoder().decode(AdvancedPlayerResponse.self, from: data)
        guard decoded.playabilityStatus?.status == "OK" else {
            throw ResolveError.unplayable(decoded.playabilityStatus?.reason ?? "video unavailable")
        }
        guard let source = resolved(decoded, videoID: videoID, client: "visionos-0.1") else {
            throw ResolveError.unplayable("no compatible direct audio stream")
        }
        return source
    }

    private static func anonymousVisitorData(web: WebSession) async -> String? {
        var components = URLComponents(string: "\(origin)/youtubei/v1/search")!
        components.queryItems = [.init(name: "key", value: fallbackAPIKey), .init(name: "prettyPrint", value: "false")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue("67", forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue(fallbackClientVersion, forHTTPHeaderField: "X-Youtube-Client-Version")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "context": ["client": ["clientName": "WEB_REMIX", "clientVersion": fallbackClientVersion, "hl": "en", "gl": "GB"]],
            "query": "music", "params": "EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D"
        ])
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let context = json["responseContext"] as? [String: Any] else { return nil }
        return context["visitorData"] as? String
    }

    private static func resolved(_ decoded: AdvancedPlayerResponse, videoID: String, client: String) -> ResolvedSource? {
        let formats = (decoded.streamingData?.adaptiveFormats ?? []) + (decoded.streamingData?.formats ?? [])
        let audio = formats.filter { $0.mimeType.lowercased().hasPrefix("audio/") && $0.url != nil }
        let preferred = audio.filter { $0.mimeType.lowercased().contains("mp4") }.max { ($0.averageBitrate ?? $0.bitrate ?? 0) < ($1.averageBitrate ?? $1.bitrate ?? 0) }
            ?? audio.max { ($0.averageBitrate ?? $0.bitrate ?? 0) < ($1.averageBitrate ?? $1.bitrate ?? 0) }
        guard let format = preferred, let rawURL = format.url, let url = URL(string: rawURL) else { return nil }
        let mime = format.mimeType.lowercased()
        let container = mime.contains("mp4") ? "m4a" : (mime.contains("webm") ? "webm" : "aac")
        let codec = mime.components(separatedBy: "codecs=\"").dropFirst().first?.components(separatedBy: "\"").first ?? "unknown"
        let lifetime = Double(decoded.streamingData?.expiresInSeconds ?? "") ?? 3600
        return ResolvedSource(url: url, container: container, codec: codec, bitrate: format.averageBitrate ?? format.bitrate,
                              expires: Date().addingTimeInterval(lifetime), origin: "advanced-youtube:\(client):\(videoID)")
    }

    private static func bootstrap(cookie: String) async throws -> WebSession {
        let signedInHTML = try await bootstrapHTML(cookie: cookie)
        // A valid Google session can be redirected through an account/consent page
        // which contains no ytcfg. The InnerTube key and client version are public
        // web-client configuration, so obtain those from a clean Music page when
        // necessary while retaining the signed-in page's account metadata.
        var configurationHTML = signedInHTML
        if playerConfiguration(in: configurationHTML) == nil {
            configurationHTML = try await bootstrapHTML(cookie: nil)
        }
        let configuration = playerConfiguration(in: configurationHTML)
            ?? (apiKey: fallbackAPIKey, clientVersion: fallbackClientVersion)
        return WebSession(
            apiKey: configuration.apiKey,
            clientVersion: configuration.clientVersion,
            visitorData: value(named: "VISITOR_DATA", in: signedInHTML) ?? value(named: "VISITOR_DATA", in: configurationHTML),
            authUser: numericValue(named: "SESSION_INDEX", in: signedInHTML) ?? "0",
            pageID: value(named: "DELEGATED_SESSION_ID", in: signedInHTML)
        )
    }

    private static func bootstrapHTML(cookie: String?) async throws -> String {
        var request = URLRequest(url: URL(string: origin + "/")!)
        request.timeoutInterval = 30
        if let cookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-GB,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let html = String(data: data, encoding: .utf8) else {
            throw ResolveError.unavailable("couldn't open YouTube Music (HTTP \(status))")
        }
        return html
    }

    private static func playerConfiguration(in html: String) -> (apiKey: String, clientVersion: String)? {
        guard let apiKey = value(named: "INNERTUBE_API_KEY", in: html),
              let version = value(named: "INNERTUBE_CLIENT_VERSION", in: html)
                ?? value(named: "INNERTUBE_CONTEXT_CLIENT_VERSION", in: html)
                ?? value(named: "clientVersion", in: html) else { return nil }
        return (apiKey, version)
    }

    private static func value(named name: String, in html: String) -> String? {
        capture("\\\"\(NSRegularExpression.escapedPattern(for: name))\\\"\\s*:\\s*\\\"([^\\\"]+)\\\"", in: html)
            ?? capture("\\\\\\\"\(NSRegularExpression.escapedPattern(for: name))\\\\\\\"\\s*:\\s*\\\\\\\"([^\\\\]+?)\\\\\\\"", in: html)
    }

    private static func numericValue(named name: String, in html: String) -> String? {
        capture("\\\"\(NSRegularExpression.escapedPattern(for: name))\\\"\\s*:\\s*\\\"?(\\d+)\\\"?", in: html)
    }

    private static func collectMusicResults(_ value: Any, into results: inout [YouTubeCandidate]) {
        if let dictionary = value as? [String: Any] {
            if let renderer = dictionary["musicResponsiveListItemRenderer"] as? [String: Any],
               let item = renderer["playlistItemData"] as? [String: Any],
               let id = item["videoId"] as? String, id.count == 11,
               let columns = renderer["flexColumns"] as? [[String: Any]] {
                let runs = columns.compactMap { column -> [[String: Any]]? in
                    let flex = column["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any]
                    let text = flex?["text"] as? [String: Any]
                    return text?["runs"] as? [[String: Any]]
                }
                let title = runs.first?.compactMap { $0["text"] as? String }.joined() ?? ""
                let metadata = runs.dropFirst().first ?? []
                let artist = metadata.first?["text"] as? String ?? ""
                let duration = metadata.compactMap { $0["text"] as? String }.compactMap(musicDuration).last
                if !title.isEmpty { results.append(YouTubeCandidate(id: id, title: title, channel: artist, duration: duration)) }
            }
            for child in dictionary.values { collectMusicResults(child, into: &results) }
        } else if let array = value as? [Any] {
            for child in array { collectMusicResults(child, into: &results) }
        }
    }

    private static func musicDuration(_ text: String) -> Double? {
        let pieces = text.split(separator: ":").compactMap { Int($0) }
        guard (2...3).contains(pieces.count), pieces.count == text.split(separator: ":").count else { return nil }
        return Double(pieces.reduce(0) { $0 * 60 + $1 })
    }

    private static func authorization(scheme: String, value: String, timestamp: Int) -> String {
        let input = "\(timestamp) \(value) \(origin)"
        let digest = Insecure.SHA1.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(scheme) \(timestamp)_\(digest)"
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func errorMessage(_ data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            return String(message.prefix(180))
        }
        let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "no response body"
        return String(raw.prefix(180))
    }

    private static func cookieValue(_ name: String, in header: String) -> String? {
        header.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.first { $0.hasPrefix(name + "=") }
            .map { String($0.dropFirst(name.count + 1)) }
    }
}

struct AdvancedYouTubeResolver: AudioResolver {
    let id = "advanced-youtube"
    let name = "advanced youtube"
    var available: Bool { Keychain.get("youtube.google.cookies") != nil }

    func resolve(_ track: Track, mapping: Mapping?) async throws -> ResolvedSource {
        var attempted = Set<String>()
        var choices: [YouTubeCandidate] = []
        if let mapped = mapping?.videoid {
            choices.append(YouTubeCandidate(id: mapped, title: mapping?.videotitle ?? track.title,
                                            channel: mapping?.channel ?? track.artist, duration: mapping?.videoduration))
        } else if track.id.hasPrefix(Track.ytprefix) {
            choices.append(YouTubeCandidate(id: String(track.id.dropFirst(Track.ytprefix.count)), title: track.title,
                                            channel: track.artist, duration: track.duration))
        }
        let queries = YouTubeSearch.queries(for: track)
        var musicPool: [YouTubeCandidate] = []
        for query in queries {
            musicPool += await AdvancedYouTubeClient.search(query, limit: 20)
        }
        let musicMatches = YouTubeMatcher.rank(musicPool, for: track).ok.prefix(8).map(\.0)
        choices += musicMatches
        // Metrolist treats Music search as primary but does not assume every YouTube
        // Music catalogue ID has a usable player representation. Keep ordinary
        // YouTube candidates as the final compatibility tier for missing/unplayable
        // songs; they still resolve through Advanced YouTube's effects pipeline.
        let youtubePool = await YouTubeSearch.candidates(for: track, limit: 24)
        choices += YouTubeMatcher.rank(youtubePool, for: track).ok.prefix(8).map(\.0)
        var lastError = "no YouTube Music song matched"
        for candidate in choices where attempted.insert(candidate.id).inserted {
            do {
                var source = try await AdvancedYouTubeClient.stream(videoID: candidate.id)
                if mapping?.videoid != candidate.id {
                    source.match = Mapping(videoid: candidate.id, source: id, verified: true, auto: true,
                                           videotitle: candidate.title, channel: candidate.channel,
                                           videoduration: candidate.duration, trackduration: track.duration, matchedat: Date())
                }
                return source
            } catch {
                lastError = (error as? ResolveError)?.text ?? error.localizedDescription
            }
        }
        throw ResolveError.unplayable(lastError)
    }
}
