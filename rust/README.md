# librespot bridge (rust)

Compile status: the crate passes `cargo check --release` against the supplied librespot 0.8.0 on a Linux host (rust 1.89).
It has **not** been built for any iOS target, linked into the app, or run. Audio, login and playback are unproven.

## 0.2.1 build 4: why login said "Try another access point"

`librespot-core` 0.8.0 reads `std::env::consts::OS`. On iOS that is `"ios"`, so the AP handshake sends `PLATFORM_IPHONE_ARM64`
and the session defaults to the iOS client id. `connection/handshake.rs` documents that Android needs spoofing as linux
because otherwise all APs answer `TryAnotherAP` regardless of credentials; iOS takes the same path unspoofed.
`Session::connect` (session.rs) retries up to 6 APs on that code and then returns the last error as
`Permission denied { Login failed with reason: Try another access point }`, which matches the ~2.7 s failure in the log.
Fix: `core/src/config.rs` now maps iOS to `"linux"` (marked `WOLFIFIED PATCH`; `build.sh` refuses to run without it).
Not yet proven on a device: whether Spotify also accepts a token minted for wolfified's own client id.
The FFI now forwards librespot's log lines (chosen AP, retries) and returns classified error codes.

## build 4, second finding: login5 / client token

With the AP login fixed, track loading failed: `INVALID_CREDENTIALS` (credentials from client id A presented under id B),
then `HTTP 400` once the session used wolfified's own id (clienttoken.spotify.com only accepts spotify's own client ids).
So playback now signs in separately with librespot's built-in id (`LibrespotAuth`, Sources/spotifykit/librespotauth.swift),
the same flow as `librespot --enable-oauth`. One-time: settings > audio source > "sign in for playback".

## build 5: spotify connect

Root cause of "no Wolfified in the device list": the FFI only created a `Session` + `Player` (`_device_name` was reserved and
unused). Nothing registered the device with Spotify's connect-state service, so no client could ever see or control it.
(The earlier TryAnotherAP failure is a separate, already fixed cause: see build 4.)

Now `wolf_start` builds `Session` (unconnected) -> `Player` -> `Spirc::new(...)`, which performs `Session::connect` itself,
starts the dealer websocket, PUTs the device into the account's connect cluster and drives the `Player` when a client
transfers playback or sends play/pause/seek/next/prev/volume. A `WolfMixer` stores Spotify's volume and reports it to swift
(applied to wolfified's own output volume). Track metadata (`PlayerEvent::TrackChanged`) goes to swift, which shows it as the
current track and renders the pcm through the existing ring buffer/graph. The device id is random once per install (swift),
the name is "Wolfified". With the `zeroconf` cargo feature (default) the device is also advertised over mDNS;
`WOLF_NO_ZEROCONF=1 ./rust/build.sh sim` builds without it. Info.plist now declares `_spotify-connect._tcp`.

Behaviour to know: while a Spotify client controls Wolfified the decoder is held to 0.75 s ahead of the audio so the position
Spotify shows matches what you hear; starting a track from wolfified's own queue steps out of the connect session first.
Not verified: everything in this section needs a real build and a second Spotify client to prove.

## build for the ios simulator (what you need for testing)

    # one time
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh     # then open a new terminal
    xcode-select --install                                              # if you haven't

    # from the project folder (the one containing wolfified.xcodeproj and librespot-0.8.0/)
    ./rust/build.sh sim

The first build downloads and compiles several hundred crates (5 to 15 minutes). Then in Xcode: Product > Clean Build Folder, run.

`build.sh` writes `config/rust.xcconfig`, which `base.xcconfig` includes. That file adds the library and module path for the
simulator SDK only, so there is no xcframework and nothing to drag into Xcode. Delete it (or `./rust/build.sh clean`) and the app
builds without librespot and the Spotify source reports "not built".

Intel Mac simulator: `build.sh` builds for the machine it runs on. `SIM_FAT=1 ./rust/build.sh sim` builds arm64 and x86_64 together.
Real iPhone: `./rust/build.sh device` (or `all`). `build-xcframework.sh` is the older xcframework route and is no longer needed.

## Cargo.lock

`wolfified-librespot-ffi/Cargo.lock` is a copy of librespot 0.8.0's own lockfile. Without it, cargo picks newer `vergen` crates
and `librespot-core`'s build script fails to compile. Keep the file.

## design

    librespot decoder -> RingSink::write (f32, interleaved stereo, 44.1 kHz)
      -> 4 MiB in-memory SPSC ring (atomics only)
      -> wolf_pcm_read()  [AVAudioSourceNode render block]
      -> shared AVAudioEngine graph (time-pitch, eq, reverb) -> output

No PCM or encrypted audio is written to disk (`Session::new(config, None)`, no cache).

## open risks (only a run can settle these)

1. **login with wolfified's own token**: the PKCE token from your client id (plus the `streaming` scope) is handed to
   `Credentials::with_access_token`. Spotify may refuse it. Settings > audio source > "test connection" shows the result.
2. **ios compile**: librespot's dependencies have not been built for iOS here. Expect possible feature-flag or linker fixes.
3. **Connect is written but unrun** (see build 5 below): never compiled, never seen in a device picker.
4. **session loss**: polled every 2 s, no auto reconnect.
5. **seek**: a few already decoded packets can reach the ring after a flush.
