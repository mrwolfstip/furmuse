//! C ffi around librespot 0.8.0 for wolfified.
//!
//! NOT COMPILED. Written against the librespot 0.8.0 source in this repo (symbols checked by reading:
//! Spirc::new, ConnectConfig, Mixer, Discovery::builder, Session::new, Credentials::with_access_token,
//! Player::new/load/play/pause/seek/stop/set_session, Sink trait, Converter::f64_to_f32, PlayerEvent).
//! A real `cargo build --target aarch64-apple-ios` may still surface errors that only a compiler finds.
//!
//! Spotify Connect: `Spirc::new` owns the login (it calls Session::connect itself), registers this device with
//! Spotify's connect-state service over the dealer websocket (that is what makes "Wolfified" appear in every
//! Spotify client signed in to the same account) and drives the Player when another device selects us.
//! With the `zeroconf` feature the device is also advertised over mDNS (_spotify-connect._tcp).
//!
//! Audio path: librespot decoder -> RingSink::write (f32 interleaved stereo 44.1k) -> in-memory SPSC ring
//! -> wolf_pcm_read (called from the AVAudioSourceNode render callback). Nothing is written to disk.

use std::cell::UnsafeCell;
use std::ffi::{c_char, c_void, CStr, CString};
use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, AtomicU16, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use librespot_connect::{ConnectConfig, LoadRequest, LoadRequestOptions, PlayingTrack, Spirc};
use librespot_core::{
    authentication::Credentials,
    config::{DeviceType, SessionConfig},
    error::ErrorKind,
    session::Session,
    spotify_id::SpotifyId,
    SpotifyUri,
};
use librespot_metadata::audio::{AudioItem, UniqueFields};
use librespot_playback::{
    audio_backend::{Sink, SinkError, SinkResult},
    config::{Bitrate, PlayerConfig},
    convert::Converter,
    decoder::AudioPacket,
    mixer::{Mixer, MixerConfig, NoOpVolume},
    player::{Player, PlayerEvent, SinkStatus},
};

// ---------------------------------------------------------------------------------------------------------
// ring buffer: single producer (sink thread), single consumer (audio render thread), wait-free.
// capacity is in f32 samples (2 per frame). 2^20 samples = ~11.9 s of stereo at 44.1 kHz = 4 MiB.
// flush() never touches the consumer's index: it publishes `drop_to`, and both sides treat
// max(read, drop_to) as the real read position, so a flush works even while the engine is paused.
// ---------------------------------------------------------------------------------------------------------
const CAP: usize = 1 << 20;
const MASK: usize = CAP - 1;

struct Ring {
    buf: Box<[UnsafeCell<f32>]>,
    write: AtomicUsize,
    read: AtomicUsize,
    drop_to: AtomicUsize,
    underruns: AtomicU64,
}
unsafe impl Sync for Ring {}
unsafe impl Send for Ring {}

impl Ring {
    fn new() -> Self {
        let mut v = Vec::with_capacity(CAP);
        v.resize_with(CAP, || UnsafeCell::new(0.0));
        Ring {
            buf: v.into_boxed_slice(),
            write: AtomicUsize::new(0),
            read: AtomicUsize::new(0),
            drop_to: AtomicUsize::new(0),
            underruns: AtomicU64::new(0),
        }
    }

    #[inline]
    fn eff_read(&self) -> usize {
        let w = self.write.load(Ordering::Acquire);
        self.read.load(Ordering::Acquire).max(self.drop_to.load(Ordering::Acquire)).min(w)
    }

    // producer. writes whole frames only; returns samples written.
    fn push(&self, data: &[f32]) -> usize {
        let w = self.write.load(Ordering::Relaxed);
        let free = CAP - (w - self.eff_read());
        let n = data.len().min(free) & !1;
        for i in 0..n {
            unsafe { *self.buf[(w + i) & MASK].get() = data[i] };
        }
        self.write.store(w + n, Ordering::Release);
        n
    }

