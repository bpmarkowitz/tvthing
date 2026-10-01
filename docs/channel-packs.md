# Channel packs

A channel pack is a JSON file (extension `.tvthing`) for sharing a lineup. Import one from **Settings → Channels → Import…**. Exports use the same format.

```json
{
  "format": "tvthing.channels",
  "version": 1,
  "name": "My Channels",
  "channels": [
    { "name": "Big Buck Bunny", "source": { "provider": "hls", "value": "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8" } },
    { "name": "News Stream", "url": "https://example.com/live/master.m3u8" },
    { "name": "Needs conversion", "url": "https://example.com/hevc.m3u8", "playback": "convert" }
  ]
}
```

| Field | Notes |
| --- | --- |
| `format` | Always `tvthing.channels` |
| `version` | `1`. Newer versions are rejected with a clear message |
| `name` | Optional pack name |
| `channels[].name` | Display name |
| `channels[].source` | `{provider, value}`. Built-in providers are `hls` (value: playlist URL) and `mpegts` (value: a raw MPEG transport stream URL, such as an HDHomeRun channel); [custom providers](adding-a-provider.md) define their own values |
| `channels[].url` | Shorthand for `{"provider": "hls", "value": url}` |
| `channels[].playback` | Optional: `automatic` (default), `direct`, or `convert` |

Imported channels are added to the end of the lineup, skipping any whose source is already there, so re-importing an updated pack only adds what's new. If the lineup was empty, the first four also fill buttons 1–4.

## M3U playlists

Extended M3U files (`#EXTM3U` with `#EXTINF` lines, the common IPTV format) can be imported too. Each HTTP(S) entry becomes an `hls` channel named from its `#EXTINF` title, falling back to `tvg-name` or the file name.
