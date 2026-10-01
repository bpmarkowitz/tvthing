# TV Thing

**Turn a Spotify Car Thing into a tiny TV.** The Car Thing shows the picture; your Mac plays the sound, kept in sync.

Tune channels with the four preset buttons, turn the big knob for volume, and press it for a channel guide. Changing channels plays analog-TV static, and there are optional CRT scanlines. TV Thing plays any HLS live stream (`.m3u8`) or IPTV-style M3U playlist you have the right to watch.

> TV Thing is an independent hobby project. It isn't affiliated with, endorsed by, or supported by Spotify, Bridgething, Apple, or any broadcaster or streaming service. See [Disclaimer](#disclaimer).

---

## What you need

| | |
| --- | --- |
| **Mac** | An Apple silicon Mac (M1 or later) running **macOS 14 Sonoma or later** |
| **Car Thing** | A Spotify Car Thing running **[Bridgething](https://bridgething.com)**, with the Bridgething desktop app installed on your Mac |
| **Cable** | A USB cable that carries data (not charge-only), plugged straight into the Mac rather than through a hub if you can |
| **FFmpeg** (optional, recommended) | Needed for streams the Car Thing can't play directly. Install it with [Homebrew](https://brew.sh): `brew install ffmpeg` |

## Install

1. **Download** the latest `TV-Thing-mac.zip` and `TVThing-CarThing.zip` from the [Releases page](https://github.com/bpmarkowitz/tvthing/releases).
2. **Unzip** `TV-Thing-mac.zip` and drag **TV Thing** into your **Applications** folder.
3. **Open TV Thing.** It's signed and notarized by Apple, so it opens like any other app. The first time, macOS asks you to confirm opening an app downloaded from the internet.
4. **Find TV Thing in the menu bar** (a TV icon). A welcome window walks you through setup.
5. **Install the Car Thing app:** with the Car Thing connected, install `TVThing-CarThing.zip` as a local app in the Bridgething desktop app. TV Thing's **Settings → Car Thing → Show Car Thing App** also reveals a copy.
6. **Open TV Thing on the Car Thing.**

## Adding channels

- **Starter channels:** click **Add Starter Channels** in the welcome window or Settings → Channels. These are free live channels that broadcasters publish themselves (Al Jazeera English, Red Bull TV, PBS Kids, Africanews, CBS News Miami, Bloomberg Originals, France 24, DW, NHK World-Japan, Arirang, and Fox Weather), plus a test stream. The first six play directly; the rest need FFmpeg. Free streams can change or go offline at any time.
- **Paste a stream URL:** Settings → Channels → **+**, paste an HLS playlist URL (`.m3u8`), and press Return.
- **Import a playlist:** Settings → Channels → **Import…** accepts IPTV-style **M3U** playlists and TV Thing **channel packs** (`.tvthing`, [format](docs/channel-packs.md)). Channels already in your lineup are skipped.

Right-click a channel to assign it to Car Thing button 1–4. Drag to reorder.

## Finding streams

TV Thing doesn't come with content. It plays streams you add. Some places to look:

- **Broadcasters' own free live streams.** Many news organizations, public broadcasters, and government channels publish free live HLS streams on their websites.
- **[iptv-org](https://github.com/iptv-org/iptv)**, a community-maintained index of publicly available streams, as M3U playlists by country, language, and category.
- **Services you subscribe to** that provide M3U or HLS URLs for use in third-party players.

**You're responsible for what you watch.** Only add streams you have the right to access, and check each source's terms of use. Many services only allow viewing through their own apps or websites. TV Thing doesn't bypass ads, logins, DRM, or geographic restrictions, and streams protected by DRM won't play.

## Using it

**On the Car Thing**

| Control | Action |
| --- | --- |
| Buttons 1–4 | Tune to a favorite |
| Turn the knob | Volume (moves through the guide when it's open) |
| Press the knob | Open the channel guide / watch the highlighted channel |
| Buttons 1–4 while the guide is open | Save the highlighted channel to that button |
| Front button | Mute or unmute; the picture keeps playing (closes the guide when it's open) |
| Top-right button | Show what's on (five quick presses return to Bridgething's home) |

**On the Mac:** the menu bar window shows what's on, favorites, the full lineup, volume, mute, and an audio delay control for fine-tuning lip sync. **Settings** has channel management, playback options (including CRT scanlines), a setup checklist, and a diagnostics log that includes messages from the Car Thing.

## Troubleshooting

| Problem | Try |
| --- | --- |
| Car Thing says "Can't reach your Mac" | Make sure TV Thing (menu bar) and the Bridgething desktop app are both running, and the Car Thing shows as connected in Bridgething. |
| "Port 17839 is in use" | Another copy of TV Thing (or another app) is using its port. Quit it and relaunch TV Thing. |
| A channel won't play, or plays without sound sync | Install FFmpeg (`brew install ffmpeg`). Some streams need converting for the Car Thing. |
| Sound and picture slightly out of step | Adjust **Delay** in the menu bar window (or Settings → Playback). Positive values delay the sound. |
| The Car Thing keeps disconnecting | Try another USB port or cable, and plug straight into the Mac. |
| Anything else | Settings → Diagnostics → **Copy Log**, and include it when you [open an issue](https://github.com/bpmarkowitz/tvthing/issues). |

## How it works

```
 Car Thing                         Mac
┌──────────────┐  USB   ┌──────────────────────────────────────────────┐
│ TV Thing     │◀──────▶│ Bridgething ──▶ TV Thing (127.0.0.1:17839)    │
│ webapp       │        │                 ├─ Device API (state, tune…)  │
│  hls.js      │        │                 ├─ HLS relay ◀── stream source│
│  video only  │        │                 ├─ FFmpeg (only when needed)  │
└──────────────┘        │                 └─ AVPlayer: audio, synced    │
                        └──────────────────────────────────────────────┘
```

The Car Thing plays video through a relay on the Mac and reports which frame is on screen. The Mac plays the same stream's audio and keeps it aligned using the stream's timestamps. Everything stays on your Mac; the local server only accepts connections from the Mac itself. See [docs/architecture.md](docs/architecture.md).

## Building from source

You'll need Xcode 16 or later and Node.js 20 or later.

```sh
make carthing      # builds and zips the Car Thing app
make app           # builds the Mac app (Release), with the Car Thing app embedded
make test          # engine unit tests
make integration   # live end-to-end tests (needs network; FFmpeg for the conversion test)
make release       # both downloads, zipped in dist/
```

Builds are signed to run locally. To sign with your Apple developer team, create an untracked `Local.mk` containing `TEAM = <your team ID>`. Or open `mac/TVThing.xcodeproj` in Xcode, choose your team under **Signing & Capabilities**, and run the **TVThing** scheme. Build the Car Thing app first so it gets embedded.

| Path | Contents |
| --- | --- |
| `mac/TVThing/` | The macOS menu bar app (SwiftUI) |
| `mac/TVThingKit/` | The engine: library, providers, relay, FFmpeg, server, audio sync, plus tests and the `tvthing-server` dev tool |
| `carthing/` | The Car Thing webapp (TypeScript, hls.js, esbuild) |
| `docs/` | Architecture, device API, channel pack format, adding stream providers |
| `examples/channel-packs/` | The starter channel pack |

**Developing the Car Thing app without a Car Thing:**

```sh
make server PACK=examples/channel-packs/starter-channels.tvthing   # headless engine on :17839
cd carthing && npm run dev                                           # http://localhost:5173/?browser
```

Resize the browser to 800×480. Keys 1–4, the scroll wheel (volume), Enter (guide), Escape (mute), and M (info) stand in for the Car Thing's controls.

## Disclaimer

TV Thing is provided "as is", without warranty of any kind (see [LICENSE](LICENSE)).

- **No content is included or hosted.** TV Thing is a player. It doesn't host or distribute video. The starter channels are links to free streams that broadcasters make publicly available themselves. All programming belongs to its owners, TV Thing isn't affiliated with any of them, and they may change or withdraw these streams at any time.
- **Use it lawfully.** You're responsible for ensuring you have the right to access any stream you add, and for following the terms of the services and sources you use.
- **No affiliation.** Spotify and Car Thing are trademarks of Spotify AB. Bridgething, Apple, macOS, and other names belong to their respective owners. TV Thing isn't affiliated with or endorsed by any of them.
- **Hardware:** Car Thing is discontinued hardware, and Bridgething is third-party software. Use them at your own risk.

## Credits

- **[hls.js](https://github.com/video-dev/hls.js)** (Apache 2.0) and the **[Bridgething client](https://github.com/JoeyEamigh/bridgething)** (MIT) are bundled in the Car Thing app. Their licenses ship in the app's `licenses/` folder.
- **Test stream:** *Big Buck Bunny* is © Blender Foundation, licensed under [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/) ([peach.blender.org](https://peach.blender.org)), hosted by Mux.
- Made by [Ben Markowitz](https://bpmarkowitz.com). MIT licensed.
