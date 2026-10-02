import { conversionVariant, evaluate, parsePlaylist, preferredVariant } from '../extension/engine/playlist.ts';
import { Relay } from '../extension/engine/relay.ts';
import { isHostPlayer, playlistOrigin } from '../extension/engine/session.ts';
import { arguments_ } from '../extension/engine/transcoder.ts';
import { equal, ok } from './assert.ts';

const MULTIVARIANT = `#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=6000000,RESOLUTION=1920x1080,CODECS="avc1.640028,mp4a.40.2"
1080.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720,CODECS="avc1.64001f,mp4a.40.2"
720.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,CODECS="avc1.64001e,mp4a.40.2"
360.m3u8`;
const MEDIA = `#EXTM3U
#EXT-X-TARGETDURATION:6
#EXTINF:6.0,
#EXT-X-PROGRAM-DATE-TIME:2026-10-02T13:00:00.000Z
a.ts
#EXTINF:6.0,
b.ts`;

Deno.test('playlist parsing, including quoted commas', () => {
  const playlist = parsePlaylist(MULTIVARIANT);
  equal(playlist.variants.map((v) => v.height), [1080, 720, 360]);
  equal(playlist.variants[0].codecs, ['avc1.640028', 'mp4a.40.2']);
  equal(preferredVariant(playlist)?.uri, '360.m3u8');
  equal(conversionVariant(playlist), 1);
});

Deno.test('direct playback needs H.264 at 720p or less, timestamps, and small segments', () => {
  const multivariant = parsePlaylist(MULTIVARIANT);
  const media = parsePlaylist(MEDIA);
  equal(evaluate(multivariant, media, 300_000), { direct: true });
  ok(!evaluate(multivariant, media, 900_000).direct);
  ok(!evaluate(multivariant, parsePlaylist(MEDIA.replace(/#EXT-X-PROGRAM-DATE-TIME.*\n/, '')), 300_000).direct);
  const hevc = parsePlaylist(MULTIVARIANT.replaceAll('avc1', 'hvc1'));
  ok(!evaluate(hevc, media).direct);
});

Deno.test('the relay rewrites every URI to a stable local token', () => {
  const relay = new Relay('/stream/abc/s/', { entryURL: new URL('https://cdn.example/live/master.m3u8') });
  const text = '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\nseg1.ts\nhttps://other.example/seg2.ts\nseg1.ts\n';
  const lines = relay.rewrite(text, new URL('https://cdn.example/live/media.m3u8')).split('\n');
  equal(lines[1], '#EXT-X-KEY:METHOD=AES-128,URI="/stream/abc/s/1"');
  equal(lines[2], '/stream/abc/s/2.ts');
  equal(lines[3], '/stream/abc/s/3.ts');
  equal(lines[4], '/stream/abc/s/2.ts');
});

Deno.test("the host player's starting date is worked back from the first timestamp", () => {
  equal(playlistOrigin(MEDIA), Date.parse('2026-10-02T13:00:00.000Z'));
  const later = '#EXTM3U\n#EXTINF:6.0,\na.ts\n#EXTINF:6.0,\nb.ts\n#EXT-X-PROGRAM-DATE-TIME:2026-10-02T13:00:12.000Z\n#EXTINF:6.0,\nc.ts';
  equal(playlistOrigin(later), Date.parse('2026-10-02T13:00:00.000Z'));
  equal(playlistOrigin(MULTIVARIANT), null);
});

Deno.test('telling the host player apart from the Car Thing and FFmpeg', () => {
  ok(isHostPlayer('AppleCoreMedia/1.0.0.26A434 (Macintosh; U; Intel Mac OS X 27_0_1; en_us)'));
  ok(!isHostPlayer('bridgething/0.13.1'));
  ok(!isHostPlayer('Lavf/62.12.101'));
});

Deno.test('FFmpeg paces and loops finished videos, but not live streams', () => {
  const source = { url: new URL('http://127.0.0.1:17839/stream/x/source.m3u8'), onDemand: true };
  const first = arguments_(source, '/tmp/out', false);
  const loop = arguments_(source, '/tmp/out', true);
  ok(first.includes('-readrate_initial_burst'));
  ok(!loop.includes('-readrate_initial_burst'));
  ok(loop[loop.indexOf('-hls_flags') + 1].includes('append_list+discont_start'));
  ok(!arguments_({ ...source, onDemand: false }, '/tmp/out', false).includes('-readrate'));
});
