// Channel packs (`.tvthing` JSON) and extended M3U playlists. See docs/channel-packs.md.

import type { Channel, PlaybackMode, SourceReference } from './library';

export const PACK_FORMAT = 'tvthing.channels';
export const PACK_VERSION = 1;

type NewChannel = Omit<Channel, 'id'>;

export class PackError extends Error {}

/** Reads a TV Thing channel pack or, failing that, an M3U playlist. */
export function decodePack(text: string): { name?: string; channels: NewChannel[] } {
  const trimmed = text.replace(/^﻿/, '').trim();
  if (trimmed.startsWith('#EXTM3U')) return { channels: parseM3U(trimmed) };
  let pack: { format?: string; version?: number; name?: string; channels?: unknown[] };
  try {
    pack = JSON.parse(trimmed);
  } catch {
    throw new PackError("This file isn't a TV Thing channel pack or M3U playlist.");
  }
  if (pack.format !== PACK_FORMAT) throw new PackError("This file isn't a TV Thing channel pack or M3U playlist.");
  if ((pack.version ?? 0) > PACK_VERSION) throw new PackError(`This channel pack uses format version ${pack.version}, which needs a newer TV Thing.`);
  const channels = (pack.channels ?? []).flatMap((entry): NewChannel[] => {
    const raw = entry as { name?: string; source?: SourceReference; url?: string; playback?: PlaybackMode };
    if (typeof raw?.name !== 'string') return [];
    const source = raw.source ?? (typeof raw.url === 'string' ? { provider: 'hls', value: raw.url } : null);
    if (!source || typeof source.provider !== 'string' || typeof source.value !== 'string') return [];
    return [{ name: raw.name, source, ...(raw.playback && raw.playback !== 'automatic' ? { playback: raw.playback } : {}) }];
  });
  if (channels.length === 0) throw new PackError('No channels were found in this file.');
  return { name: pack.name, channels };
}

export function encodePack(channels: Channel[], name?: string): string {
  return JSON.stringify(
    {
      format: PACK_FORMAT,
      version: PACK_VERSION,
      ...(name ? { name } : {}),
      channels: channels.map(({ name, source, playback }) => ({ name, source, ...(playback && playback !== 'automatic' ? { playback } : {}) })),
    },
    null,
    2,
  );
}

/** `#EXTINF:-1 tvg-name="Foo",Display Name` + URL lines → channels. */
export function parseM3U(text: string): NewChannel[] {
  const channels: NewChannel[] = [];
  let pendingName: string | null = null;
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (line.startsWith('#EXTINF')) {
      pendingName = nameFromInfo(line);
    } else if (line && !line.startsWith('#')) {
      if (/^https?:\/\//i.test(line)) {
        const fallback = line.split(/[?#]/)[0].split('/').filter(Boolean).pop()?.replace(/\.[^.]+$/, '') ?? 'Channel';
        channels.push({ name: pendingName || fallback, source: { provider: 'hls', value: line } });
      }
      pendingName = null;
    }
  }
  if (channels.length === 0) throw new PackError('No channels were found in this file.');
  return channels;
}

function nameFromInfo(line: string): string {
  let quoted = false;
  let comma = -1;
  for (let index = 0; index < line.length; index += 1) {
    if (line[index] === '"') quoted = !quoted;
    else if (line[index] === ',' && !quoted) comma = index;
  }
  const title = comma >= 0 ? line.slice(comma + 1).trim() : '';
  if (title) return title;
  return line.match(/tvg-name="([^"]*)"/)?.[1] ?? '';
}
