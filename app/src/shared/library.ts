// The channel lineup, shared between the settings page (which edits it) and the Car Thing
// app (which plays it). Stored as JSON in Bridgething's per-app doc storage.

export type PlaybackMode = 'automatic' | 'direct' | 'convert';

/** A provider-specific pointer to a stream. `value` is opaque to everything but the provider. */
export interface SourceReference {
  provider: string;
  value: string;
}

export interface Channel {
  id: string;
  name: string;
  source: SourceReference;
  /** Defaults to `automatic`: relay directly when the Car Thing can play it, otherwise convert. */
  playback?: PlaybackMode;
}

export interface Library {
  channels: Channel[];
  /** Car Thing buttons 1–4: a channel id per slot. */
  favorites: (string | null)[];
}

export interface Prefs {
  /** CRT scanlines over the picture. */
  scanlines: boolean;
  /** Shifts the computer's audio relative to the picture; positive plays it later. */
  audioOffsetMs: number;
}

export const FAVORITE_SLOTS = 4;
export const DEFAULT_PREFS: Prefs = { scanlines: true, audioOffsetMs: 0 };

/** Bridgething doc keys. Each value is a string of at most 256 KiB. */
export const DOC = {
  library: 'library',
  prefs: 'prefs',
  /** The channel on air, written by the Car Thing app. */
  current: 'current',
} as const;

export function newID(): string {
  return crypto.randomUUID();
}

/** Repairs anything malformed: four favorite slots, no dangling references, valid channels. */
export function normalizeLibrary(raw: unknown): Library {
  const input = (raw ?? {}) as Partial<Library>;
  const seen = new Set<string>();
  const channels = (Array.isArray(input.channels) ? input.channels : []).filter((channel): channel is Channel => {
    const ok =
      !!channel && typeof channel.id === 'string' && typeof channel.name === 'string' &&
      typeof channel.source?.provider === 'string' && typeof channel.source?.value === 'string' && !seen.has(channel.id);
    if (ok) seen.add(channel.id);
    return ok;
  });
  const favorites = Array.from({ length: FAVORITE_SLOTS }, (_, slot) => {
    const id = Array.isArray(input.favorites) ? input.favorites[slot] : null;
    return typeof id === 'string' && seen.has(id) ? id : null;
  });
  return { channels, favorites };
}

export function parseLibrary(json: string | null | undefined): Library {
  try {
    return normalizeLibrary(json ? JSON.parse(json) : null);
  } catch {
    return normalizeLibrary(null);
  }
}

export function parsePrefs(json: string | null | undefined): Prefs {
  try {
    const value = json ? JSON.parse(json) : {};
    return {
      scanlines: typeof value.scanlines === 'boolean' ? value.scanlines : DEFAULT_PREFS.scanlines,
      audioOffsetMs: Number.isFinite(value.audioOffsetMs) ? Math.max(-5000, Math.min(5000, value.audioOffsetMs)) : 0,
    };
  } catch {
    return { ...DEFAULT_PREFS };
  }
}

export function favoriteSlot(library: Library, id: string): number | undefined {
  const slot = library.favorites.indexOf(id);
  return slot >= 0 ? slot : undefined;
}

/** Assigns a channel to a button. A channel holds at most one button. */
export function setFavorite(library: Library, id: string | null, slot: number): Library {
  if (slot < 0 || slot >= FAVORITE_SLOTS) return library;
  const favorites = library.favorites.map((existing) => (id && existing === id ? null : existing));
  favorites[slot] = id;
  return normalizeLibrary({ ...library, favorites });
}

export function removeChannels(library: Library, ids: Set<string>): Library {
  return normalizeLibrary({ ...library, channels: library.channels.filter((channel) => !ids.has(channel.id)) });
}

export function moveChannel(library: Library, from: number, to: number): Library {
  const channels = [...library.channels];
  const [moved] = channels.splice(from, 1);
  if (!moved) return library;
  channels.splice(Math.max(0, Math.min(to, channels.length)), 0, moved);
  return { ...library, channels };
}

export function sameSource(a: SourceReference, b: SourceReference): boolean {
  return a.provider === b.provider && a.value === b.value;
}

/**
 * Adds channels whose source isn't already in the lineup (or earlier in the list). If the
 * lineup was empty, the first four also fill buttons 1–4.
 */
export function mergeChannels(library: Library, incoming: Omit<Channel, 'id'>[]): { library: Library; added: number; skipped: number } {
  const known = [...library.channels.map((channel) => channel.source)];
  const added: Channel[] = [];
  for (const channel of incoming) {
    if (known.some((source) => sameSource(source, channel.source))) continue;
    known.push(channel.source);
    added.push({ ...channel, id: newID() });
  }
  let next = normalizeLibrary({ ...library, channels: [...library.channels, ...added] });
  if (library.channels.length === 0) {
    added.slice(0, FAVORITE_SLOTS).forEach((channel, slot) => (next = setFavorite(next, channel.id, slot)));
  }
  return { library: next, added: added.length, skipped: incoming.length - added.length };
}