    // consumer. returns samples read (always even).
    fn pop(&self, out: &mut [f32]) -> usize {
        let w = self.write.load(Ordering::Acquire);
        let r = self.read.load(Ordering::Relaxed).max(self.drop_to.load(Ordering::Acquire)).min(w);
        let n = out.len().min(w - r) & !1;
        for i in 0..n {
            out[i] = unsafe { *self.buf[(r + i) & MASK].get() };
        }
        self.read.store(r + n, Ordering::Release);
        n
    }

    fn flush(&self) {
        self.drop_to.store(self.write.load(Ordering::Acquire), Ordering::Release);
    }

    fn buffered_frames(&self) -> usize {
        (self.write.load(Ordering::Acquire) - self.eff_read()) / 2
    }
}

// ---------------------------------------------------------------------------------------------------------
// the librespot sink: pcm goes into the ring and nowhere else. blocks (4 ms naps) while the ring is full,
// which is how librespot's own backends apply back-pressure to the decoder.
// ---------------------------------------------------------------------------------------------------------
struct RingSink {
    ring: Arc<Ring>,
    shutdown: Arc<AtomicBool>,
    flags: Arc<Flags>,
}

// while this device is the active Connect device the decoder must not run far ahead of what is audible, otherwise
// the position Spotify shows (decoder position) drifts from what is heard by the whole ring depth.
// 0.75 s of lead keeps the error under that while still allowing the 0.5 s prebuffer gate on the swift side.
const CONNECT_LEAD_SAMPLES: usize = 33075 * 2;

impl Sink for RingSink {
    fn write(&mut self, packet: AudioPacket, converter: &mut Converter) -> SinkResult<()> {
        let samples = match packet {
            AudioPacket::Samples(s) => s,
            AudioPacket::Raw(_) => {
                return Err(SinkError::OnWrite("passthrough audio isn't supported".into()))
            }
        };
        let f: Vec<f32> = converter.f64_to_f32(&samples);
        let mut off = 0;
        while off < f.len() {
            if self.shutdown.load(Ordering::Relaxed) {
                return Err(SinkError::NotConnected("shutting down".into()));
            }
            let limit = if self.flags.active.load(Ordering::Relaxed) { CONNECT_LEAD_SAMPLES } else { CAP };
            let room = limit.saturating_sub(self.ring.buffered_frames() * 2);
            let end = (off + room).min(f.len());
            let n = if end > off { self.ring.push(&f[off..end]) } else { 0 };
            if n == 0 {
                std::thread::sleep(Duration::from_millis(4));
            } else {
                off += n;
            }
        }
        Ok(())
    }
}

// ---------------------------------------------------------------------------------------------------------
// handle + events
// ---------------------------------------------------------------------------------------------------------
pub type WolfEventCb = extern "C" fn(*mut c_void, i32, i64, i64, *const c_char);

#[derive(Clone, Copy)]
struct Callback {
    cb: WolfEventCb,
    ctx: *mut c_void,
}
unsafe impl Send for Callback {}
unsafe impl Sync for Callback {}

impl Callback {
    fn emit(&self, kind: i32, a: i64, b: i64, text: &str) {
        let c = CString::new(text.replace('\0', " ")).unwrap_or_default();
        (self.cb)(self.ctx, kind, a, b, c.as_ptr());
    }
}


// ---------------------------------------------------------------------------------------------------------
// librespot's own log lines (AP host chosen, "Instructed to try another access point", authenticated...)
// go nowhere unless a logger is installed. forward info and above to swift as event kind 10
// (a = 1 error, 2 warn, 3 info). tokens are never logged by librespot at these levels; the username is dropped here.
// ---------------------------------------------------------------------------------------------------------
static LOG_CB: Mutex<Option<Callback>> = Mutex::new(None);
struct FfiLogger;
static LOGGER: FfiLogger = FfiLogger;

impl log::Log for FfiLogger {
    fn enabled(&self, m: &log::Metadata) -> bool {
        m.level() <= log::Level::Info && m.target().starts_with("librespot")
    }
    fn log(&self, r: &log::Record) {
        if !self.enabled(r.metadata()) {
            return;
        }
        let Ok(g) = LOG_CB.lock() else { return };
        let Some(cb) = *g else { return };
        let mut text = format!("{}", r.args());
        if text.starts_with("Authenticated as") {
            text = "Authenticated".to_string();
        }
        let lvl = match r.level() {
            log::Level::Error => 1,
            log::Level::Warn => 2,
            _ => 3,
        };
        cb.emit(10, lvl, 0, &text);
    }
    fn flush(&self) {}
}

