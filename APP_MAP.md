# furmuse: complete app map

This document explains the current iOS app from first launch through everyday use, then maps the code and data behind each feature. It describes the source tree as it exists now.

## 1. What furmuse is

Furmuse is a SwiftUI music player for iPhone. A song has one stable identity and can be played from Spotify, YouTube, an attached local file, or a downloaded copy. Display edits, artwork, lyrics, and playback-source choices are stored as local overlays, so changing how a song looks does not change its canonical Spotify metadata or Last.fm scrobbles.

The app has three main tabs:

1. **home** — full-screen now playing, controls, lyrics, queue, search, source selection, and downloads.
2. **library** — playlists, artists, albums, songs, imports, metadata, and artwork editing.
3. **settings** — accounts, playback, effects, lyrics, source rules, downloads, animated covers, appearance, backups, and diagnostics.

## 2. Launch and dependency graph

`FurmuseApp` creates the shared `Services` object and injects its observable services into `RootView`.

```text
FurmuseApp
└── Services.shared
    ├── Settings
    ├── SetupStore
    ├── LibraryStore
    ├── SpotifyAuth + SpotifyAPI + DeviceManager
    ├── ResolverManager
    ├── PlaybackEngine
    ├── DownloadManager
    ├── LyricsStore
    ├── NowPlayingCenter
    └── LastfmClient + Scrobbler
```

At launch:

- UIKit navigation, list, and tab-bar backgrounds are made transparent.
- Saved settings, setup state, library data, credentials, and caches are loaded.
- Spotify and Last.fm sessions are validated.
- The selected Spotify playback backend is supervised.
- Lock-screen remote commands are registered.
- A black splash screen displays `furmuse`, a forming waveform, and the loading caption for about 2.1 seconds.
- `RootView` opens setup if setup has never been completed; otherwise it opens the three-tab app.

The root also owns the global toast and loading overlays. Playback loading appears as a small material capsule near the bottom rather than replacing the whole screen.

## 3. First-time setup

Setup is a saved, branch-aware, fully centered flow. It opens with a dedicated welcome message before asking any questions. Every later page has back/skip controls, the top progress bar reflects the current branch, pages move horizontally with a spring, and Reduce Motion substitutes a short fade. Quitting resumes at the saved page.

1. Choose Spotify or YouTube. This sets the main service and global playback source.
2. Choosing Spotify presents the Premium question as an alert rather than another setup page. Answering no selects YouTube; Premium users are guided through creating a client ID, copying `wolfified://callback`, authenticating with `ASWebAuthenticationSession`, and choosing standard or `with effects` playback. The latter includes the separate librespot readiness/sign-in step.
3. YouTube instead shows the Last.fm metadata accuracy warning.
4. Both branches optionally configure Last.fm keys and browser authentication.
5. Finish opens the main tabs. Spicy Lyrics is configured later under settings → lyrics, not during initial setup.

All setup choices can be changed later in settings. Resetting the whole app returns the user to this flow.

## 4. Song identity and metadata model

`Track` is the canonical song record.

- Normal IDs are Spotify track IDs.
- IDs beginning with `yt_` are YouTube-only songs.
- IDs beginning with `local_` are files imported directly from the device.
- The canonical title, artist, album, duration, credits, and service identifiers remain available even when the user edits the visible metadata.

Furmuse keeps separate layers around a track:

| Layer | Purpose |
|---|---|
| `Track` | Canonical service/file metadata and stable identity. |
| `LibraryEntry` | Added date, import origin, last-played date, and play count. |
| `Override` | Local title, artist, album, still artwork, and custom animated artwork. |
| `Mapping` | The selected or automatically matched YouTube video. |
| `SourceChoice` | Preferred source and attached local audio file. |
| `DownloadItem` | Downloaded audio path, format, size, and trimmed ending. |

`LibraryStore.shown(_:)` applies display overrides and album-level art without modifying the original track.

## 5. Home and now playing

The player fills the available area above the tab bar.

### Artwork

- The artwork spans the full player width and fills the available upper area.
- Its lower edge fades into the player background.
- A blurred, low-opacity copy and an average cover colour tint the background.
- The accent colour is derived from the displayed still image or the first frame of animated art, then contrast-corrected for readability.
- Reduced Motion disables animated artwork playback.

