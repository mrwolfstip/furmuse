import Foundation

// Official Spicy Lyrics API adapter. The user's key is read from Keychain for each request so a
// replaced/removed key takes effect immediately and an invalid key can safely unpause the provider.
final class SpicyLyrics: LyricsProvider, @unchecked Sendable {
    static let shared = SpicyLyrics()
    static let keychainKey = "spicylyrics.apiKey"
    let id = "spicy"
    let name = "spicy lyrics"
    private let lock = NSLock()
    private var pausedUntil = Date.distantPast
    private var rejectedKey = ""

    var haskey: Bool { !(Keychain.get(Self.keychainKey) ?? "").isEmpty }
    func savekey(_ value: String) { Keychain.set(value.trimmingCharacters(in: .whitespacesAndNewlines), Self.keychainKey); reset() }
    func removekey() { Keychain.remove(Self.keychainKey); reset() }
    private func reset() { lock.lock(); pausedUntil = .distantPast; rejectedKey = ""; lock.unlock() }
    private func isblocked(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; return key == rejectedKey || Date() < pausedUntil }
    private func reject(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; let first = rejectedKey != key; rejectedKey = key; return first }
    private func pause(_ seconds: Int) { lock.lock(); pausedUntil = Date().addingTimeInterval(Double(seconds)); lock.unlock() }

    func testkey() async -> String {
        guard let key = Keychain.get(Self.keychainKey), !key.isEmpty else { return "add a key first" }
        // A syntactically valid Spotify id is intentionally allowed to miss: 404 still proves the key passed auth.
        let result = await request(id: "0000000000000000000000", key: key)
        switch result.code {
        case 200, 404: return "key works"
        case 401, 403: return "that key wasn't accepted"
        case 429: return "key works, but its rate limit is paused"
        default: return "couldn't reach spicy lyrics"
        }
    }

    func fetch(_ track: Track, settings: Settings) async -> LyricsDoc? {
        guard track.isspotify, track.id.count == 22, let key = Keychain.get(Self.keychainKey), !key.isEmpty else { return nil }
        guard !isblocked(key) else { return nil }
        let result = await request(id: track.id, key: key)
        if result.code == 401 || result.code == 403 {
            let first = reject(key)
            Log.e(.lyrics, "spicy lyrics rejected the saved key (http \(result.code))")
            if first { await MainActor.run { ToastCenter.shared.show("spicy lyrics needs a different key") } }
            return nil
        }
        if result.code == 429 {
            let wait = max(1, result.retryAfter ?? 60)
            pause(wait)
            Log.w(.lyrics, "spicy lyrics rate limited, paused for \(wait) seconds")
            return nil
        }
        guard result.code == 200, let data = result.data, let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let body = root["Body"] as? [String: Any], let source = body["source"] as? String else {
            if result.code != 404 { Log.w(.lyrics, "spicy lyrics request failed (http \(result.code))") }
            return nil
        }
        let accepted = source == "spicy_lyrics" ? settings.spicycommunity : (source == "apple_music" ? settings.spicyapple : (source == "spotify" ? settings.spicyspotify : false))
        guard accepted else { Log.i(.lyrics, "spicy lyrics result from disabled source \(source), falling through"); return nil }
        return Self.parse(body, source: source)
    }

    private func request(id: String, key: String) async -> (code: Int, data: Data?, retryAfter: Int?) {
        var request = URLRequest(url: URL(string: "https://api.spicylyrics.org/v1/lyrics/\(id)")!)
        request.timeoutInterval = 10
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            if let left = http?.value(forHTTPHeaderField: "RateLimit-Remaining") { Log.i(.lyrics, "spicy lyrics rate limit remaining: \(left)") }
            return (http?.statusCode ?? 0, data, Int(http?.value(forHTTPHeaderField: "Retry-After") ?? ""))
        } catch {
            Log.w(.lyrics, "spicy lyrics network failure: \(error.localizedDescription)")
            return (0, nil, nil)
        }
    }

    private static func parse(_ body: [String: Any], source: String) -> LyricsDoc? {
        let type = body["Type"] as? String ?? ""
        var lines: [LyricLine] = []
        if type == "Syllable", let content = body["Content"] as? [[String: Any]] {
            for item in content {
                guard let lead = item["Lead"] as? [String: Any], let syllables = lead["Syllables"] as? [[String: Any]] else { continue }
                var words: [LyricWord] = [], word = "", roman = "", start: Double?, end = 0.0
                for syllable in syllables {
                    let text = syllable["Text"] as? String ?? ""
                    if start == nil { start = syllable["StartTime"] as? Double }
                    end = syllable["EndTime"] as? Double ?? end
                    word += text; roman += syllable["TransliteratedText"] as? String ?? text
                    if (syllable["IsPartOfWord"] as? Bool) != true {
                        if let start, !word.isEmpty { words.append(LyricWord(time: start, end: max(end, start), text: word + " ", roman: roman + " ")) }
                        word = ""; roman = ""; start = nil
                    }
                }
                let text = words.map(\.text).joined().trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                let begin = lead["StartTime"] as? Double ?? words.first?.time ?? 0
                let finish = lead["EndTime"] as? Double ?? words.last?.end ?? begin
                let backgrounds = (item["Background"] as? [[String: Any]])?.compactMap { group -> String? in
                    let value = (group["Syllables"] as? [[String: Any]])?.compactMap { $0["Text"] as? String }.joined(separator: " ")
                    return value?.isEmpty == false ? value : nil
                }.joined(separator: " · ")
                lines.append(LyricLine(time: begin, end: finish, text: text, words: words, roman: lead["TransliteratedText"] as? String,
                                       background: backgrounds, opposite: item["OppositeAligned"] as? Bool ?? false,
                                       translation: lead["TranslatedText"] as? String))
            }
        } else if type == "Line", let content = body["Content"] as? [[String: Any]] {
            lines = content.compactMap { item in
                guard let text = item["Text"] as? String, !text.isEmpty else { return nil }
                let start = item["StartTime"] as? Double ?? 0, end = item["EndTime"] as? Double ?? start
                return LyricLine(time: start, end: end, text: text, words: [], roman: item["TransliteratedText"] as? String,
                                 opposite: item["OppositeAligned"] as? Bool ?? false, translation: item["TranslatedText"] as? String)
            }
        } else if type == "Static", let content = body["Lines"] as? [[String: Any]] {
            lines = content.compactMap { item in
                guard let text = item["Text"] as? String, !text.isEmpty else { return nil }
                return LyricLine(time: -1, end: -1, text: text, words: [], roman: item["TransliteratedText"] as? String,
                                 translation: item["TranslatedText"] as? String)
            }
        }
        guard !lines.isEmpty else { return nil }
        let attribution = body["UploadAttribution"] as? [String: Any]
        func credit(_ key: String) -> LyricsCredit? {
            guard source == "spicy_lyrics", let value = attribution?[key] as? [String: Any],
                  let name = value["username"] as? String, let url = value["url"] as? String else { return nil }
            return LyricsCredit(name: name, url: url)
        }
        let label = source == "spicy_lyrics" ? "spicy lyrics" : source.replacingOccurrences(of: "_", with: " ")
        return LyricsDoc(lines: lines, synced: type != "Static", source: label, uploader: credit("Uploader"), maker: credit("Maker"))
    }
}
