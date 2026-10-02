import { decodePack, encodePack } from '../src/shared/pack.ts';
import { equal, throws } from './assert.ts';

Deno.test('channel packs: full sources, url shorthand, and playback modes', () => {
  const pack = decodePack(JSON.stringify({
    format: 'tvthing.channels',
    version: 1,
    name: 'Mine',
    channels: [
      { name: 'A', source: { provider: 'hls', value: 'https://a' } },
      { name: 'B', url: 'https://b', playback: 'convert' },
      { name: 'Broken' },
    ],
  }));
  equal(pack.name, 'Mine');
  equal(pack.channels, [
    { name: 'A', source: { provider: 'hls', value: 'https://a' } },
    { name: 'B', source: { provider: 'hls', value: 'https://b' }, playback: 'convert' },
  ]);
});

Deno.test('channel packs round-trip', () => {
  const channels = [{ id: '1', name: 'A', source: { provider: 'hls', value: 'https://a' }, playback: 'direct' as const }];
  equal(decodePack(encodePack(channels, 'X')).channels, [{ name: 'A', source: { provider: 'hls', value: 'https://a' }, playback: 'direct' }]);
});

Deno.test('M3U playlists', () => {
  const text = '#EXTM3U\n#EXTINF:-1 tvg-name="Tvg Name",Display Name\nhttps://a/live.m3u8\n#EXTINF:-1 tvg-name="Only Tvg",\nhttps://b/x.m3u8\nhttps://c/path/stream.m3u8\n';
  equal(decodePack(text).channels.map((c) => c.name), ['Display Name', 'Only Tvg', 'stream']);
});

Deno.test('rejects other files and newer versions', () => {
  throws(() => decodePack('{"hello":1}'), /isn't a TV Thing channel pack/);
  throws(() => decodePack('{"format":"tvthing.channels","version":9,"channels":[]}'), /newer TV Thing/);
});
