# Architecture

TV Thing is two programs: a macOS menu bar app that owns everything, and a thin Car Thing webapp that only displays video. All channel data, stream handling, and policy live on the Mac, so the Car Thing app rarely needs updating.

## The Mac app

```
TVThing (app target)              TVThingKit (Swift package)
─────────────────────             ───────────────────────────────────────────────
AppModel ────────────────────────▶ TVThingEngine (actor)
  mirrors EngineSnapshot            ├─ ChannelLibrary + LibraryStore (JSON in App Support)
  preferences                       ├─ ProviderRegistry ── HLSProvider, TransportStreamProvider, …
Views (menu bar, Settings,          ├─ StreamSession (one per tune)
  welcome)                          │    ├─ HLSRelay (source)   ◀── upstream stream
SetupMonitor                        │    ├─ CompatibilityProbe
                                    │    └─ FFmpegTranscoder ─▶ HLSRelay (output)
                                    ├─ LocalHTTPServer (127.0.0.1:17839) + DeviceAPI
CompanionAudio (AVPlayer) ◀──────── └─ DiagnosticsLog
  SyncPolicy
```

- **`TVThingEngine`** is the single source of truth. The UI calls its async methods and observes its `snapshots` stream.
- **`ChannelLibrary`** is a value type that enforces the invariants: exactly four favorite slots, no dangling references, and always a current channel when the list isn't empty.
- **Providers** turn user input into a `SourceReference` (`{provider, value}`) and resolve a reference into a playable playlist, plus a request decorator for things like auth tokens. Everything else is provider-agnostic. See [adding-a-provider.md](adding-a-provider.md).
- **`StreamSession`** is created on each tune with a fresh ID, and everything it serves lives under `/stream/<id>/`. Requests left over from the previous channel get a clean 404 instead of mixing streams. Sessions are lazy: nothing is resolved or fetched until a player asks for the playlist.
- **`HLSRelay`** rewrites every URI in a playlist to a short local token and proxies the fetches. Concurrent requests for the same resource share one upstream fetch, and responses are cached briefly (playlists for 1 s, segments for 60 s).
- **`FFmpegTranscoder`** reads the source relay, never the upstream directly, so provider auth keeps working. It writes 800×480 H.264/AAC HLS with program-date-time stamps. It stops after 45 s with no viewers and restarts on demand.
- **`CompanionAudio`** plays the session's playlist with `AVPlayer`, video tracks disabled and at the lowest bitrate, and seeks it to match the Car Thing's reported position.

## The Car Thing app

`carthing/src/`:

| File | Role |
| --- | --- |
| `main.ts` | `App`: polls state, reacts to session changes, reports position, handles controls |
| `mac.ts` | `MacLink`: typed Device API client (mirrors `DeviceAPI.swift`) |
| `transport.ts` | Bridgething network bridge; a browser transport for development |
| `loader.ts` | hls.js loader that fetches through the transport |
| `player.ts` | hls.js + `<video>` with automatic recovery |
| `input.ts` | Buttons, knob, front, and top-right buttons mapped to intents; the first press of each key is reported to the Mac log |
| `ui/` | Channel bug, static, guide, status card, toasts |

## Why it's built this way

These are lessons from earlier prototypes and testing on real hardware, now written into the design:

- **Audio plays on the Mac.** The Car Thing has no useful speaker path for this, and Mac audio gets volume keys, AirPlay, and output selection for free. The Car Thing video stays muted.
- **Sync uses program-date-time, not playback position.** Two players on one live stream have unrelated `currentTime`s but share wall-clock PDT stamps, so the compatibility probe requires them, and conversion adds them.
- **Align once, then hold.** Position reports cross USB and Bridgething with a few hundred milliseconds of jitter, and chasing them sounds worse than a steady offset. `SyncPolicy` re-aligns only on a big jump in consecutive samples (ad breaks on stitched streams), on persistent drift, or when the user changes the offset.
- **Both players go through the same relay.** Ad-supported streams often stitch ads per viewing session. If the Mac and the Car Thing fetched separately, they could get different ads. The shared relay and cache give them identical playlists.
- **The Car Thing plays the lightest rendition.** Its decoder and the USB bridge are the bottlenecks, so hls.js is pinned to the lowest-bitrate level. Direct streams above 720p, in codecs other than H.264, or with segments over 500 KB are converted. Each segment crosses Bridgething's link as one message, and large ones make the link drop.
- **Let hls.js ride through hiccups; reload only when stuck.** Small gaps and data stalls at ad splices are left to hls.js, because a full reload is more disruptive than the hiccup.
- **The ad-to-show splice wedges the decoder.** After splicing back into the show, the Car Thing's decoder can stop with plenty of video buffered. Seeking or resetting the decoder then crashes the Car Thing's browser, but a full reload is safe. The player watches frames closely for 3 s after each splice; if they stop for 0.35 s, it cuts to black, reloads, and fades back in after 2 s of clean playback, like a broadcast break. A frozen picture (8 s) is the general backstop.
- **Sound follows the picture.** Sync reports carry a playback `generation`, which changes on every reload so the Mac re-aligns at once, and `visible`, which is false while the picture is hidden so the Mac stays silent and keeps following the Car Thing until it fades back in. The Mac also goes silent 1.5 s after reports stop (unplugged, crashed), and the Car Thing says goodbye when the app is closed. The Mac rebuilds `AVPlayer` if audio stops advancing (7 s).
- **Loopback only, with request hardening.** The server binds to 127.0.0.1 and rejects foreign `Host` headers (DNS rebinding) and non-JSON POSTs (cross-site form posts), so web pages can't drive it.

## Extending

- **New stream source:** add a `StreamProvider` ([guide](adding-a-provider.md)).
- **New Car Thing feature:** add a Device API route in `TVThingEngine.route`, its types in `DeviceAPI.swift` and `mac.ts`, and bump `DeviceAPI.version` if older clients would break.
- **New per-channel option:** add a field to `Channel` with a default in `init(from:)` so existing libraries and packs still decode.
