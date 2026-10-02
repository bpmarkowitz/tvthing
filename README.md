# TV Thing

**Turn a Spotify Car Thing into a tiny TV.** The Car Thing shows the picture; your computer plays the sound, kept in sync.

Tune channels with the four preset buttons, turn the big knob for volume, and press it for a channel guide. Changing channels plays analog-TV static, and CRT scanlines give the picture an old-TV look (you can turn them off). TV Thing plays any HLS live stream (`.m3u8`) or IPTV-style M3U playlist you have the right to watch.

TV Thing is a single [Bridgething](https://bridgething.com) app. Everything is set up in Bridgething; there's nothing else to install.

> TV Thing is an independent hobby project. It isn't affiliated with, endorsed by, or supported by Spotify, Bridgething, Apple, or any broadcaster or streaming service. See [Disclaimer](#disclaimer).

---

## What you need

| | |
| --- | --- |
| **Car Thing** | A Spotify Car Thing running **[Bridgething](https://bridgething.com)** |
| **Computer** | The **Bridgething desktop app**, with the Car Thing connected. TV Thing is developed and tested on a Mac |
| **Cable** | A USB cable that carries data (not charge-only), plugged straight into the computer rather than through a hub if you can |
| **FFmpeg** (optional, recommended) | Needed for streams the Car Thing can't play directly. On a Mac, install it with [Homebrew](https://brew.sh): `brew install ffmpeg` |

## Install

1. **Download** `TVThing-<version>.zip` from the [Releases page](https://github.com/bpmarkowitz/tvthing/releases).
2. **Install it in the Bridgething desktop app** as a local app. TV Thing includes a small helper (a Bridgething *extension*) that runs on your computer to relay streams, so Bridgething asks you to approve its permissions: network access, reading and writing files (for FFmpeg's temporary output), environment variables (to find FFmpeg), and running `/bin/sh` and `pkill` (to start and stop FFmpeg).
3. **Open TV Thing on the Car Thing.** The first time, it adds a set of free channels so the buttons work straight away.

**Coming from TV Thing 2 (the Mac app)?** In the Mac app, export your channels (Settings → Channels → Export), then quit it and move it to the Trash. Import the file in TV Thing's settings in Bridgething. Both use the same port, so the Mac app must not be running.

## Adding channels

Open **TV Thing's settings** in the Bridgething desktop app.

- **Add a URL:** paste an HLS stream URL (`.m3u8`) to add one channel, or an M3U playlist URL to add every channel in it.
- **Import a file:** TV Thing **channel packs** (`.tvthing`, [format](docs/channel-packs.md)) and **M3U** playlists. Channels already in your lineup are skipped.
- **Add the free channels:** free live channels that broadcasters publish themselves (Al Jazeera English, Red Bull TV, PBS Kids, Africanews, CBS News Miami, Bloomberg Originals, France 24, DW, NHK World-Japan, Arirang, and Fox Weather), plus a test stream. Some need FFmpeg. Free streams can change or go offline at any time.

Each channel can be renamed, reordered, deleted, given one of the Car Thing's buttons 1–4, or set to always play directly or always convert. Changes reach the Car Thing straight away.

## Finding streams

TV Thing doesn't come with content. It plays streams you add. Some places to look:

- **Broadcasters' own free live streams.** Many news organizations, public broadcasters, and government channels publish free live HLS streams on their websites.
- **[iptv-org](https://github.com/iptv-org/iptv)**, a community-maintained index of publicly available streams, as M3U playlists by country, language, and category.
- **Services you subscribe to** that provide M3U or HLS URLs for use in third-party players.

**You're responsible for what you watch.** Only add streams you have the right to access, and check each source's terms of use. Many services only allow viewing through their own apps or websites. TV Thing doesn't bypass ads, logins, DRM, or geographic restrictions, and streams protected by DRM won't play.

## Using it

| Control | Action |
| --- | --- |
| Buttons 1–4 | Tune to a favorite |
| Turn the knob | Volume |
| Press the knob | Open the channel guide (turn to browse, press to watch) |
| Press the knob on the channel that's already playing | **Sound timing:** turn to shift the sound earlier or later, press when done |
| Buttons 1–4 while the guide is open | Save the highlighted channel to that button |
| Front button | Mute or unmute; the picture keeps playing (backs out of the guide or sound timing) |
| Top-right button | Show what's on (five quick presses return to Bridgething's home) |
| Tap the screen | Cycle the picture: Fill, Fit (whole picture), Zoom (removes the side bars of 4:3 shows); remembered per channel |

Settings also has CRT scanlines and sound timing.

## Troubleshooting

| Problem | Try |
| --- | --- |
| "Can't reach your computer" | Make sure the Bridgething desktop app is running and the Car Thing shows as connected. TV Thing's settings show whether its helper is running. |
| Settings say the old Mac app is running | Quit TV Thing 2 (the menu bar app). It uses the same port. |
| A channel won't play | Install FFmpeg (`brew install ffmpeg`). Some streams need converting for the Car Thing. In settings, try setting the channel to **Always convert**. |
| Sound and picture slightly out of step | Press the knob twice (on the channel that's playing) and turn to shift the sound. It's remembered. |
| The Car Thing keeps disconnecting | Try another USB port or cable, and plug straight into the computer. |
| Anything else | Open `http://127.0.0.1:17839/api/v1/log` in a browser on the computer for TV Thing's recent activity, and include it when you [open an issue](https://github.com/bpmarkowitz/tvthing/issues). |

## How it works

```
 Car Thing                          Computer
┌───────────────┐  USB   ┌──────────────────────────────────────────────────┐
│ TV Thing app  │◀──────▶│ Bridgething desktop                              │
│  hls.js       │        │  ├─ TV Thing extension (127.0.0.1:17839)         │
│  picture only │        │  │    ├─ HLS relay ◀── stream source             │
│  follows the  │        │  │    └─ FFmpeg (only when needed)               │
│  sound        │        │  ├─ host player: the sound, from the same relay  │
└───────────────┘        │  └─ TV Thing settings page                       │
                         └──────────────────────────────────────────────────┘
```

The extension relays each stream (converting it with FFmpeg when the Car Thing can't play it), and both players load it from there: the Car Thing for the picture and Bridgething's host player for the sound. The sound plays straight through, and the Car Thing keeps the picture in step with it using the stream's timestamps. The extension only accepts connections from the computer itself. See [docs/architecture.md](docs/architecture.md).

## Building from source

You'll need Node.js 20 or later, and [Deno](https://deno.com) for the tests.

```sh
make           # typechecks, tests, builds, and zips the app → app/dist/TVThing.zip
make test      # tests
make release   # the download for a release, in dist/
```

| Path | Contents |
| --- | --- |
| `app/src/device/` | The Car Thing app (TypeScript, hls.js) |
| `app/src/settings/` | The settings page, built into one self-contained `settings.html` |
| `app/src/shared/` | The lineup, channel packs, starter channels, and the API between the app and the extension |
| `app/extension/` | The extension: relay, compatibility checks, FFmpeg, and stream providers |
| `app/tests/` | Tests |
| `docs/` | Architecture, channel pack format, adding stream providers |
| `examples/channel-packs/` | The starter channel pack |

**Developing without a Car Thing:**

```sh
make dev
```

This runs the extension on its own and serves the app in a browser, with stand-ins for Bridgething. Open `http://localhost:5173/?browser` (resize to 800×480) for the Car Thing app, or `http://localhost:5173/settings-dev` for settings. Keys 1–4, the scroll wheel, Enter, Escape, and M stand in for the Car Thing's controls. If Bridgething's copy of the extension is already using port 17839, set `TVTHING_PORT=17840` for both the extension and `npm run dev`.

## Disclaimer

TV Thing is provided "as is", without warranty of any kind (see [LICENSE](LICENSE)).

- **No content is included or hosted.** TV Thing is a player. It doesn't host or distribute video. The starter channels are links to free streams that broadcasters make publicly available themselves. All programming belongs to its owners, TV Thing isn't affiliated with any of them, and they may change or withdraw these streams at any time.
- **Use it lawfully.** You're responsible for ensuring you have the right to access any stream you add, and for following the terms of the services and sources you use.
- **No affiliation.** Spotify and Car Thing are trademarks of Spotify AB. Bridgething, Apple, macOS, and other names belong to their respective owners. TV Thing isn't affiliated with or endorsed by any of them.
- **Hardware:** Car Thing is discontinued hardware, and Bridgething is third-party software. Use them at your own risk.

## Credits

- **[hls.js](https://github.com/video-dev/hls.js)** (Apache 2.0) and the **[Bridgething client](https://github.com/JoeyEamigh/bridgething)** (MIT) are bundled in the app. Their licenses ship in its `licenses/` folder.
- **Test stream:** *Big Buck Bunny* is © Blender Foundation, licensed under [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/) ([peach.blender.org](https://peach.blender.org)), hosted by Mux.
- Made by [Ben Markowitz](https://bpmarkowitz.com). MIT licensed.
