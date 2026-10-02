import type { HlsConfig, Loader, LoaderCallbacks, LoaderConfiguration, LoaderContext, LoaderStats } from 'hls.js';
import type { ExtensionLink } from './link';

/** Playlists can take a while when the computer is starting FFmpeg for a stream. */
const PLAYLIST_TIMEOUT_MS = 25_000;
const SEGMENT_TIMEOUT_MS = 15_000;

function emptyStats(): LoaderStats {
  const timing = () => ({ start: 0, first: 0, end: 0 });
  return { aborted: false, loaded: 0, total: 0, retry: 0, chunkCount: 0, bwEstimate: 0, loading: timing(), parsing: { start: 0, end: 0 }, buffering: timing() };
}

/**
 * An hls.js loader that fetches through Bridgething's network bridge instead of XHR,
 * since the Car Thing can't reach the computer's local server directly.
 */
export function makeLoader(link: ExtensionLink): HlsConfig['loader'] {
  return class BridgeLoader implements Loader<LoaderContext> {
    context: LoaderContext | null = null;
    stats: LoaderStats = emptyStats();
    private aborted = false;

    constructor(_config: HlsConfig) {}

    load(context: LoaderContext, _config: LoaderConfiguration, callbacks: LoaderCallbacks<LoaderContext>): void {
      this.context = context;
      this.stats.loading.start = performance.now();
      const headers = context.rangeEnd ? [{ name: 'Range', value: `bytes=${context.rangeStart ?? 0}-${context.rangeEnd - 1}` }] : [];
      const timeoutMs = context.responseType === 'arraybuffer' ? SEGMENT_TIMEOUT_MS : PLAYLIST_TIMEOUT_MS;

      link.fetch(context.url, { headers, timeoutMs }).then(
        (response) => {
          if (this.aborted) return;
          const now = performance.now();
          this.stats.loading.first = now;
          this.stats.loading.end = now;
          this.stats.loaded = this.stats.total = response.body.byteLength;
          if (response.status < 200 || response.status >= 300) {
            callbacks.onError({ code: response.status, text: new TextDecoder().decode(response.body) }, context, null, this.stats);
            return;
          }
          const bytes = response.body;
          const data = context.responseType === 'arraybuffer'
            ? bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength)
            : new TextDecoder().decode(bytes);
          callbacks.onSuccess({ url: context.url, data: data as ArrayBuffer }, this.stats, context, null);
        },
        (error: Error) => {
          if (this.aborted) return;
          callbacks.onError({ code: 0, text: error.message }, context, null, this.stats);
        },
      );
    }

    abort(): void {
      this.aborted = true;
      this.stats.aborted = true;
    }

    destroy(): void {
      this.abort();
      this.context = null;
    }
  } as unknown as HlsConfig['loader'];
}