fn install_logger(cb: Callback) {
    if let Ok(mut g) = LOG_CB.lock() {
        *g = Some(cb);
    }
    let _ = log::set_logger(&LOGGER);
    log::set_max_level(log::LevelFilter::Info);
}

// maps a librespot login error to a stable code the swift side can classify:
// -3 spotify rejected the credential, -6 every AP answered TryAnotherAP, -4 network/unavailable, -5 anything else
fn classify(e: &librespot_core::Error) -> i32 {
    let msg = e.to_string();
    if msg.contains("Try another access point") {
        -6
    } else {
        match e.kind {
            ErrorKind::PermissionDenied | ErrorKind::Unauthenticated => -3,
            ErrorKind::Unavailable | ErrorKind::DeadlineExceeded => -4,
            _ => -5,
        }
    }
}

// shared flags between the ffi calls, the sink and the event task
struct Flags {
    active: AtomicBool,     // this device is the active Spotify Connect device (set by SessionConnected/Disconnected)
    eot: AtomicBool,        // EndOfTrack seen: the next Loading is a natural transition, keep the buffered tail
    local_seek: AtomicBool, // a seek that swift asked for through wolf_seek (already flushed the ring)
}

// state that changes when zeroconf hands us another account's credentials
struct Shared {
    spirc: Mutex<Option<Spirc>>,
    session: Mutex<Session>,
}

pub struct WolfHandle {
    rt: Option<tokio::runtime::Runtime>,
    shared: Arc<Shared>,
    player: Arc<Player>,
    ring: Arc<Ring>,
    shutdown: Arc<AtomicBool>,
    flags: Arc<Flags>,
}

fn cstr(p: *const c_char) -> Option<String> {
    if p.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(p) }.to_str().ok().map(|s| s.to_owned())
}

// ---------------------------------------------------------------------------------------------------------
// volume: spotify clients set it through the Mixer. wolfified applies volume in its own audio graph, so the mixer only
// stores the value and tells swift (event 11, a = 0..65535). the player's own volume stage stays NoOpVolume.
// ---------------------------------------------------------------------------------------------------------
struct WolfMixer {
    vol: AtomicU16,
    cb: Callback,
}

impl Mixer for WolfMixer {
    fn open(_config: MixerConfig) -> Result<Self, librespot_core::Error>
    where
        Self: Sized,
    {
        Err(librespot_core::Error::unimplemented("WolfMixer is created by wolf_start"))
    }
    fn volume(&self) -> u16 {
        self.vol.load(Ordering::Relaxed)
    }
    fn set_volume(&self, volume: u16) {
        self.vol.store(volume, Ordering::Relaxed);
        self.cb.emit(11, volume as i64, 0, "");
    }
}

fn json_str(s: &str) -> String {
    let mut o = String::with_capacity(s.len() + 2);
    o.push('"');
    for c in s.chars() {
        match c {
            '"' => o.push_str("\\\""),
            '\\' => o.push_str("\\\\"),
            '\n' => o.push_str("\\n"),
            '\r' => o.push_str("\\r"),
            '\t' => o.push_str("\\t"),
            c if (c as u32) < 0x20 => o.push(' '),
            c => o.push(c),
        }
    }
    o.push('"');
    o
}

// metadata of the track spotify just put on this device, as json for swift (event 12)
fn track_json(item: &AudioItem) -> String {
    let id = item.track_id.to_id().unwrap_or_default();
    let (artist, album) = match &item.unique_fields {
        UniqueFields::Track { artists, album, .. } => (
            artists.iter().map(|a| a.name.as_str()).collect::<Vec<_>>().join(", "),
            album.clone(),
        ),
        UniqueFields::Local { artists, album, .. } => (artists.clone().unwrap_or_default(), album.clone().unwrap_or_default()),
        UniqueFields::Episode { show_name, .. } => (show_name.clone(), String::new()),
    };
    let cover = item.covers.first().map(|c| c.url.clone()).unwrap_or_default(); // covers are sorted largest first
    format!(
        "{{\"id\":{},\"uri\":{},\"title\":{},\"artist\":{},\"album\":{},\"cover\":{},\"duration_ms\":{}}}",
        json_str(&id),
        json_str(&item.uri),
        json_str(&item.name),
        json_str(&artist),
        json_str(&album),
        json_str(&cover),
        item.duration_ms
    )
}

