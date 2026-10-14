import Foundation

// the page that runs spotify's Web Playback SDK. the SDK is a javascript library (https://sdk.scdn.co/spotify-player.js),
// not a native library, so it has to run inside a web view. this page is loaded into a WKWebView by WebPlaybackSession
// with loadHTMLString (nothing is hosted by furmuse; only the SDK script itself is fetched from spotify).
//
// swift -> page:  window.wolf.init(name, volume) | token(id, token) | tokenfail(id, why) | cmd(name, arg) | dispose()
// page -> swift:  webkit.messageHandlers.wolf.postMessage({type: ...}) with
//   sdk_loaded, ready {device_id}, not_ready {device_id}, state {state|null}, error {kind, message},
//   autoplay_failed, token_request {id}, activated, cmdresult {name, ok, err}, volume {requested, actual}, connectresult {ok}
//
// the page never sees a client id or secret; it only receives short-lived access tokens when the SDK asks for one.
enum WebPlayerPage {
    static let origin = "https://furmuse.invalid/"

    static let html = #"""
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<link rel="preconnect" href="https://sdk.scdn.co" crossorigin>
<link rel="dns-prefetch" href="https://sdk.scdn.co">
<style>
html, body { margin: 0; height: 100%; background: #101010; color: #fff; font: 15px -apple-system, sans-serif; }
#bar { display: none; height: 100%; align-items: center; justify-content: center; }
#act { font: 600 15px -apple-system, sans-serif; color: #000; background: #fff; border: 0; border-radius: 10px; padding: 12px 18px; }
</style>
</head>
<body>
<div id="bar"><button id="act">tap to enable spotify audio</button></div>
<script>
(function () {
  "use strict";
  var player = null, cfg = null, pending = {}, seq = 0, poll = null, isready = false, lastnull = false;

  function post(o) { try { window.webkit.messageHandlers.wolf.postMessage(o); } catch (e) {} }
  function msg(e) { return String((e && e.message) || e || ""); }
  function bar(show) { document.getElementById("bar").style.display = show ? "flex" : "none"; }

  function slimtrack(x) {
    if (!x) return null;
    var imgs = (x.album && x.album.images) || [], best = "", w = -1;
    for (var i = 0; i < imgs.length; i++) {
      var iw = imgs[i].width || 0;
      if (iw > w || !best) { best = imgs[i].url || ""; w = iw; }
    }
    var names = [];
    for (var j = 0; j < (x.artists || []).length; j++) names.push(x.artists[j].name);
    return {
      uri: x.uri || "", id: x.id || "", type: x.type || "", name: x.name || "",
      artists: names.join(", "), artistlist: names, album: (x.album && x.album.name) || "", cover: best,
      duration_ms: x.duration_ms | 0
    };
  }

  function slim(s) {
    if (!s) return null;
    var tw = s.track_window || {}, prev = [];
    for (var i = 0; i < (tw.previous_tracks || []).length; i++) prev.push(tw.previous_tracks[i].uri || "");
    return {
      paused: !!s.paused, position: s.position | 0, duration: s.duration | 0, loading: !!s.loading,
      shuffle: !!s.shuffle, repeat: s.repeat_mode | 0, context: (s.context && s.context.uri) || "",
      track: slimtrack(tw.current_track), prev: prev, nextn: (tw.next_tracks || []).length,
      disallows: s.disallows || {}
    };
  }

  function startpoll() {
    if (poll) clearInterval(poll);
    poll = setInterval(function () {
      if (!player || !isready) return;
      player.getCurrentState().then(function (s) {
        if (s) { lastnull = false; post({ type: "state", state: slim(s), poll: true }); }
        else if (!lastnull) { lastnull = true; post({ type: "state", state: null, poll: true }); }
      }, function () {});
    }, 1000);
  }

  function fail(kind, e) { post({ type: "error", kind: kind, message: msg(e) }); }

  function create() {
    if (player || !cfg) return;
    post({ type: "sdk_loaded" });
    player = new window.Spotify.Player({
      name: cfg.name,
      volume: cfg.volume,
      enableMediaSession: false,
      getOAuthToken: function (cb) {
        var id = String(++seq);
        pending[id] = cb;
        post({ type: "token_request", id: id });
      }
    });
    player.addListener("ready", function (o) { isready = true; lastnull = false; post({ type: "ready", device_id: o.device_id }); startpoll(); });
    player.addListener("not_ready", function (o) { isready = false; post({ type: "not_ready", device_id: o.device_id }); });
    player.addListener("player_state_changed", function (s) { post({ type: "state", state: slim(s) }); });
    player.addListener("initialization_error", function (e) { fail("initialization_error", e); });
    player.addListener("authentication_error", function (e) { fail("authentication_error", e); });
    player.addListener("account_error", function (e) { fail("account_error", e); });
    player.addListener("playback_error", function (e) { fail("playback_error", e); });
    player.addListener("autoplay_failed", function () { bar(true); post({ type: "autoplay_failed" }); });
    var r = player.connect();
    Promise.resolve(r).then(function (ok) { post({ type: "connectresult", ok: !!ok }); }, function (e) { post({ type: "connectresult", ok: false, err: msg(e) }); });
  }

  document.getElementById("act").addEventListener("click", function () {
    // a real tap inside the page: this is the user gesture the SDK needs for activateElement()
    var p = player ? player.activateElement() : Promise.resolve();
    Promise.resolve(p).then(function () { bar(false); post({ type: "activated" }); }, function (e) { fail("activation_error", e); });
  });

  window.onSpotifyWebPlaybackSDKReady = create;

  window.wolf = {
    init: function (name, volume) {
      cfg = { name: String(name), volume: Math.max(0, Math.min(1, +volume)) };
      if (window.Spotify) { create(); return; }
      var s = document.createElement("script");
      s.src = "https://sdk.scdn.co/spotify-player.js";
      s.async = true;
      s.onerror = function () { fail("sdk_load_failed", "could not load the spotify web playback sdk (network or blocked)"); };
      document.head.appendChild(s);
    },
    token: function (id, tok) {
      var cb = pending[id]; delete pending[id];
      if (cb) cb(tok);
    },
    tokenfail: function (id, why) {
      var cb = pending[id]; delete pending[id];
      post({ type: "error", kind: "token_unavailable", message: String(why || "") });
      if (cb) cb("");
    },
    cmd: function (name, arg) {
      if (!player) { post({ type: "cmdresult", name: name, ok: false, err: "player not created" }); return; }
      var p;
      try {
        switch (name) {
          case "pause": p = player.pause(); break;
          case "resume": p = player.resume(); break;
          case "toggle": p = player.togglePlay(); break;
          case "seek": p = player.seek(arg | 0); break;
          case "next": p = player.nextTrack(); break;
          case "prev": p = player.previousTrack(); break;
          case "activate": p = player.activateElement(); break;
          case "volume":
            p = Promise.resolve(player.setVolume(+arg)).then(function () { return player.getVolume(); })
              .then(function (v) { post({ type: "volume", requested: +arg, actual: v }); });
            break;
          case "connect":
            p = Promise.resolve(player.connect()).then(function (ok) { post({ type: "connectresult", ok: !!ok }); });
            break;
          case "disconnect": player.disconnect(); isready = false; p = Promise.resolve(); break;
          case "getstate":
            p = Promise.resolve(player.getCurrentState()).then(function (s) { post({ type: "state", state: slim(s) }); });
            break;
          default: p = Promise.reject(new Error("unknown command " + name));
        }
      } catch (e) { p = Promise.reject(e); }
      Promise.resolve(p).then(function () { post({ type: "cmdresult", name: name, ok: true }); },
                              function (e) { post({ type: "cmdresult", name: name, ok: false, err: msg(e) }); });
    },
    dispose: function () {
      if (poll) { clearInterval(poll); poll = null; }
      try { if (player) player.disconnect(); } catch (e) {}
      player = null; isready = false; pending = {};
    }
  };
})();
</script>
</body>
</html>
"""#
}
