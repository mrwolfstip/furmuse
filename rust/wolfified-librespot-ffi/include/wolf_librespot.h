// C api between wolfified (swift) and librespot 0.8.0 (rust). see rust/README.md.
// all pcm is interleaved stereo float32 at 44100 Hz and lives only in memory.
#ifndef WOLF_LIBRESPOT_H
#define WOLF_LIBRESPOT_H
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

typedef struct WolfHandle WolfHandle;

// event kinds: 1 loading, 2 playing(a=position ms), 3 paused(a=position ms), 4 end of track, 5 track unavailable,
//              6 seeked(a=position ms), 7 stopped, 8 sink status (text), 9 session disconnected (text), 0 error (text, a = error code),
//              10 librespot log line (a = 1 error / 2 warn / 3 info, text),
//              11 volume set by a Spotify client (a = 0..65535), 12 track changed (text = json: id, uri, title, artist, album,
//              cover, duration_ms), 13 connect activity (a = 1 this device is now the active Connect device, 0 it no longer is),
//              14 controlling client changed (text = client name)
// event 6 (seeked): b = 1 when the seek came from a Spotify client (the ring was already flushed on the rust side)
// the callback runs on a rust thread; `text` is only valid during the call.
typedef void (*WolfEventCb)(void *ctx, int32_t kind, int64_t a, int64_t b, const char *text);

// blocking login + player creation. returns NULL on failure and writes a code to *err.
// the access token is used for the login only and is never logged or stored.
// *err: -1 no token, -2 runtime, -3 spotify rejected the credential, -4 network/unavailable,
//       -5 other, -6 every access point answered "try another access point"
// client_id must be the spotify client id the access token was issued for (NULL = librespot default).
// Spotify Connect: wolf_start registers this device with Spotify (device_name is what the device picker shows,
// device_id must be stable per install, device_type 1 computer / 2 tablet / 3 smartphone / 4 speaker, initial_volume 0..65535).
// the login happens inside Spirc::new, so the session is connected exactly once.
WolfHandle *wolf_start(const char *access_token, const char *client_id, const char *device_name, const char *device_id,
                       int32_t device_type, uint16_t initial_volume, WolfEventCb cb, void *ctx, int32_t *err);
void wolf_stop(WolfHandle *h);

// track_id is the 22 character base62 spotify id. returns 0 on success.
int32_t wolf_load(WolfHandle *h, const char *track_id, bool start_playing, uint32_t position_ms);
void wolf_play(WolfHandle *h);
void wolf_pause(WolfHandle *h);
void wolf_seek(WolfHandle *h, uint32_t position_ms);

// commands that go through Spotify Connect while a Spotify client controls this device:
// cmd 1 play, 2 pause, 3 next, 4 previous, 5 seek (arg = ms), 6 volume (arg = 0..65535), 7 disconnect (arg != 0 pauses).
// returns 0 ok, -1 no handle, -2 no connect session, -3 unknown command, -4 refused.
int32_t wolf_connect_cmd(WolfHandle *h, int32_t cmd, int64_t arg);
bool wolf_connect_active(WolfHandle *h);
int32_t wolf_connect_load(WolfHandle *h, const char *track_id, uint32_t position_ms);

// realtime-safe (atomics only, no locks, no allocation). returns frames copied; never blocks.
size_t wolf_pcm_read(WolfHandle *h, float *out, size_t frames);
void wolf_pcm_flush(WolfHandle *h);
size_t wolf_pcm_buffered(WolfHandle *h);
uint64_t wolf_pcm_underruns(WolfHandle *h);

#endif