fn device_type(n: i32) -> DeviceType {
    match n {
        1 => DeviceType::Computer,
        2 => DeviceType::Tablet,
        4 => DeviceType::Speaker,
        5 => DeviceType::Tv,
        6 => DeviceType::Avr,
        _ => DeviceType::Smartphone,
    }
}

// ---------------------------------------------------------------------------------------------------------
// zeroconf (mDNS _spotify-connect._tcp + the http addUser endpoint). optional: the dealer registration above is what
// makes the device visible to the account's own clients; zeroconf additionally makes it visible on the local network
// and lets someone else's Spotify app log this device in. a failure here never affects the cloud registration.
// ---------------------------------------------------------------------------------------------------------
#[cfg(feature = "zeroconf")]
struct Zc(Option<librespot_discovery::Discovery>);
#[cfg(not(feature = "zeroconf"))]
struct Zc;

#[cfg(feature = "zeroconf")]
fn zc_launch(cb: Callback, name: &str, dt: DeviceType, device_id: &str, client_id: &str) -> Zc {
    match librespot_discovery::Discovery::builder(device_id.to_string(), client_id.to_string())
        .name(name.to_string())
        .device_type(dt)
        .launch()
    {
        Ok(d) => {
            cb.emit(10, 3, 0, "zeroconf: advertising _spotify-connect._tcp");
            Zc(Some(d))
        }
        Err(e) => {
            cb.emit(10, 2, 0, &format!("zeroconf unavailable: {e}"));
            Zc(None)
        }
    }
}
#[cfg(not(feature = "zeroconf"))]
fn zc_launch(cb: Callback, _n: &str, _d: DeviceType, _i: &str, _c: &str) -> Zc {
    cb.emit(10, 3, 0, "zeroconf: not built (cloud connect registration only)");
    Zc
}

#[cfg(feature = "zeroconf")]
async fn zc_next(z: &mut Zc) -> Option<Credentials> {
    use futures_util::StreamExt;
    match z.0.as_mut() {
        Some(d) => d.next().await,
        None => std::future::pending().await,
    }
}
#[cfg(not(feature = "zeroconf"))]
async fn zc_next(_z: &mut Zc) -> Option<Credentials> {
    std::future::pending().await
}

#[cfg(feature = "zeroconf")]
async fn zc_shutdown(z: Zc) {
    if let Some(d) = z.0 {
        d.shutdown().await;
    }
}
#[cfg(not(feature = "zeroconf"))]
async fn zc_shutdown(_z: Zc) {}

#[cfg(feature = "zeroconf")]
fn zc_none() -> Zc {
    Zc(None)
}
#[cfg(not(feature = "zeroconf"))]
fn zc_none() -> Zc {
    Zc
}

