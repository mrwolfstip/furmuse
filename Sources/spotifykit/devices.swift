import Foundation

final class DeviceManager: ObservableObject {
    @Published private(set) var devices: [SpDevice] = []
    @Published private(set) var loading = false
    @Published private(set) var selectedid: String?
    private let api: SpotifyAPI
    private let library: LibraryStore
    private let onselect: (String?) -> Void
    private let key = "wolfified.device.selected"

    init(api: SpotifyAPI, library: LibraryStore, onselect: @escaping (String?) -> Void) {
        self.api = api
        self.library = library
        self.onselect = onselect
        selectedid = UserDefaults.standard.string(forKey: key)
        onselect(selectedid)
    }

    var selected: SpDevice? { devices.first { $0.id == selectedid } }
    var selectedmissing: Bool { selectedid != nil && selected == nil }

    func display(_ d: SpDevice) -> String { d.id.flatMap { library.data.aliases[$0] } ?? d.name }
    var selectedname: String {
        guard let id = selectedid else { return "none" }
        if let d = selected { return display(d) }
        return library.data.aliases[id] ?? "unavailable"
    }

    func select(_ id: String?) {
        selectedid = id
        UserDefaults.standard.set(id, forKey: key)
        onselect(id)
    }

    // the web playback sdk generates a new device id every time it connects. this keeps "the device furmuse controls"
    // pointed at furmuse's own device: if the selection was none, or was the previous id of this same device, it follows
    // the new id. a different device the user chose on purpose is left alone.
    private let lastownkey = "wolfified.webplayback.lastdeviceid"
    private(set) var owndeviceid: String?
    func adoptown(_ id: String) {
        let previous = owndeviceid ?? UserDefaults.standard.string(forKey: lastownkey)
        owndeviceid = id
        UserDefaults.standard.set(id, forKey: lastownkey)
        if selectedid == nil || selectedid == previous { select(id) }
    }
    func isown(_ id: String?) -> Bool { id != nil && id == owndeviceid }

    func setalias(_ id: String, _ alias: String) {
        let t = alias.trimmingCharacters(in: .whitespaces)
        library.mutate { $0.aliases[id] = t.isEmpty ? nil : t }
        objectWillChange.send()
    }

    @MainActor
    func refresh() async {
        guard api.auth.connected else { devices = []; return }
        loading = true
        defer { loading = false }
        do { devices = try await api.devices() } catch { SpotifyAPI.report(error) }
    }

    private func send(_ work: () async throws -> Void) async -> Bool {
        do { try await work(); return true } catch {
            SpotifyAPI.report(error)
            // a selected device that vanished is rediscovered from spotify, never assumed
            if case .nodevice? = error as? SpotifyError { await refresh() }
            return false
        }
    }

    private var query: [String: String] { selectedid.map { ["device_id": $0] } ?? [:] }

    func playsingle(_ t: Track, positionms: Int = 0) async {
        guard selectedid != nil else { ToastCenter.shared.show("pick a connect device first", route: .devices); return }
        _ = await send { _ = try await api.request("PUT", "/me/player/play", query: query, body: ["uris": [t.uri], "position_ms": max(0, positionms)]) }
    }
    func pause() async { _ = await send { _ = try await api.request("PUT", "/me/player/pause", query: query) } }
    func resume() async { _ = await send { _ = try await api.request("PUT", "/me/player/play", query: query) } }
    func next() async { _ = await send { _ = try await api.request("POST", "/me/player/next", query: query) } }
    func previous() async { _ = await send { _ = try await api.request("POST", "/me/player/previous", query: query) } }
    func seek(ms: Int) async {
        var q = query; q["position_ms"] = String(max(0, ms))
        _ = await send { _ = try await api.request("PUT", "/me/player/seek", query: q) }
    }
    func volume(_ pct: Int) async {
        var q = query; q["volume_percent"] = String(min(100, max(0, pct)))
        _ = await send { _ = try await api.request("PUT", "/me/player/volume", query: q) }
    }
    func queue(_ t: Track) async {
        var q = query; q["uri"] = t.uri
        _ = await send { _ = try await api.request("POST", "/me/player/queue", query: q) }
    }
    func transfer(play: Bool) async {
        guard let id = selectedid else { return }
        _ = await send { _ = try await api.request("PUT", "/me/player", body: ["device_ids": [id], "play": play]) }
    }
    func remotestate() async -> SpPlayerState? {
        do { return try await api.state() } catch { SpotifyAPI.report(error); return nil }
    }
}
