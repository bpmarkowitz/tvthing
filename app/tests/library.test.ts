import { mergeChannels, moveChannel, normalizeLibrary, parsePrefs, removeChannels, setFavorite } from '../src/shared/library.ts';
import { equal, ok } from './assert.ts';

const hls = (name: string, url: string) => ({ name, source: { provider: 'hls', value: url } });

Deno.test('merging into an empty lineup fills the buttons', () => {
  const { library, added, skipped } = mergeChannels(normalizeLibrary(null), [hls('A', 'https://a'), hls('B', 'https://b'), hls('A again', 'https://a')]);
  equal(added, 2);
  equal(skipped, 1);
  equal(library.favorites, [library.channels[0].id, library.channels[1].id, null, null]);
});

Deno.test('merging into an existing lineup skips known sources and leaves buttons alone', () => {
  const first = mergeChannels(normalizeLibrary(null), [hls('A', 'https://a')]).library;
  const { library, added } = mergeChannels(first, [hls('A', 'https://a'), hls('B', 'https://b')]);
  equal(added, 1);
  equal(library.favorites, [first.channels[0].id, null, null, null]);
});

Deno.test('a channel holds at most one button', () => {
  const library = mergeChannels(normalizeLibrary(null), [hls('A', 'https://a')]).library;
  const id = library.channels[0].id;
  equal(setFavorite(library, id, 2).favorites, [null, null, id, null]);
});

Deno.test('removing a channel clears its button', () => {
  const library = mergeChannels(normalizeLibrary(null), [hls('A', 'https://a'), hls('B', 'https://b')]).library;
  const next = removeChannels(library, new Set([library.channels[0].id]));
  equal(next.channels.map((c) => c.name), ['B']);
  equal(next.favorites, [null, library.channels[1].id, null, null]);
});

Deno.test('moving a channel', () => {
  const library = mergeChannels(normalizeLibrary(null), [hls('A', 'https://a'), hls('B', 'https://b'), hls('C', 'https://c')]).library;
  equal(moveChannel(library, 0, 2).channels.map((c) => c.name), ['B', 'C', 'A']);
});

Deno.test('malformed stored data is repaired', () => {
  const library = normalizeLibrary({ channels: [{ id: 'x', name: 'X', source: { provider: 'hls', value: 'https://x' } }, { id: 'x' }, null], favorites: ['x', 'missing'] });
  equal(library.channels.length, 1);
  equal(library.favorites, ['x', null, null, null]);
});

Deno.test('preferences default and clamp', () => {
  equal(parsePrefs(null), { scanlines: true, audioOffsetMs: 0 });
  equal(parsePrefs('{"scanlines":false,"audioOffsetMs":99999}'), { scanlines: false, audioOffsetMs: 5000 });
  ok(parsePrefs('not json').scanlines);
});