// keeps the connect device alive: waits for the spirc task and for zeroconf logins.
// a zeroconf login (someone picked Wolfified in their Spotify app on the LAN) replaces session + spirc, exactly like
// librespot's own main loop does. session loss without a new login is reported to swift, which restarts with a fresh token.
async fn supervise(
    sh: Arc<Shared>,
    flags: Arc<Flags>,
    cb: Callback,
    player: Arc<Player>,
    mixer: Arc<WolfMixer>,
    scfg: SessionConfig,
    ccfg: ConnectConfig,
    down: Arc<AtomicBool>,
    mut task: Pin<Box<dyn Future<Output = ()> + Send>>,
    mut zc: Zc,
) {
    let mut live = true;
    loop {
        if down.load(Ordering::Relaxed) {
            break;
        }
        tokio::select! {
            _ = async { (&mut task).await }, if live => {
                live = false;
                cb.emit(10, 2, 0, "connect: spirc task ended");
                // the connect loop is gone (dealer/session dropped). unless a zeroconf login replaces it, tell swift so it
                // restarts the whole session with a fresh token; otherwise the device silently vanishes from the picker.
                if !down.load(Ordering::Relaxed) {
                    flags.active.store(false, Ordering::Relaxed);
                    cb.emit(9, 0, 0, "connect task ended");
                }
            },
            creds = zc_next(&mut zc) => {
                let Some(creds) = creds else { zc = zc_none(); continue };
                cb.emit(10, 3, 0, "zeroconf: login received, switching session");
                let old = sh.spirc.lock().ok().and_then(|mut g| g.take());
                if let Some(s) = old { let _ = s.shutdown(); }
                if live {
                    let _ = tokio::time::timeout(Duration::from_secs(3), &mut task).await;
                    live = false;
                }
                let old_session = sh.session.lock().map(|g| g.clone()).ok();
                if let Some(s) = old_session { if !s.is_invalid() { s.shutdown(); } }
                flags.active.store(false, Ordering::Relaxed);
                let session = Session::new(scfg.clone(), None);
                player.set_session(session.clone());
                if let Ok(mut g) = sh.session.lock() { *g = session.clone(); }
                match Spirc::new(ccfg.clone(), session, creds, player.clone(), mixer.clone() as Arc<dyn Mixer>).await {
                    Ok((sp, t)) => {
                        if let Ok(mut g) = sh.spirc.lock() { *g = Some(sp); }
                        task = Box::pin(t);
                        live = true;
                        cb.emit(10, 3, 0, "connect: session ready after zeroconf login");
                    }
                    Err(e) => cb.emit(0, classify(&e) as i64, 0, &format!("connect login failed after zeroconf: {e}")),
                }
            },
            _ = tokio::time::sleep(Duration::from_millis(500)) => {}
        }
    }
    zc_shutdown(zc).await;
}