Artwork selection is described in [Animated artwork](#13-animated-artwork).

### Main controls

The player provides:

- title and artist links, which open album and artist pages;
- liked button;
- progress slider and elapsed/total time;
- previous, play/pause, and next;
- system volume slider using `MPVolumeView`;
- repeat off, repeat all, and repeat one;
- lyrics;
- add to playlist;
- queue;
- search.

The `…` menu provides:

- switch between still and animated artwork when animation exists;
- choose Canvas-first, Apple-first, or the app default for this song;
- playback speed;
- reverb on/off and preset selection;
- audio source selection;
- song details and artwork editing;
- download or remove download;
- open the original Spotify or YouTube page.

If the user taps play/pause five times within eight seconds while using Spotify Web Playback, the app offers to test the librespot-based `with effects` backend.

### Empty state

When nothing is playing, home shows a search shortcut. Selecting a search result creates a queue and starts playback.

## 6. Search and browsing

Search is reached from home. When Spotify is connected, it searches Spotify tracks. Results can be played, queued, added to the library, added to a playlist, or opened through their artist/album links.

Playing or importing a song records it in the library. Search results may exist temporarily in the metadata cache before they become library members.

Artist pages show:

- the chosen or discovered artist image;
- play and shuffle controls;
- songs already in the local library;
- additional Spotify results for that artist when available.

Album pages group songs by normalized album name and album artist. Album art can be changed for the whole group.

## 7. Library

The library has four searchable sections:

### Playlists

- Create local playlists.
- Import Spotify playlists.
- Import and review YouTube playlists.
- Rename playlists and choose playlist covers.
- Reorder, add, or remove tracks locally.
- Imported Spotify/YouTube IDs are retained as origin metadata; local edits do not rewrite the remote playlist.
- Liking a song creates or updates a local playlist named `Liked Songs`.

### Artists

Songs are grouped by their primary credited artist. Artist pages can use a custom photo, a photo found through Spotify, or a track cover as fallback.

### Albums

Songs are grouped by album name plus album artist. A chosen still or animated album cover applies to every song in that album unless a song has its own explicit override.

### Songs

This is every track currently in the Furmuse library, ordered by last played or added date. Imported playlist tracks appear here after import or after `update library` synchronizes older playlist entries.

Searching the exact hidden phrase `goontomrwolf` unlocks the legacy app-icon option under settings → appearance.

## 8. Adding and importing music

The library import menu offers four paths.

### Add your own song

One or more device audio files can be selected. Furmuse reads embedded title, artist, album, duration, and artwork where available. The user can adjust common metadata, select a cover, and optionally paste plain or timestamped lyrics. Security-scoped files are copied and decode-checked off the main thread into Application Support, with per-file state and partial-success reporting, so large files do not freeze the UI and playback does not depend on the original picker URL. Attaching/replacing one song's file uses the same path.

Local-file tracks use a `local_` ID and always have their imported file available as a source.

### Spotify playlist

The user chooses from their Spotify playlists. Pages of tracks are fetched through the Spotify Web API, converted into canonical `Track` values, placed in a local playlist, and added to the Furmuse library. This is metadata import, not a live mirrored playlist.

### YouTube playlist

The importer:

1. reads the public playlist;
2. parses each video;
3. attempts to match it to a Spotify track when Spotify is connected;
4. scores and verifies the YouTube video as the audio source;
5. shows every result for review;
6. lets the user include/exclude tracks and edit either the Spotify match or YouTube source;
7. imports only after confirmation.

If Spotify is unavailable or no match is found, the item becomes a YouTube-only `yt_` track.

Continuation pages are cancellation-aware. If YouTube stops answering after one or more pages, those playable results remain reviewable with a clear partial-results warning; private/unavailable playlists fail with an actionable reason rather than hanging.

### YouTube link or search

The user can paste a video URL/ID or search YouTube. They may keep it as a YouTube-only track or ask Furmuse to match a Spotify identity. The selected video is stored as a confirmed source so future playback does not guess again.

## 9. Audio-source selection

Source precedence is intentionally separate from song identity.

For each track, playback generally follows this order:

1. an available attached local file;
2. a preferred downloaded copy when enabled;
3. the per-track preferred source, if set;
4. the global source preference;
5. appropriate fallback/error handling.

YouTube-only songs always use their own confirmed video. Local-only songs use their imported file.

For a normal Spotify-identity track, the user can select:

- **default** — follow the global source;
- **Spotify** — use the configured Spotify backend;
- **local file** — use an attached file;
- **YouTube** — use the stored or automatically resolved video.

Attaching a file copies it into the app. Removing the attachment leaves the track and its other source choices intact.

### YouTube matching

`ResolverManager` caches successful stream resolutions and coalesces duplicate requests. `YouTubeResolver` searches multiple candidates, ranks title/artist/duration similarity, attempts playable M4A/AAC streams, and saves successful mappings.

- User-confirmed mappings are reused until the video becomes unavailable.
- Manual mappings are honoured even if their duration looks suspicious, but the app warns the user.
- Automatic mappings are rechecked when track duration changes or verification is incomplete.
- A failing stored source triggers a fresh search.
- A custom resolver endpoint can be configured as an optional alternative or priority source.

For YouTube streams whose container reports a much longer duration than the real song, the player clamps the displayed and playable end to roughly the canonical track duration plus the allowed tail rather than exposing the full bad container duration.

## 10. Playback engine and queue

`PlaybackEngine` owns the current queue, index, source instance, position, duration, loading state, and playback state.

Every load, skip, source switch, and retry receives a generation token. Starting a newer request cancels its resolver flight, tears down the previous source first, and makes callbacks from stale AVPlayer, Web Playback, or librespot sources harmless.

It supports:

- play a list from any index;
- play now, play next, or append;
- queue reordering and removal;
- previous, next, seek, pause, and resume;
- repeat one and repeat all;
- switching global source or Spotify backend while preserving the current position where possible;
- playback events for Last.fm and UI updates.

Sources conform to one `PlaybackSource` protocol and report positions in track time. The implementations are:

- `LocalFileSource` for imported/downloaded files;
- `YouTubeSource`/`AVPlayerStreamSource` for resolved streams;
- `WebPlaybackSource` for Spotify Web Playback;
- `SpotifyPlaybackSource` backed by the native librespot bridge.

## 11. Spotify playback modes

### Standard

The standard backend embeds Spotify Web Playback in a hidden `WKWebView`, supervises its connection, and receives player state through script messages. It is the default and has the least setup, but Spotify controls capability and account eligibility. Some local audio effects cannot be applied because Spotify owns the audio rendering.

### With effects

The alternative backend uses the Rust `librespot` bridge and the app's shared audio graph. It needs its separate librespot authentication to be ready. Because audio flows through Furmuse, speed, pitch, equalizer, bass, and reverb can be applied.

The Spotify player settings page shows readiness and blockers for the selected backend and has a one-tap reconnect. Librespot is supervised with network/foreground/watchdog recovery and exponential backoff. Audio-interruption recovery also kicks the supervisor. When another Spotify client changes the song on either backend, Furmuse immediately adopts the event metadata so the player never waits on the network. An external selection also clears any pending natural end-of-track PCM boundary from the old item, preventing new audio from playing while the UI remains queued on the previous song. Furmuse then fetches complete metadata for the incoming Spotify ID, rejects stale metadata results, and enriches the same current item without replaying the old queue.

## 12. Sound, speed, and volume

The shared audio graph supports:

- speed from 0.5× to 2×;
- optional pitch lock;
- pitch shift in semitones;
- five-band equalizer;
- bass boost;
- reverb preset and wet/dry mix;
- app playback volume.

The player also exposes the actual device/system volume through `MPVolumeView`. Effects are guaranteed only for sources rendered through the shared graph; the settings UI explains backend limitations and may switch Spotify to `with effects` when an effect requires it.

## 13. Animated artwork

Furmuse supports three animated-art sources:

1. a custom video selected by the user;
2. Spotify Canvas fetched through the configured Canvas service;
3. Apple Music animated artwork fetched through the configured artwork service.

Precedence rules:

- A custom song video wins.
- An explicit custom still song cover suppresses automatic online animation for that song.
- Otherwise the per-song priority wins, falling back to the global priority.
- The preferred provider falls back to the other provider when no match exists.
- Async artwork results are keyed by track and effective priority, so a late cached provider cannot overwrite a newer per-song choice. An explicit fallback produces a toast.
- Album-level custom art applies below song-level overrides.
- `show animated cover` controls the in-app player.
- `animate lock screen covers` controls iOS 26 animated lock-screen artwork; when off, the still image is used.
- Reduced Motion keeps the in-app artwork still.

Canvas and Apple results are downloaded and cached locally with preview frames. The animated-covers settings page enables/disables providers, sets service URLs and priority, clears caches, and can prefetch artwork for the library.

## 14. Lyrics

When a song opens, `LyricsStore` resolves lyrics in this order:

1. user-saved TTML;
2. user-saved LRC;
3. local structured/cache result;
4. Spicy Lyrics for canonical Spotify IDs when the user supplied a key;
5. LRCLIB exact lookup;
6. LRCLIB search;
7. optional NetEase, QQ Music, and Kugou fallbacks.

Online sources conform to `LyricsProvider`. Settings → lyrics → lyrics sources exposes their saved order and an enable switch for each provider; user-saved lyrics remain outside that list and always win. The old `search more sites` value migrates to the NetEase/QQ/Kugou switches. Every provider falls through on failure.

Spicy Lyrics keys are stored only in Keychain and can be added, tested, replaced, or removed in settings. Community, Apple Music, and Spotify catalogue results can be accepted independently. The adapter handles syllable-, line-, and static-level responses, preserves source/uploader/maker attribution and source transliteration in its structured cache, observes retry delays, and falls through on misses, disabled result sources, timeouts, and server failures. A rejected key is toasted once and remains paused until the key changes.

The app prefers synced lyrics but retains an unsynced fallback. Network fetching can be disabled, and offline-only mode prevents it.

### Display modes

- **classic** — current line/word highlighting without the extra laser styling.
- **laser** — Apple Music-like left-to-right glyph illumination, glow, scale, blur, and dimming around the active line.

True word timing from TTML/LRC is used when available. If only line timing exists and estimated words are enabled, the line duration is divided into estimated word timings.

TTML keeps explicit overlapping line intervals for duets instead of clipping a singer when the next line begins. Timed `ttm:role="x-bg"` spans are stored as their own words and receive an independent highlight sweep, allowing lead and background/second vocals to glow simultaneously.

### Interaction

- Tapping a synced line seeks playback.
- The active line scrolls into view.
- Text size is configurable.
- Lyrics can be refreshed unless user lyrics currently override providers.
- The song menu allows per-song romanization and user-lyrics management.

### Romanization

Japanese, Chinese, and Korean lyrics can be annotated locally. The global mode can be overridden per song:

- off;
- replace the original;
- show romanization below;
- show it only for the current line.

### Creating lyrics

The lyric editor accepts existing LRC or TTML, or lets the user paste plain text and sync it:

- **line by line** records a timestamp for each line;
- **word by word** records progressively finer timing;
- the result is saved per track and takes priority over downloaded lyrics.

User lyrics can be removed to return to cached/online providers.

## 15. Lyric cards

From lyrics, the user can select up to five lines. The card composer produces a square PNG with:

- album cover, artist photo, or solid-colour background;
- adjustable blur and darkening;
- adjustable lyric size;
- original or romanized text;
- optional `furmuse` branding.

The preview updates while options change. The final PNG is written to a temporary file and passed to the iOS share sheet.

## 16. Downloads and offline behavior

Local/attached songs are reported as already local. YouTube songs download their stream; Spotify-identity songs resolve and download a matched YouTube source rather than Spotify audio. Transfers expose per-track progress, preserve URLSession resume data after interruption, obey Wi-Fi/offline policy, reject HTML/HLS and invalid/empty audio, record format/codec/size metadata, and may analyze long silent tails. Completion tells the user which source was used. Downloads can be removed individually.

Relevant settings:

- prefer downloaded audio;
- offline only;
- Wi-Fi only;
- clear downloaded songs.

Offline-only mode also prevents online lyric lookup. Cached artwork, lyrics, attached files, and completed downloads remain available locally.

## 17. Lock screen and Dynamic Island

`NowPlayingCenter` publishes title, artist, album, duration, elapsed time, playback rate, and artwork through `MPNowPlayingInfoCenter`.

The system remote controls support:

- play, pause, and toggle;
- next and previous;
- seek;
- like/unlike through the `Liked Songs` playlist.

On supported iOS 26 builds, lock-screen artwork can use the custom animation, Canvas, Apple animated cover, or an animation generated from still artwork. Turning off `animate lock screen covers` forces static artwork.

`wolfified` is registered as the app URL scheme, `RootView` handles foreground links, and `NSSupportsLiveActivities` is present. This repository currently contains no WidgetKit/ActivityKit extension target, widget state, or `widgetURL`; therefore there is no Dynamic Island widget bundle for `scripts/signipa.sh` to re-sign. A future widget target must bring its own extension profile, matching bundle ID, App Group entitlement, and links on every activity state.

If `show current lyric as artist` is enabled, the artist field is periodically replaced with the active lyric. Its romanization follows the effective per-song/global romanization mode.

System volume cannot be embedded into Apple's lock-screen media widget by third-party apps; the in-app player provides the device volume slider instead.

## 18. Last.fm

Last.fm keys and the session token are stored in the Keychain. The user independently chooses whether to scrobble Spotify, local-file, and YouTube playback.

Scrobbles use canonical metadata, not the user's display renames. Pending scrobbles are retained and retried. If the Last.fm account may already receive Spotify scrobbles, Furmuse requires confirmation before also scrobbling Spotify-source playback to reduce accidental double counting.

## 19. Settings map

### Accounts

- **Spotify** — client ID, account connection, token verification, and disconnect.
- **Last.fm** — API credentials, authentication, per-source scrobbling, and double-counting confirmation.

### Listening

- **Speed & volume** — rate, pitch lock, and app volume.
- **Sound effects** — equalizer, bass, pitch, and reverb.
- **Lyrics** — enablement, network providers, highlighting style, word timing, romanization, and size.
  Spicy Lyrics key management, testing, and accepted-result-source toggles live inside this screen and its sources page rather than at the settings root.

### Music

- **Where songs play from** — global source, source confirmation, resolver order, endpoint, offline/download preferences.
- **Spotify player** — standard Web Playback or librespot `with effects`, plus readiness status.
- **Downloads** — policy, storage use, individual downloaded items, and cleanup.

### Library

- **Library & backup** — JSON export/import, global artist/album renames, and library maintenance.
- **Animated covers** — providers, priority, endpoints, caches, and prefetching.

### App

- **Appearance** — system/light/dark/black theme, lock-screen animation, lock-screen lyrics, and the unlockable legacy icon. Fresh installs and settings resets default to dark; existing saved theme values are preserved.
- **More** — toasts, diagnostics/log sharing, stored keys, reset actions, and advanced options.

## 20. Persistence and privacy

### Keychain

Sensitive values are stored in iOS Keychain:

- Spotify client ID and refresh token;
- librespot refresh token;
- Last.fm API key, shared secret, and session key.
- Spicy Lyrics API key.

### UserDefaults

UserDefaults stores non-secret preferences and compact state:

- theme and playback/effect options;
- lyric and artwork preferences;
- setup progress;
- Spotify device selection;
- Last.fm username/status and pending scrobbles;
- cached silence-trim values.

### Application Support

The `wolfified` Application Support directory stores:

- `library.json`;
- copied local audio;
- downloads;
- custom and cached artwork;
- animated artwork and preview frames;
- user and cached lyrics;
- diagnostics logs.

The library backup is JSON metadata. Media files and credentials are separate and are not embedded in that JSON export.

### Reset

The full reset clears the library, downloaded/local media managed by the app, artwork and animation caches, lyrics, logs, app preferences, setup state, connections, and configured credentials, then returns to setup. Reset controls should be treated as destructive.

## 21. Diagnostics and failure handling

The app writes categorized lifecycle, Spotify, playback, resolver, lyrics, imports, downloads, and Last.fm events to a rotating local log. Settings → more → problem report shows the recent tail but exports both complete rotating files as one `.txt` report; keys and passwords are redacted. Library backup uses a proper JSON file exporter and logs encode/export failures.

Common errors are surfaced as dismissible material toasts. A toast may open the relevant settings or mapping screen. Spotify rate limiting uses a dedicated alert and retry window. Network providers generally use short timeouts and fall through to the next source instead of blocking the player indefinitely.

## 22. Build and release layout

- `Sources/app` — app entry point.
- `Sources/ui` — SwiftUI screens, sheets, pickers, player, library, setup, and settings.
- `Sources/furmusecore` — models, storage, playback, resolving, downloads, lyrics, artwork, and lock-screen integration.
- `Sources/spotifykit` — Spotify OAuth, API, devices, Keychain helper, and librespot authentication.
- `Sources/lastfmkit` — Last.fm authentication and scrobbling.
- `rust/wolfified-librespot-ffi` — Rust/C bridge used by the `with effects` Spotify backend.
- `Support/Info.plist` — iOS app metadata and URL handling.
- `config` — Xcode build configuration.
- `scripts/makeipa.sh` — builds an unsigned device IPA.
- `scripts/signipa.sh` — signs an IPA locally with a supplied certificate/profile.
- `scripts/make-install-manifest.sh` — creates an OTA manifest for an authorised signed build.
- `.github/workflows/release-v1.yml` — builds and publishes the unsigned release artifact.

## 23. End-to-end everyday flow

```text
launch
  → setup or main tabs
  → search/import/open a library song
  → song enters a queue
  → engine chooses local/download/per-song/global source
  → resolver verifies or retrieves audio when needed
  → selected PlaybackSource prepares and starts
  → library records the play
  → now-playing UI + lock screen update
  → lyrics load from user file/cache/providers
  → artwork loads from override/album/service fallback
  → optional Last.fm now-playing/scrobble event
  → user can like, queue, download, edit, share lyrics, or change source
```

That separation—identity, display, source, lyrics, artwork, and playback—is the central design of Furmuse. It allows one library entry to keep reliable metadata while still being customized and played from whichever source works best.

## 24. Complete screen and UI-copy reference

This section is the implementation-facing inventory of user-visible copy. Text in `<angle brackets>` is dynamic. A slash shows mutually exclusive states. System-generated error descriptions and media metadata are represented as dynamic values because their exact content comes from iOS or a remote service.

### Launch, global overlays, and tabs

| Area | Exact copy or template | Behavior |
|---|---|---|
| Splash | `furmuse` | App name above the animated waveform. |
| Splash | `loading your music one note at a time.` | Grey italic launch caption. |
| Loading capsule | `loading…` / `connecting…` | Shown while a track or Spotify backend prepares. |
| Spotify quota alert | `spotify needs a break` | Appears only for Web Playback rate limiting. |
| Spotify quota message | `spotify says too many requests were made. furmuse will try again in about <seconds> seconds.` | Explains the retry delay. |
| Spotify quota button | `ok` | Dismisses the alert. |
| Tabs | `home`, `library`, `settings` | The three permanent destinations. |
| Routed settings sheet | `done` | Closes a settings page opened from a toast. |

Toast text is shown for five seconds, deduplicated for eight seconds, and can optionally open the relevant repair screen when tapped.

### Setup

Shared header copy:

- `welcome to furmuse!`
- `we require some details to fully complete the furmuse experience.`
- `step <n> of 5`
- `skip setup for now`
- `back` on steps after the first.

Step copy and controls:

| Step | Copy | Meaning |
|---|---|---|
| Spotify | `spotify` | Section title. |
| Spotify | `spotify client id` | Credential section. |
| Spotify | `make a free app at developer.spotify.com/dashboard. tick "Web Playback SDK" and "Web API", add wolfified://callback as the redirect address, then paste its client id here.` | Setup instructions. |
| Spotify | `client id` → `saved` / `missing` | Does not reveal the actual ID. |
| Spotify | `paste client id` | Entry field. |
| Spotify | `save` / `checking…` | Saves first, then verifies without deleting a valid-looking ID during an outage. |
| Spotify | `continue` | Enabled once an entered client ID is stored. |
| Account | `your account` | Section title. |
| Account | `free accounts can connect for search and playlist importing. spotify playback itself may require premium.` | Capability note. |
| Account | `status` → `connected` / `not connected` | Current OAuth state. |
| Account | `connect spotify` / `waiting…` / `continue` | Starts OAuth or advances. |
| Last.fm | `last.fm (optional)` | Section title. |
| Last.fm | `tracks what you listen to.` | Purpose. |
| Last.fm | `set up last.fm` | Opens Last.fm settings. |
| Last.fm | `continue` / `skip for now` | Depends on sign-in state. |
| Music | `music` | Section title. |
| Music | `youtube works right away.` | Default-source note. |
| Music | `choose where songs play from` | Opens source settings. |
| Music | `continue` | Advances. |
| Finish | `all set` | Final section. |
| Finish | `you can change everything later in settings.` | Reassurance. |
| Finish | `start listening` | Completes setup. |

Client-ID validation can display:

- `that doesn't look right. copy the client id from your app in the spotify dashboard.`
- `saved. checking with spotify…`
- `saved, but spotify rejected it. check the client id and redirect address, then replace it.`
- `saved. now connect your spotify account.`
- `saved, but spotify couldn't be reached to check it.`
- `<credential error returned by the authentication layer>`.

### Home with nothing playing

- `nothing playing`
- `search for something, or pick it from your library`
- `search`

The search button opens the music search screen.

### Now playing

Dynamic text includes `<song title>`, `<artist>`, `<elapsed time>`, and `<duration>`. Title opens the album; artist opens the artist page.

Accessibility/control copy:

- liked button: `add to liked songs` / `remove from liked songs`;
- transport icons represent previous, play/pause, and next;
- bottom controls represent repeat, lyrics, add to playlist, queue, and search;
- repeat cycles through off, playlist, and one-song modes.

The `…` menu contains:

- `use still cover` / `use animated cover`;
- `animated cover priority`;
- `spotify canvas first`;
- `apple music cover first`;
- `use app default`;
- `playback speed (<rate>x)`;
- `reverb`;
- `turn reverb off` / `turn reverb on`;
- each available system reverb-room name;
- `audio source`;
- `edit song`;
- `download` / `remove download`;
- `open original`.

The speed sheet contains:

- title `playback speed`;
- live value `<rate>x`;
- endpoints `0.5x` and `2x`;
- `reset to 1.00x`;
- `done`.

Web Playback recovery alert:

- title: `hey! web playback sdk might be having issues.`
- message: `wanna test librespot / with effects?`
- buttons: `test with effects`, `keep standard`;
- confirmation toast: `switched to with effects. sign in under settings → spotify player if asked.`

### Search

| Copy | Behavior |
|---|---|
| `search` | Navigation title. |
| `search music` | Query field. |
| `searching…` | Active request. |
| `no results` | Empty response. |
| `showing youtube results because spotify search isn't available.` | Search-provider fallback footer. |
| `loading…`, `load more`, `nothing here` | Pagination states. |

Every result row shows `<title>`, `<artist>`, optional ` · <album>`, and a source badge. Its menu can show:

- `add to queue`;
- `play next`;
- `play on connect device`;
- `save to library` / `in your library`;
- `choose youtube source…`;
- `download` / `remove download`;
- `add to playlist`;
- playlist names, with a checkmark when already included;
- `new playlist…`.

### New playlist and add-to-playlist menus

- title: `new playlist`;
- field: `playlist name`;
- buttons: `create`, `cancel`;
- menu action: `new playlist…`;
- existing playlists appear by their user-entered names and show a checkmark when the track is already present.

### Library root

Visible copy:

- navigation title `library`;
- segmented tabs `playlists`, `artists`, `albums`, `songs`;
- matching search prompts `playlists`, `artists`, `albums`, or `songs`;
- toolbar actions `update library` and `import`;
- import items `add your own song`, `spotify playlist`, `youtube playlist`, `youtube link`;
- playlist action `new playlist`.

Empty/status copy:

- `no playlists yet. use import in the top right to bring in a spotify playlist.`
- `<count> tracks`, optionally followed by ` · from spotify` or ` · from youtube`;
- `nothing here yet. songs you play or import show up in your library automatically. use the update button if a playlist's songs are missing.`
- `nothing here yet. songs you play or import show up in your library automatically.`
- `no albums found`;
- `songs appear here after you play or import them.`
- `no matches`;
- `<artist> · <count> song/songs`;
- update toast `library is up to date` or `added <count> song/songs to your library`.

Secret-search toast:

- `you found the original wolf. check settings → appearance.`

### Artist page

The header displays `<artist>` and `<count> song/songs`. Buttons are `play` and `shuffle`. Extra remote results use section title `more on spotify`.

The `…` menu contains:

- `choose photo`;
- `find photo on spotify`;
- `remove my photo` when a custom photo exists.

Toasts:

- `found a photo on spotify`;
- `no photo found on spotify`;
- `couldn't crop that image`.

### Album page

The header displays `<album>`, `<album artist>`, and track count. Buttons are `play` and `shuffle`.

The artwork menu contains:

- `choose still album cover`;
- `choose animated album cover`;
- `use original covers` when album still art exists;
- `remove animated album cover` when album video exists.

Toasts:

- `couldn't use that image`;
- `album cover updated`;
- `animated album cover updated`.

### Local playlist page and queue

Playlist page copy/actions:

- `<playlist name>` and `<count> tracks`;
- `play`, `shuffle`, `Edit`;
- `empty. use the … menu on any track to add it here.`;
- menu `rename`, `choose cover`, `remove custom cover`, `delete playlist`;
- rename sheet title `rename`, field `name`, button `save`;
- dialog `delete this playlist?`, buttons `delete`, `cancel`;
- fallback `playlist not found`.

Queue copy:

- title `queue`;
- empty heading `the queue is empty`;
- empty caption `play something and what's coming next shows up here`;
- sections `now playing`, `up next`, and `played`;
- up-next detail `<count> song/songs · <remaining queue time>`;
- rows show `<title>`, `<artist>`, and optional `<duration>`;
- Edit mode allows reorder and removal.

### Add local songs

| Copy | Meaning |
|---|---|
| `add a song` / `add songs` | Title changes for one versus multiple files. |
| `song file` | File section. |
| `choose audio files` / `<filename>` / `<count> files chosen` | File picker state. |
| `cover (optional)` | Artwork section. |
| `choose a picture` / `change picture` | Cover picker. |
| `details` | Metadata section. |
| `filled in from the file when it has tags. only the name is needed.` | Single-file footer. |
| `each song takes its name, cover and tags from its own file. artist and album, when filled in, apply to every file.` | Multi-file footer. |
| `song name`, `artist (optional)`, `album (optional)` | Fields. |
| `lyrics (optional)` | Lyrics section. |
| `plain words (saved as unsynced), or lrc lines with timestamps like [00:12.00].` | Accepted text. |
| `cancel`, `add` | Toolbar actions. |

Completion/error toasts:

- `couldn't read that audio file` / `couldn't read those audio files`;
- `added <name>`;
- `added <count> songs`;
- `added <successful> of <selected> songs`.

### Spotify playlist import

- title `import spotify playlist`;
- `connect spotify in settings first.`;
- section `from a link`;
- footer `paste a spotify playlist link.` or dynamic status;
- field `spotify playlist link`;
- button `import`;
- section `your spotify playlists`;
- per-playlist `import` / `refresh`;
- pagination `loading…` / `load more`;
- toolbar `done`;
- toast `imported <count> tracks from <playlist name>`.

### Add from YouTube

- title `add from youtube`;
- toolbar `cancel` before adding, `done` afterward;
- section `youtube link` with footer `paste a youtube link or a video id.`;
- field `link or id`, button `look up`;
- section/field `search youtube`, button `search`;
- section `selected video`;
- video row `<video title>` and `<channel> · <duration or ?>`;
- toggle `match to a spotify track`;
- footer `matching uses the spotify track for the name, cover and album. the video stays the source.`;
- progress `matching…`;
- `change match`;
- `no spotify match found. it will be added as a youtube-only track.`;
- `search spotify`;
- section `details` with `song name`, `artist`, `album (optional)`;
- button `add to library`;
- completion `<title>`, `added to your library`, `add to a playlist`, `add another`.

Toasts are `that isn't a youtube link or id`, `no results`, and `added <title>`.

### YouTube playlist import

Start/progress/error copy:

- title `import youtube playlist`;
- `cancel`;
- `paste a youtube playlist link. you can review everything before it's added.`;
- field `youtube playlist link`;
- `find tracks`;
- `spotify isn't connected, so every video is added as a youtube-only track.`;
- `reading the playlist…` with `<count> videos found`;
- `matching tracks…` with `<done> of <total>`;
- `stop`;
- dynamic failure reason and `try again`.

Review copy:

- `<count> videos found. green = good match, orange = please check, grey = no spotify match. tap a row to change it. only ticked songs are added.`;
- `show only tracks that need checking (<count>)`;
- badges `good match`, `check this`, `no spotify match`;
- source line `▶ <video title> · <channel> · <duration or ?>`;
- button `import <count> tracks`;
- toast `imported <count> tracks into "<playlist title>"`.

Edit-match sheet:

- title `edit match`, button `done`;
- section `the playlist's video`;
- section `spotify track` / `no spotify match yet`;
- field `search spotify for the right track`, button `search`;
- section `youtube source`;
- footer `verified against the spotify track` or `chosen by you; <reasons>`;
- `choose a different youtube video`.

### Choose YouTube source

- title `choose youtube source`;
- section `spotify track`;
- section `search youtube`;
- footer `your pick is checked before it's saved.`;
- fields `search for a different video`, `or paste a youtube link / id`;
- buttons `search`, `use`, `cancel`, `use this`;
- results heading `searching…` / `results`;
- empty text `no youtube results`;
- result metadata `<channel or unknown channel> · <duration or ?>`;
- assessment `good match` or dynamic mismatch reason;
- warning dialog `this video may not match`, buttons `use anyway`, `choose another`;
- rejection alert `can't use this video`, button `ok`, plus dynamic reason.

### Song audio-source editor

- title `audio source`;
- track-title section with footer `renaming doesn't change the match.`;
- current mapping/source details;
- resolve/recheck actions and dynamic progress;
- `clear mapping`;
- section `set manually`;
- footer `paste a youtube link.`;
- field `youtube link or id`;
- button `use this video`;
- section `search youtube`;
- footer `results are checked against the song.`;
- button `search` / `searching…`;
- candidate suffix ` · good match` or ` · <reason>`.

Possible toasts include `found a source: <origin>`, `couldn't find a source`, `that isn't a youtube link or id`, and `no youtube results`.

### Per-song source section

- section `play this song from`;
- footer `attached files are copied into furmuse.`;
- picker values `default`, `spotify`, `local file`, `youtube`;
- warning `spotify isn't ready: <reason>`;
- key `local file` → `<original filename>`;
- `attach an audio file` / `replace audio file`;
- `remove file`;
- toasts `file attached` / `couldn't read that file`.

### Song details and custom artwork

- title `song details`;
- confirmation action `save & close`;
- section `artwork`;
- footer `custom artwork stays on this phone. song artwork takes priority over the album cover.`;
- `choose still cover`;
- `choose animated cover`;
- `animated artwork is used in the player and on supported lock screens. your original square cover stays unchanged and is used with reduced motion.`;
- `reset custom covers`;
- section `details`;
- footer `these names only change how the song appears in furmuse.`;
- row/field names `title`, `artist`, `album`;
- `reset song details`;
- toast `changes saved`.

Media errors are `couldn't crop that image`, `couldn't read that video`, and `couldn't crop that video`.

### Lyrics screen

The title is the current song title or `lyrics`. With no current song it shows `nothing playing`.

The menu contains:

- `create lyric card`;
- `import lyrics file`;
- `paste lyrics`;
- `sync lyrics`;
- submenu `romanization`;
- `off`, `romanized words`, `small text below`, `current line only`, `use app default`;
- `search lrclib again`;
- `remove my lyrics`.

Body states can show:

- parsed lyric lines and optional romanization/background vocals;
- `lyrics are off`;
- `no lyrics stored for this track`;
- `no lyrics found`;
- `couldn't read that lyrics file`;
- provider/loading status from `LyricsStore`.

### Paste and sync lyrics

Paste sheet:

- title `paste lyrics`;
- instruction `plain words are saved as unsynced lyrics. lrc or ttml text keeps its timing.`;
- buttons `save`, `cancel`;
- toast `lyrics saved` or `lyrics saved. they are off right now, turn them on in settings to see them`.

Sync editor:

- title `sync lyrics`;
- editor buttons `cancel`, `edit text`, `save`;
- section `lyrics`;
- footer `one lyric per line. a blank line leaves a gap between stanzas and is never stamped. pasted lrc text can be imported as it is.`;
- section `how to sync`;
- picker `sync`: `line by line`, `word by word`;
- picker `save as`: `lrc`, `ttml`;
- footer `word by word saves enhanced lrc or ttml word timing. save without timing keeps the words as plain unsynced lyrics.`;
- `start syncing`;
- `save without timing`;
- transport time `<position>` and `of <duration>`;
- accessibility controls `back 5 seconds`, `pause` / `play`, `forward 5 seconds`;
- stamping/restart controls shown by the active stage.

Dialogs:

- `this text has timestamps`: `import it as it is`, `remove timestamps and stamp it again`, `cancel`;
- `clear all stamps?`: `restart`, `cancel`;
- `discard your stamps?`: `discard`, `keep working`.

### Lyric card composer

- title `lyric card`;
- toolbar `cancel`, `share`;
- section `background`;
- choices `colour`, `album`, `artist`;
- dynamic missing-image footer `there's no <background type> for this song yet, so the colour is used.`;
- artist footer `until an artist photo is found or chosen, the album cover is used. you can change the artist photo from the artist's page in the library.`;
- controls `colour`, `blur`, `darken`;
- section `text`;
- footer `current line only is shown as small text below on a card, because a still image can't animate.`;
- romanization values `off`, `romanized`, `small text below`;
- `size`;
- `show furmuse`;
- selection footer `pick up to five lines.`;
- toast `choose up to five lyric lines`;
- failure toast `couldn't create lyric card`.

### Spotify account settings

- title `spotify`;
- the full `spotify client id` section listed under setup;
- section `account`;
- `status` → `connected`, `not checked yet`, or `not connected`;
- `please disconnect and connect again once.` when scopes are outdated;
- `account` → `<Spotify account name>`;
- `check connection`;
- `disconnect`;
- `connect spotify` / `waiting…`;
- `<authentication error>`;
- `add your client id above first`;
- footer `needs spotify premium.`;
- link `open spotify`.

### Spotify player settings

- title/section `spotify player`;
- footer `standard just works. "with effects" lets speed, pitch and effects work on spotify songs, but needs extra setup.`;
- picker `mode`: `standard`, `with effects`.

With-effects setup:

- section `setup`;
- footer `everything must be green for spotify songs to play.`;
- checks `included in this app`, `spotify connected`, `signed in for effects`, `ready`;
- fixes `not included in this build`, `connect it in settings → spotify`, `tap "sign in" below`, `tap "test" below`;
- `sign in` / `signing in…` / `sign out`;
- `test` / `testing…`;
- success `all good.` or a dynamic blocker/error.

Standard Web Player status:

- section `status`;
- footer `needs spotify premium. "Furmuse" then shows up in your spotify speaker list.`;
- dynamic readiness rows and repair text;
- `tap the bar at the top of the screen once to start.` when browser interaction is required;
- `use your phone's volume buttons for spotify songs.`;
- `restart player`;
- `use Furmuse as my speaker`;
- dynamic operation note.

### Last.fm settings

- title `last.fm`;
- section `last.fm keys`;
- footer `get them free at last.fm/api/account/create.`;
- secure fields `api key` / `key saved` and `shared secret` / `secret saved`;
- `save`;
- section `account`;
- status `not set up`, `signed out`, `signed in`, or `sign in again`;
- `sign in` / `sign out` and the authenticated username where available;
- section `send plays from`;
- footer `last.fm gets the original song info, even if you renamed it.`;
- per-source choices for Spotify, local files, and YouTube;
- section `double counting` when Spotify-linked Last.fm may duplicate scrobbles;
- warning/confirmation copy explaining the duplicate risk.

Service toasts include `last.fm session expired, sign in again`, `last.fm: <error>`, and dynamic authentication messages.

### Speed, volume, and sound-effects settings

Speed & volume:

- title `speed & volume`;
- section/row `speed`, live `<rate>x`;
- footer `pitch changes with speed unless pitch lock is on.`;
- `pitch lock`;
- `reset to 1.00x`;
- section `volume`;
- picker `repeat`: `off`, `playlist`, `one song`.

Sound effects:

- title `sound effects`;
- footer `equalizer, bass and reverb switch spotify to "with effects" mode.`;
- `pitch <signed semitone value>`;
- `equalizer`;
- bands `deep`, `bass`, `mid`, `treble`, `high`;
- `bass boost`;
- `reverb`;
- picker `room` with system reverb preset names;
- `amount`.

### Source settings

- title `where songs play from`;
- section `play songs from`;
- footer `downloads and files you attached always play first.`;
- picker `default`: `youtube`, `spotify`, `files & downloads`;
- warning `spotify isn't ready: <reason>`;
- footer `pick the right youtube video yourself when you play from search.`;
- toggle `ask me to pick the video`;
- row `spotify player` → `standard` / `with effects`;
- section `youtube lookup`;
- picker `use`: `youtube`, `my own server`, `my server, then youtube`;
- status `youtube` → `ready` / `unavailable`;
- status `my server` → `set` / `not set`;
- section `my own server`;
- footer `optional. a web address on your own network.`;
- placeholder `http://192.168.1.10:8080/resolve`;
- toggles `use downloads first`, `offline mode`.

### Downloads settings

- title `downloads`;
- toggles `wi-fi only`, `use downloads first`, `offline mode`;
- key `space used` → `<formatted byte count>`;
- section `downloaded songs`;
- empty state `nothing yet`;
- each row shows `<song title>` and `<formatted byte count>`;
- swipe-to-delete removes the downloaded file but keeps the library song.

Download toasts/errors are `offline mode is on` and `download failed: <resolver or system error>`.

### Lyrics settings

- title `lyrics`;
- footer `lyrics are saved on your phone.`;
- toggles `show lyrics`, `find lyrics online`, `search more sites`;
- section `highlighting`;
- picker `style`: `classic`, `laser`;
- toggles `highlight word by word`, `guess when timing is missing`;
- section `romanization`;
- footer `you can override this for a single song from the ... menu in lyrics.`;
- toggle `romanization`;
- picker `show romanization as`: `romanized words`, `small text below`, `current line only`;
- section `text size`.

Lyrics-screen status copy not listed earlier also includes:

- `finding lyrics…`;
- `no lyrics available`;
- `use the … menu to add synced lyrics.`;
- `these lyrics aren't timed. use sync lyrics in the … menu to time them.`;
- `couldn't read that file`;
- `remove your lyrics first` when refresh would immediately be overridden by a user file.

### Library and backup settings

- title `library`;
- section `backup`;
- footer `restoring only adds things. nothing is replaced or deleted.`;
- counters `songs`, `playlists`, `youtube matches`;
- `save backup`, `restore backup`;
- section `renames`;
- footer `change how a name looks in this app.`;
- existing entries `artist: <original>` / `album: <original>` → `<display name>`;
- kind picker `artist`, `album`;
- fields `original name`, `show as`;
- button `add`;
- restore toast `couldn't read that file` or `added <count> new items`.

### Animated-cover settings

- title `animated covers`;
- section `priority`;
- footer `when both services find a match, furmuse uses this one first and falls back to the other.`;
- picker `use first`: `spotify canvas`, `apple music animated`;
- section `apple music covers`;
- footer `on by default. artist and album names are sent to the server below to find moving covers.`;
- toggle `use apple covers`;
- field `server`;
- section `spotify canvas`;
- footer `the short looping videos from spotify. furmuse uses a public community service by default; you can replace its address here. canvas is unofficial and may break if spotify changes it.`;
- toggle `use spotify canvas`;
- field `service address`;
- `restore default service`;
- `saved` → `<cached count>`;
- dynamic Canvas status;
- `test with current song`;
- `clear canvas videos`;
- section `get covers ready`;
- footer `looks up covers for your whole library, so they're ready before you play.`;
- progress `<done> of <total> · <found> found`;
- `stop`;
- `get covers for my library (<count> songs)`;
- dynamic Apple-cover status;
- `clear apple covers`.

Test toasts are `play a spotify song first`, `canvas is working`, and `this song has no canvas`.

### Appearance settings

- title `appearance`;
- section/picker `theme`;
- choices `system`, `light`, `dark`, `black`;
- section `lock screen`;
- footer `needs ios 26. some phone settings turn animations off.`;
- toggles `animate lock screen covers`, `show current lyric as artist`;
- unlocked section `secret icon`;
- footer `unlocked by finding the hidden phrase in your library.`;
- toggle `use the original wolf icon`;
- errors `alternate icons aren't supported on this device` and `couldn't change icon: <system error>`.

### More, diagnostics, and reset

More screen:

- title `more`;
- `show error messages`;
- `clear saved lyrics`;
- `problem report`;
- section `keys`;
- `spotify client id`, `last.fm key`, `last.fm secret` → `set` / `missing`;
- `reset settings`;
- `redo setup`;
- `erase everything`;
- `version` → `<short version> (<build>)`.

Confirmation dialog:

- title `are you sure?`;
- destructive button repeats `reset settings`, `redo setup`, or `erase everything`;
- `cancel`;
- settings message `puts every setting back how it started.`;
- setup message `shows the setup screens again. accounts stay connected.`;
- erase message `removes your accounts, downloads, playlists and settings from this phone.`.

Problem report:

- title `problem report`;
- footer `passwords and keys are hidden from this report.`;
- `refresh`;
- `share report`;
- `clear report`;
- section `recent`;
- up to 200 recent log lines in monospaced selectable text.

### Artwork cropper

- title `crop artwork`;
- picker `shape` with `square 1:1` and `tall 3:4`;
- instruction `drag to move, pinch to zoom. cut away any black bars or borders: only what is inside the frame is kept.`;
- buttons `cancel`, `use`;
- a spinner replaces `use` while video/image processing finishes.

### Spotify Connect device picker and remote

Device picker:

- title `connect device`;
- `connect spotify first. devices are discovered from your spotify account.`;
- section `selected`;
- footer `furmuse remote-controls the speaker you pick.`;
- key `device` → `<selected name>`;
- `that speaker is offline. open spotify on it and refresh.`;
- `forget selection`;
- section `available`;
- footer `no speakers found. open spotify on one, then refresh.` or `press and hold to rename.`;
- device detail `<real name> · <type>`, optionally ` · active` and ` · restricted`;
- context action `set local name`;
- toolbar `refresh`;
- rename title `rename`, field `local name`, button `save`;
- footer `local name for <device>. leave empty to use the real name.`;
- toast `this device can't be selected` or `pick a connect device first`.

Remote screen copy uses the selected device name, current Spotify state, and transport actions. Status text is dynamic because it comes from Spotify's current player response.

### Static footer and branding copy

The settings root ends with:

`made sloppily to satisfy my own quirk - @mrwolfstip`

Generated lyric cards can include the branding text:

`furmuse`

### Cross-screen toast and failure templates

These messages can originate below the current screen and therefore belong to the global copy inventory:

- `pick a connect device first`;
- `last.fm session expired, sign in again`;
- `last.fm: <error>`;
- `fill in both boxes`;
- `saved`;
- `couldn't save that image`;
- `couldn't use that video`;
- `offline mode is on`;
- `download failed: <error>`;
- `saved <count> tracks to a local playlist`;
- `couldn't enable spotify audio: <message>`;
- `the chosen youtube source for "<title>" stopped working, looking for another`;
- `duration mismatch: source is <duration>, track is <duration>`;
- `stored source for "<title>" has the wrong length, searching again`;
- `source saved, added to your library`;
- `some stamps were cleared because the text changed`;
- `the song changed. close this and open sync lyrics again`;
- `that is before the last stamp. undo it or play on`;
- `source ok: <container> <codec>`;
- `couldn't verify`;
- `found a source: <origin>`;
- `couldn't find a source`.

Remote/API and operating-system error text is appended dynamically to the relevant prefix. Song, artist, album, playlist, device, provider, format, duration, count, version, cache status, and progress values are likewise dynamic rather than separately hard-coded sentences.

### Standard Spotify player status copy

The standard Web Playback player exposes a health checklist inside Spotify player settings:

- section `status`;
- footer `needs spotify premium. "furmuse" then shows up in your spotify speaker list.`;
- `client id added`, with the fix `add it in settings → spotify`;
- `spotify connected`, with a live blocker or `connect it in settings → spotify`;
- `player ready`, with a live error or `starts by itself`;
- key `speaker name` → `furmuse` when ready;
- `tap the bar at the top of the screen once to start.` when browser audio activation is required;
- `use your phone's volume buttons for spotify songs.` when remote volume cannot be controlled;
- buttons `restart player` and `use furmuse as my speaker`;
- completion text `done.` or the returned transfer error.

The checklist updates from the live Web Playback session. Restart rebuilds the session; the speaker button transfers the Spotify account's playback to furmuse without forcing it to start.

### Manual lyric-sync stamping copy

After text entry and the choice of line or word timing, the sync editor becomes a two-part workspace:

- section `song position`, containing play/pause, seeking, and the live song position;
- section title `next word`, `next line`, or `done`;
- footer `press stamp the moment each word starts.` or `press stamp the moment each line starts.`;
- finished prompt `all stamped. check the list below, then save.`;
- footer `tap a stamped item to go back to it.`;
- actions `undo last stamp` and `restart`;
- section `stamped`;
- empty state `nothing stamped yet`;
- word progress `<completed> of <total> words`;
- bottom control `stamp` and then `all stamped`;
- accessibility labels use the same `stamp` and `all stamped` copy.

Pressing the large bottom control records the current playback position on touch-down, which avoids adding button-release latency. Tapping an earlier stamped row removes that row and everything after it, then seeks two seconds before the chosen point. `undo last stamp` does the same for only the most recent stamp. `restart` asks before clearing the timing pass. Saving produces line-timed LRC or word-timed TTML, depending on the selected mode.

### Remote playback screen copy

The remote screen is titled `remote` and uses the selected Spotify Connect device name as its first section heading. It displays:

- `<song title>`;
- `<artist>`;
- `playing` or `paused`;
- `loading…` before the first response;
- `nothing is playing on that device` after a successful empty response;
- previous, play/pause, and next icon controls;
- a volume slider;
- footer `this speaker's volume can't be changed here.` when the device cannot expose volume;
- button `move spotify playback to this device`;
- toolbar action `refresh`.

Transport actions call Spotify Connect and then reload the remote state. Moving playback selects the configured speaker and starts it. Volume changes are sent when the user releases the slider.

## 25. Screen-to-source implementation index

This index covers the actual interactive screens, sheets, and major reusable surfaces in the current source tree. Small drawing-only helpers such as backgrounds, artwork wrappers, row renderers, and glass-card modifiers are listed with their parent rather than presented as separate user screens.

| User-facing surface | Main SwiftUI implementation | Source file |
| --- | --- | --- |
| Launch routing and waveform splash | `RootView`, `LaunchSplash`, `LoadingView` | `Sources/ui/rootview.swift` |
| First-run setup | `SetupView` | `Sources/ui/setupview.swift` |
| Spotify client ID form | `ClientIDSection` | `Sources/ui/clientidview.swift` |
| Main tabs and persistent tab bar | `MainView`, `TransparentTabBar` | `Sources/ui/mainview.swift` |
| Home and now playing | `PlayerView`, `SpeedSheet`, `NowPlayingArt`, `NowPlayingBackground` | `Sources/ui/mainview.swift` |
| Search and Spotify result pagination | `SearchView`, `SpotifyPagedList`, `SpotifyPlaylistsView` | `Sources/ui/browse.swift` |
| Library browser | `LibraryView` | `Sources/ui/libraryview.swift` |
| Artist page | `ArtistTracksView` | `Sources/ui/libraryview.swift` |
| Album page and artwork controls | `AlbumTracksView` | `Sources/ui/libraryview.swift` |
| Spotify playlist import | `SpotifyImportView` | `Sources/ui/libraryview.swift` |
| Local playlist and new-playlist sheet | `LocalPlaylistView`, `NewPlaylistSheet` | `Sources/ui/browse.swift` |
| Queue editing | `QueueView`, `QueueHeader`, `QueueRow` | `Sources/ui/browse.swift` |
| Add local audio files | `AddTrackView` | `Sources/ui/addtrack.swift` |
| Add one YouTube song | `YouTubeSongView` | `Sources/ui/youtubesong.swift` |
| Import a YouTube playlist | `YouTubeImportView`, `ImportItemEditor` | `Sources/ui/youtubeimport.swift` |
| Pick or replace a YouTube source | `YouTubeSourcePicker` | `Sources/ui/youtubesourcepicker.swift` |
| Song details, overrides, source controls, Spotify device picker, and remote | `MappingView`, `OverrideView`, `TrackSourceSection`, `DevicePickerView`, `RemoteView` | `Sources/ui/detail.swift` |
| Source-choice presentation shared by playback entry points | `SourceChooserModifier` | `Sources/ui/sourcechoice.swift` |
| Linked album page | `TrackAlbumPage` | `Sources/ui/tracklinks.swift` |
| Lyrics display | `LyricsView`, `LyricLineView`, `LyricsBackdrop` | `Sources/ui/detail.swift` |
| Paste/import and manually sync lyrics | `LyricPasteSheet`, `LyricSyncEditor`, `SyncTransport` | `Sources/ui/lyricsync.swift` |
| Lyric-card editor and export | `LyricCardComposer` | `Sources/ui/detail.swift` |
| Artwork cropper | `ArtworkCropView` | `Sources/ui/artworkcrop.swift` |
| Settings index | `SettingsView`, `SettingsRow` | `Sources/ui/settingsviews.swift` |
| Appearance | `AppearanceSettingsView` | `Sources/ui/settingsviews.swift` |
| Speed and volume | `PlaybackSettingsView` | `Sources/ui/settingsviews.swift` |
| Sound effects | `EffectsSettingsView` | `Sources/ui/settingsviews.swift` |
| Playback-source selection | `SourceSettingsView` | `Sources/ui/settingsviews.swift` |
| Spotify player backend and readiness | `SpotifyPlayerSettingsView`, `WebPlayerStatusSection` | `Sources/ui/settingsviews.swift` |
| Spotify account | `SpotifySettingsView` | `Sources/ui/settingsviews.swift` |
| Last.fm account and scrobbling | `LastfmSettingsView` | `Sources/ui/settingsviews.swift` |
| Downloads | `DownloadsSettingsView` | `Sources/ui/settingsviews.swift` |
| Lyrics preferences | `LyricsSettingsView` | `Sources/ui/settingsviews.swift` |
| Library backup and renaming | `LibrarySettingsView` | `Sources/ui/settingsviews.swift` |
| Animated-cover services | `AppleCoversSettingsView` | `Sources/ui/settingsviews.swift` |
| Advanced data/key/reset controls | `AdvancedSettingsView` | `Sources/ui/settingsviews.swift` |
| Diagnostics and log export | `DiagnosticsView` | `Sources/ui/sourcechoice.swift` |
| Global toast overlay | `ToastView` | `Sources/ui/rootview.swift` |

The document inventories app-owned visible copy. Values supplied by songs, users, Spotify, YouTube, Last.fm, iOS, network responses, or localized system pickers are identified as dynamic and are not falsely presented as fixed app strings. SF Symbol-only controls are described by function because they do not render a text label, while their accessibility labels are included where the source defines them.
