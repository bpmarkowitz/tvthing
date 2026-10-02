# Architecture

TV Thing is one Bridgething app with three parts, all built from `app/`:

| Part | Runs on | Source | Role |
| --- | --- | --- | --- |
| Car Thing app | Car Thing | `app/src/device/` | Plays the picture, keeps it in step with the sound, handles the controls |
| Settings page | Bridgething desktop | `app/src/settings/` | Edits the lineup and preferences |
| Extension | Computer (Deno, started by Bridgething) | `app/extension/` | Relays streams on `127.0.0.1:17839`, converting them with FFmpeg when needed |

The lineup and preferences live in Bridgething's doc storage for the app (`library`, `prefs`, and `current` docs; see `app/src/shared/library.ts`). The settings page and the Car Thing app both read and write them, and Bridgething delivers changes to the other side live. The extension keeps no channel data. It's told what to play on each tune.

## Playing a channel

1. The Car Thing app posts the channel's source to the extension (`POST /api/v1/sessions`) and gets back a fresh session with a playlist path under `/stream/<id>/`.
2. The Car Thing plays that playlist with hls.js, fetching through Bridgething's `net.fetch` (the Car Thing can't reach the computer's network directly). It's muted and pinned to the lightest rendition.
3. When the picture starts, the app asks Bridgething's **host player** to play the same playlist on the computer. That's the sound.
4. The picture is kept in step with the sound (see [Sync](#sync)).

## The extension

`app/extension/engine/`:

| File | Role |
| --- | --- |
| `server.ts` | The local server: sessions, stream routes, health, and a recent-activity log (`GET /api/v1/log`) |
| `session.ts` | One tune of one channel: resolves the source, probes compatibility, chooses direct or converted delivery, and notes where the host player starts |
| `providers.ts` | Stream providers, which turn a channel's source reference into a playable playlist ([adding one](adding-a-provider.md)) |
| `relay.ts` | Rewrites every URI in a playlist to a short local token and proxies the fetches. Concurrent requests share one upstream fetch, and responses are cached briefly (playlists 1 s, segments 60 s) |
| `playlist.ts` | Playlist parsing, and whether the Car Thing can play a stream as-is |
| `transcoder.ts` | FFmpeg: 800×480 H.264/AAC HLS with program-date-time stamps, 2 s segments |

- **Sessions are per tune.** Each tune gets a fresh ID, so requests left over from the previous channel get a clean 404 instead of mixing streams. Nothing is resolved or fetched until a player asks for the playlist.
- **Direct or converted.** A stream is relayed untouched if it's H.264 at 720p or less, has program-date-time stamps, and has segments under 500 KB. Otherwise FFmpeg converts it, if it's installed. Channels can be set to always do one or the other.
- **FFmpeg reads the source relay**, never the upstream directly, so provider auth keeps working. On-demand videos are paced to real time and looped by restarting FFmpeg, appending to the same playlist. FFmpeg runs under a small shell watchdog that stops it within a second if the extension goes away, and it's paused after 45 s with no viewers.
- **Loopback only, with request hardening.** The server binds to 127.0.0.1 and rejects foreign `Host` headers (DNS rebinding) and non-JSON POSTs (cross-site form posts), so web pages can't drive it.

## Sync

Bridgething's host player can't be moved once it's playing a live stream; seeks are ignored. So the sound plays straight through, untouched, and the **picture follows the sound**.

- **Comparing positions.** The two players count position from different places (each from the first segment it happened to load, and live playlists roll forward every few seconds), so raw positions can't be compared. Instead they're compared on the stream's own clock, its program-date-time stamps. hls.js gives the picture's directly. For the sound, the extension notes the stamp of the first segment in the first playlist it serves the host player (the client that isn't the Car Thing or FFmpeg), and the host player's position counts from there.
- **Moving the picture.** The picture plays about four segments behind the live edge, so there's buffered video on both sides of it. When the two drift apart, the picture jumps forward or steps back within that buffer.
- **When to move.** When a channel starts, the tuning static stays up until the picture is in step (6 s at most), so it appears already aligned. After that, only gaps over 300 ms are corrected (position reports carry a couple hundred milliseconds of jitter), at most every 20 s, or every 4 s for gaps over a second (after the picture rebuffers, say). Finer adjustments are left to the viewer's sound timing control, which shifts the target.

## The Car Thing app

`app/src/device/`:

| File | Role |
| --- | --- |
| `main.ts` | `App`: tuning, the knob's modes (volume, guide, sound timing), buttons, and the picture reveal |
| `store.ts` | The lineup and preferences from Bridgething's doc storage, with live updates |
| `sound.ts` | The host player, and keeping the picture in step with it |
| `player.ts` | hls.js + `<video>` with automatic recovery, and picture shifts for sync |
| `link.ts`, `transport.ts`, `loader.ts` | Requests to the extension through Bridgething's network bridge (a browser stand-in for development) |
| `input.ts` | Buttons and knob mapped to intents |
| `ui/` | Channel bug, static, guide, sound timing, volume, status card, toasts, framing |

## Why it's built this way

These are lessons from earlier prototypes and testing on real hardware:

- **Both players go through the same relay.** Ad-supported streams often stitch ads per viewing session. If the computer and the Car Thing fetched separately, they could get different ads. The shared relay and cache give them identical playlists.
- **The Car Thing plays the lightest rendition.** Its decoder and the USB bridge are the bottlenecks. Each segment crosses Bridgething's link as one message, and large ones make the link drop.
- **Let hls.js ride through hiccups; reload only when stuck.** Small gaps and data stalls at ad splices are left to hls.js, because a full reload is more disruptive than the hiccup.
- **The ad-to-show splice wedges the decoder.** After splicing back into the show, the Car Thing's decoder can stop with plenty of video buffered. Seeking then crashes the Car Thing's browser, but a full reload is safe. The player watches frames closely for 3 s after each splice; if they stop for 0.35 s, it cuts to black, reloads, and fades back in, like a broadcast break. The sound keeps playing, and the picture rejoins it. A frozen picture (8 s) is the general backstop. (Small sync shifts happen only while the picture is playing normally.)
- **Volume is the computer's.** The knob sets Bridgething's output volume, keeping its own level so the computer's rounding doesn't get it stuck.

## Extending

- **New stream source:** add a provider ([guide](adding-a-provider.md)).
- **New setting:** add it to `Prefs` in `app/src/shared/library.ts` (with a default in `parsePrefs`), the settings page, and wherever the Car Thing app uses it.
- **New per-channel option:** add an optional field to `Channel`, carry it through `decodePack`/`encodePack`, and add it to the settings page's editor.
- **New extension route:** add it in `server.ts` and its types in `app/src/shared/api.ts`. Bump `API_VERSION` if an older Car Thing app would break.