#[no_mangle]
pub extern "C" fn wolf_start(
    access_token: *const c_char,
    client_id: *const c_char, // the client id the token was minted for; login5 must use the same one
    device_name: *const c_char, // what Spotify clients show in the device picker
    device_id: *const c_char, // stable per-install id chosen by the app (never hardcoded here)
    dev_type: i32,            // 1 computer, 2 tablet, 3 smartphone, 4 speaker, 5 tv, 6 avr
    initial_volume: u16,      // 0..65535, what Spotify shows until a client changes it
    cb: WolfEventCb,
    ctx: *mut c_void,
    err: *mut i32,
) -> *mut WolfHandle {
    let set_err = |c: i32| {
        if !err.is_null() {
            unsafe { *err = c }
        }
    };
    let token = match cstr(access_token) {
        Some(t) if !t.is_empty() => t,
        _ => {
            set_err(-1);
            return std::ptr::null_mut();
        }
    };
    let rt = match tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build() {
        Ok(r) => r,
        Err(_) => {
            set_err(-2);
            return std::ptr::null_mut();
        }
    };
    let client_id = cstr(client_id).filter(|c| !c.is_empty());
    let name = cstr(device_name).filter(|n| !n.is_empty()).unwrap_or_else(|| "Wolfified".to_string());
    let dev_id = cstr(device_id).filter(|c| !c.is_empty());
    let callback = Callback { cb, ctx };
    install_logger(callback);
    callback.emit(10, 3, 0, "session creation started, authentication method: access token (streaming scope)");
    let ring = Arc::new(Ring::new());
    let shutdown = Arc::new(AtomicBool::new(false));
    let flags = Arc::new(Flags { active: AtomicBool::new(false), eot: AtomicBool::new(false), local_seek: AtomicBool::new(false) });

    let built = rt.block_on(async {
        // Session::new spawns tasks, so it must run inside the runtime
        let mut scfg = SessionConfig::default();
        if let Some(id) = client_id {
            scfg.client_id = id;
        }
        if let Some(id) = dev_id {
            scfg.device_id = id;
        }
        let session = Session::new(scfg.clone(), None); // no cache: nothing persisted

        let cfg = PlayerConfig {
            bitrate: Bitrate::Bitrate320,
            gapless: false,
            normalisation: false,
            ditherer: None,
            position_update_interval: None,
            ..PlayerConfig::default()
        };
        let sink_ring = ring.clone();
        let sink_down = shutdown.clone();
        let sink_flags = flags.clone();
        let player = Player::new(cfg, session.clone(), Box::new(NoOpVolume), move || {
            Box::new(RingSink { ring: sink_ring, shutdown: sink_down, flags: sink_flags }) as Box<dyn Sink>
        });

        let c2 = callback;
        player.set_sink_event_callback(Some(Box::new(move |s: SinkStatus| {
            let t = match s {
                SinkStatus::Running => "running",
                SinkStatus::Closed => "closed",
                SinkStatus::TemporarilyClosed => "temporarily_closed",
            };
            c2.emit(8, 0, 0, t);
        })));

        // player events -> C callback. events from Spirc-driven playback and from wolf_load look the same.
        let mut ch = player.get_player_event_channel();
        let c3 = callback;
        let ev_ring = ring.clone();
        let ev_flags = flags.clone();
        tokio::spawn(async move {
            while let Some(ev) = ch.recv().await {
                match ev {
                    PlayerEvent::Loading { .. } => {
                        // another device put a new track on us: drop the old track's buffered audio, unless this is the
                        // natural end-of-track hand-over (then the tail of the previous track must still play out)
                        let was_eot = ev_flags.eot.swap(false, Ordering::Relaxed);
                        if ev_flags.active.load(Ordering::Relaxed) && !was_eot {
                            ev_ring.flush();
                        }
                        c3.emit(1, 0, 0, "")
                    }
                    PlayerEvent::Playing { position_ms, .. } => c3.emit(2, position_ms as i64, 0, ""),
                    PlayerEvent::Paused { position_ms, .. } => c3.emit(3, position_ms as i64, 0, ""),
                    PlayerEvent::EndOfTrack { .. } => {
                        ev_flags.eot.store(true, Ordering::Relaxed);
                        c3.emit(4, 0, 0, "")
                    }
                    PlayerEvent::Unavailable { .. } => c3.emit(5, 0, 0, ""),
                    PlayerEvent::Seeked { position_ms, .. } => {
                        // b = 1: the seek came from a Spotify client, not from wolf_seek; the ring still holds pre-seek audio
                        let local = ev_flags.local_seek.swap(false, Ordering::Relaxed);
                        if !local && ev_flags.active.load(Ordering::Relaxed) {
                            ev_ring.flush();
                        }
                        c3.emit(6, position_ms as i64, if local { 0 } else { 1 }, "")
                    }
                    PlayerEvent::Stopped { .. } => c3.emit(7, 0, 0, ""),
                    PlayerEvent::TrackChanged { audio_item } => c3.emit(12, 0, 0, &track_json(&audio_item)),
                    PlayerEvent::SessionConnected { .. } => {
                        ev_flags.active.store(true, Ordering::Relaxed);
                        c3.emit(13, 1, 0, "active")
                    }
                    PlayerEvent::SessionDisconnected { .. } => {
                        ev_flags.active.store(false, Ordering::Relaxed);
                        c3.emit(13, 0, 0, "inactive")
                    }
                    PlayerEvent::SessionClientChanged { client_name, .. } => c3.emit(14, 0, 0, &client_name),
                    _ => {}
                }
            }
        });

        let mixer = Arc::new(WolfMixer { vol: AtomicU16::new(initial_volume), cb: callback });
        let ccfg = ConnectConfig {
            name: name.clone(),
            device_type: device_type(dev_type),
            initial_volume,
            ..ConnectConfig::default()
        };

        // Spirc::new performs Session::connect itself (it registers the dealer listeners first, which must happen before
        // the connection exists), so the session must NOT be connected beforehand. Session::connect already walks up to
        // 6 access points; do not wrap this in another retry loop.
        let (spirc, task) = match Spirc::new(
            ccfg.clone(),
            session.clone(),
            Credentials::with_access_token(token),
            player.clone(),
            mixer.clone() as Arc<dyn Mixer>,
        )
        .await
        {
            Ok(x) => x,
            Err(e) => return Err((classify(&e), e.to_string())),
        };
        callback.emit(10, 3, 0, "session ready");
        callback.emit(10, 3, 0, &format!("connect: device \"{}\" registered with spotify connect", name));

        let shared = Arc::new(Shared { spirc: Mutex::new(Some(spirc)), session: Mutex::new(session.clone()) });
        let zc = zc_launch(callback, &name, device_type(dev_type), &scfg.device_id, &scfg.client_id);
        let task: Pin<Box<dyn Future<Output = ()> + Send>> = Box::pin(task);
        tokio::spawn(supervise(
            shared.clone(),
            flags.clone(),
            callback,
            player.clone(),
            mixer.clone(),
            scfg.clone(),
            ccfg,
            shutdown.clone(),
            task,
            zc,
        ));

        // watch for session loss (reports once; swift restarts with a fresh token)
        let sh2 = shared.clone();
        let c4 = callback;
        let down = shutdown.clone();
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(Duration::from_secs(2)).await;
                if down.load(Ordering::Relaxed) {
                    break;
                }
                let invalid = sh2.session.lock().map(|s| s.is_invalid()).unwrap_or(false);
                if invalid {
                    // a zeroconf account switch swaps the session; give it a moment before calling it lost
                    tokio::time::sleep(Duration::from_secs(5)).await;
                    let still = sh2.session.lock().map(|s| s.is_invalid()).unwrap_or(false);
                    if still && !down.load(Ordering::Relaxed) {
                        c4.emit(9, 0, 0, "librespot session closed");
                        break;
                    }
                }
            }
        });

        Ok::<(Arc<Shared>, Arc<Player>), (i32, String)>((shared, player))
    });

    match built {
        Ok((shared, player)) => Box::into_raw(Box::new(WolfHandle { rt: Some(rt), shared, player, ring, shutdown, flags })),
        Err((code, e)) => {
            callback.emit(0, code as i64, 0, &format!("login failed: {e}"));
            set_err(code);
            rt.shutdown_background();
            std::ptr::null_mut()
        }
    }
}

