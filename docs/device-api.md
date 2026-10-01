# Device API (v1)

The Mac app serves this on `http://127.0.0.1:17839`. The Car Thing reaches it through Bridgething's `net.fetch`, which performs requests on the Mac. The Swift source of truth is `mac/TVThingKit/Sources/TVThingKit/Server/DeviceAPI.swift`; the TypeScript mirror is `carthing/src/mac.ts`.

Rules for every request:
- The `Host` header, if present, must be `127.0.0.1:17839` or `localhost:17839`.
- POST bodies must be JSON with `Content-Type: application/json`.
- Errors are `{"error": "message"}` with a 4xx/5xx status.
- Optional fields are omitted rather than set to `null`.

## `GET /api/v1/health`

```json
{ "app": "TV Thing", "version": "2.0.0", "api": 1 }
```

## `GET /api/v1/state`

```json
{
  "api": 1,
  "revision": 42,
  "session": { "id": "2179889b", "playlist": "/stream/2179889b/index.m3u8" },
  "channel": { "id": "E6AA…", "number": 1, "name": "The X-Files", "favorite": 0 },
  "channels": [ { "id": "E6AA…", "number": 1, "name": "The X-Files", "favorite": 0 } ],
  "phase": "playing",
  "message": "Only present when phase is failed",
  "display": { "scanlines": false },
  "muted": false,
  "volume": 0.8
}
```

- `revision` changes whenever anything displayable changes (names, order, favorites, phase).
- `session.id` changes only when the stream changes. That's the signal to restart playback.
- `phase` is `preparing`, `playing`, `failed`, or `empty` (no channels).
- `favorite` is the Car Thing button index (0–3).
- `display` holds picture options set on the Mac (currently `scanlines`).
- `muted` is whether the Mac's audio is muted; `volume` is its level, 0–1.

## `POST /api/v1/tune`

One of `{"channel": "<id>"}`, `{"favorite": 0}`, or `{"step": 1}` (wraps around). Returns the new state.

## `POST /api/v1/favorites`

`{"slot": 0, "channel": "<id>"}` saves a channel to a button. Leave out `channel` to use the current channel. Returns the new state.

## `POST /api/v1/sync`

Sent about every 500 ms while a session is loaded:

```json
{ "session": "2179889b", "position": 1790810618788, "playing": true, "generation": 3, "visible": true }
```

`generation` increments whenever the Car Thing (re)starts the stream, such as reloading after a stall; the Mac re-aligns its audio immediately when it changes. `visible` is false while the Car Thing hides the picture (tuning, or a recovery blackout); the Mac keeps its audio silent and aligned until it's true again, then fades it in.

`position` is the program-date-time of the frame on screen in Unix milliseconds, or `null` if the stream has none. Reports for an old session are ignored.

## `POST /api/v1/mute`

`{"muted": true}` or `{"muted": false}`; send `{}` to toggle. Mutes the Mac's audio while the Car Thing keeps playing the picture. Returns the new state, whose `muted` field reflects it.

## `POST /api/v1/volume`

`{"steps": 1}` moves the Mac's audio volume by knob detents (5% each; turning up also unmutes). `{"level": 0.5}` sets it directly. Returns the new state, whose `volume` field (0–1) reflects it.

## `POST /api/v1/log`

`{"message": "…"}` adds a line to Settings → Diagnostics on the Mac (truncated to 500 characters).

## Streams: `GET /stream/<session>/…`

- `index.m3u8` is the playlist players load. It is relayed or converted as needed.
- `s/<token>` and `o/<token>` are rewritten media references. Treat them as opaque.
- `source.m3u8` is the relayed source, which FFmpeg reads when converting.
