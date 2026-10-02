// The parts of an HLS playlist TV Thing needs to judge whether the Car Thing can play it.

export interface Variant {
  uri: string;
  bandwidth: number;
  height?: number;
  codecs: string[];
}

export interface Playlist {
  variants: Variant[];
  hasProgramDateTime: boolean;
  /** A finished, on-demand video rather than a live stream. */
  hasEndList: boolean;
  segmentURIs: string[];
}

export function parsePlaylist(text: string): Playlist {
  const variants: Variant[] = [];
  const segmentURIs: string[] = [];
  let pending: Record<string, string> | null = null;
  let hasProgramDateTime = false;
  let hasEndList = false;
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line) continue;
    if (line.startsWith('#EXT-X-STREAM-INF:')) pending = attributes(line.slice('#EXT-X-STREAM-INF:'.length));
    else if (line.startsWith('#EXT-X-PROGRAM-DATE-TIME')) hasProgramDateTime = true;
    else if (line.startsWith('#EXT-X-ENDLIST')) hasEndList = true;
    else if (!line.startsWith('#')) {
      if (pending) {
        const size = pending.RESOLUTION?.split('x').map(Number);
        variants.push({
          uri: line,
          bandwidth: Number(pending.BANDWIDTH) || 0,
          height: size?.length === 2 && Number.isFinite(size[1]) ? size[1] : undefined,
          codecs: (pending.CODECS ?? '').split(',').map((c) => c.trim().toLowerCase()).filter(Boolean),
        });
        pending = null;
      } else {
        segmentURIs.push(line);
      }
    }
  }
  return { variants, hasProgramDateTime, hasEndList, segmentURIs };
}

/** Parses an HLS attribute list, respecting quoted values that contain commas. */
export function attributes(list: string): Record<string, string> {
  const result: Record<string, string> = {};
  let key = '';
  let value = '';
  let readingValue = false;
  let quoted = false;
  const commit = () => {
    if (key.trim()) result[key.trim()] = value;
    key = '';
    value = '';
    readingValue = false;
  };
  for (const character of list) {
    if (character === '=' && !readingValue) readingValue = true;
    else if (character === '"' && readingValue) quoted = !quoted;
    else if (character === ',' && !quoted) commit();
    else if (readingValue) value += character;
    else key += character;
  }
  commit();
  return result;
}

export type Compatibility = { direct: true } | { direct: false; reason: string };

const MAXIMUM_DIRECT_HEIGHT = 720;
/** ~300 KB segments are proven safe over Bridgething's USB link; ~775 KB ones drop it. */
const MAXIMUM_SEGMENT_BYTES = 500_000;
const AUDIO_CODECS = ['mp4a', 'ac-3', 'ec-3', 'opus', 'flac'];

function isPlayable(variant: Variant): boolean {
  if (variant.codecs.length === 0) return true;
  const video = variant.codecs.filter((codec) => !AUDIO_CODECS.some((prefix) => codec.startsWith(prefix)));
  return video.length > 0 && video.every((codec) => codec.startsWith('avc1') || codec.startsWith('avc3'));
}

/**
 * Whether the stream can be relayed untouched: H.264 at up to 720p, program-date-time stamps
 * (the Car Thing and the host player align on them), and segments small enough for the link.
 */
export function evaluate(multivariant: Playlist | null, media: Playlist, segmentBytes?: number): Compatibility {
  if (multivariant) {
    const candidates = multivariant.variants.filter(isPlayable);
    if (candidates.length === 0) return { direct: false, reason: "Uses a video codec the Car Thing can't decode" };
    const heights = candidates.map((v) => v.height).filter((h): h is number => h !== undefined);
    if (heights.length && Math.min(...heights) > MAXIMUM_DIRECT_HEIGHT) return { direct: false, reason: `Every quality level is above ${MAXIMUM_DIRECT_HEIGHT}p` };
  }
  if (!media.hasProgramDateTime) return { direct: false, reason: 'No timestamps to sync audio with' };
  if (segmentBytes !== undefined && segmentBytes > MAXIMUM_SEGMENT_BYTES) {
    return { direct: false, reason: `Video chunks are too large for the Car Thing link (${Math.round(segmentBytes / 1000)} KB)` };
  }
  return { direct: true };
}

/** The variant the Car Thing plays: the lowest-bandwidth playable one. */
export function preferredVariant(playlist: Playlist): Variant | undefined {
  return playlist.variants.filter(isPlayable).sort((a, b) => a.bandwidth - b.bandwidth)[0];
}

/** For conversion: the best variant up to 720p (FFmpeg's program number), else the smallest. */
export function conversionVariant(playlist: Playlist): number | undefined {
  const video = playlist.variants.map((variant, index) => ({ variant, index })).filter(({ variant }) => variant.codecs.length === 0 || variant.codecs.some((c) => !c.startsWith('mp4a')));
  const fitting = video.filter(({ variant }) => (variant.height ?? 0) <= MAXIMUM_DIRECT_HEIGHT);
  const pool = fitting.length ? fitting : video;
  if (!pool.length) return undefined;
  const pick = fitting.length
    ? pool.reduce((a, b) => (b.variant.bandwidth > a.variant.bandwidth ? b : a))
    : pool.reduce((a, b) => (b.variant.bandwidth < a.variant.bandwidth ? b : a));
  return pick.index;
}