#[no_mangle]
pub extern "C" fn wolf_stop(h: *mut WolfHandle) {
    if h.is_null() {
        return;
    }
    let mut h = unsafe { Box::from_raw(h) };
    // leave Spotify's device list cleanly: Spirc shutdown pauses, deregisters and closes the dealer connection
    if let Ok(mut g) = h.shared.spirc.lock() {
        if let Some(s) = g.take() {
            let _ = s.shutdown();
        }
    }
    if let Some(rt) = h.rt.as_ref() {
        rt.block_on(async { tokio::time::sleep(Duration::from_millis(400)).await });
    }
    h.shutdown.store(true, Ordering::Relaxed);
    h.player.stop();
    if let Ok(s) = h.shared.session.lock() {
        s.shutdown();
    }
    if let Some(rt) = h.rt.take() {
        rt.shutdown_timeout(Duration::from_secs(1));
    }
}

// transport/volume commands that must go through Spotify Connect while a Spotify client controls this device,
// so the cluster state (what the phone shows) stays the source of truth.
// cmd: 1 play, 2 pause, 3 next, 4 previous, 5 seek (arg = ms), 6 volume (arg = 0..65535), 7 disconnect (arg != 0 pauses)
// returns 0 ok, -1 no handle, -2 no connect session, -3 unknown command, -4 spirc refused (session closing)
#[no_mangle]
pub extern "C" fn wolf_connect_cmd(h: *mut WolfHandle, cmd: i32, arg: i64) -> i32 {
    let Some(h) = (unsafe { h.as_ref() }) else { return -1 };
    let Ok(g) = h.shared.spirc.lock() else { return -2 };
    let Some(s) = g.as_ref() else { return -2 };
    let r = match cmd {
        1 => s.play(),
        2 => s.pause(),
        3 => s.next(),
        4 => s.prev(),
        5 => s.set_position_ms(arg.clamp(0, u32::MAX as i64) as u32),
        6 => s.set_volume(arg.clamp(0, 65535) as u16),
        7 => s.disconnect(arg != 0),
        _ => return -3,
    };
    if r.is_ok() { 0 } else { -4 }
}

#[no_mangle]
pub extern "C" fn wolf_connect_active(h: *mut WolfHandle) -> bool {
    unsafe { h.as_ref() }.map(|h| h.flags.active.load(Ordering::Relaxed)).unwrap_or(false)
}

#[no_mangle]
pub extern "C" fn wolf_connect_load(h: *mut WolfHandle, track_id: *const c_char, position_ms: u32) -> i32 {
    let (Some(h), Some(id)) = (unsafe { h.as_ref() }, cstr(track_id)) else { return -1 };
    if SpotifyId::from_base62(&id).is_err() { return -2; }
    let Ok(g) = h.shared.spirc.lock() else { return -3 };
    let Some(spirc) = g.as_ref() else { return -3 };
    let uri = format!("spotify:track:{id}");
    let options = LoadRequestOptions {
        start_playing: true,
        seek_to: position_ms,
        playing_track: Some(PlayingTrack::Uri(uri.clone())),
        ..LoadRequestOptions::default()
    };
    if spirc.activate_and_load(LoadRequest::from_tracks(vec![uri], options)).is_err() { return -4; }
    0
}

#[no_mangle]
pub extern "C" fn wolf_load(h: *mut WolfHandle, track_id: *const c_char, start_playing: bool, position_ms: u32) -> i32 {
    let (Some(h), Some(id)) = (unsafe { h.as_ref() }, cstr(track_id)) else { return -1 };
    let Ok(id) = SpotifyId::from_base62(&id) else { return -2 };
    // a wolfified-initiated track while Spotify controls us: step out of the Connect session first (without pausing the
    // player, the load below follows immediately) so Spotify's state doesn't claim a track we are no longer playing
    if h.flags.active.swap(false, Ordering::Relaxed) {
        if let Ok(g) = h.shared.spirc.lock() {
            if let Some(s) = g.as_ref() {
                let _ = s.disconnect(false);
            }
        }
    }
    h.ring.flush();
    h.player.load(SpotifyUri::Track { id }, start_playing, position_ms);
    0
}

#[no_mangle]
pub extern "C" fn wolf_play(h: *mut WolfHandle) {
    if let Some(h) = unsafe { h.as_ref() } {
        h.player.play();
    }
}

#[no_mangle]
pub extern "C" fn wolf_pause(h: *mut WolfHandle) {
    if let Some(h) = unsafe { h.as_ref() } {
        h.player.pause();
    }
}

#[no_mangle]
pub extern "C" fn wolf_seek(h: *mut WolfHandle, position_ms: u32) {
    if let Some(h) = unsafe { h.as_ref() } {
        h.ring.flush();
        h.flags.local_seek.store(true, Ordering::Relaxed);
        h.player.seek(position_ms);
    }
}

// realtime-safe: atomics and a memcpy loop only.
#[no_mangle]
pub extern "C" fn wolf_pcm_read(h: *mut WolfHandle, out: *mut f32, frames: usize) -> usize {
    let Some(h) = (unsafe { h.as_ref() }) else { return 0 };
    if out.is_null() || frames == 0 {
        return 0;
    }
    let slice = unsafe { std::slice::from_raw_parts_mut(out, frames * 2) };
    let n = h.ring.pop(slice) / 2;
    if n < frames {
        h.ring.underruns.fetch_add(1, Ordering::Relaxed);
    }
    n
}

#[no_mangle]
pub extern "C" fn wolf_pcm_flush(h: *mut WolfHandle) {
    if let Some(h) = unsafe { h.as_ref() } {
        h.ring.flush();
    }
}

#[no_mangle]
pub extern "C" fn wolf_pcm_buffered(h: *mut WolfHandle) -> usize {
    unsafe { h.as_ref() }.map(|h| h.ring.buffered_frames()).unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn wolf_pcm_underruns(h: *mut WolfHandle) -> u64 {
    unsafe { h.as_ref() }.map(|h| h.ring.underruns.load(Ordering::Relaxed)).unwrap_or(0)
}
