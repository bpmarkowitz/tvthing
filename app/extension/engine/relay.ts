// Proxies an HLS stream through the extension's local server.
//
// Every URI in a playlist is rewritten to a short local token, so the Car Thing, the host
// player, and FFmpeg all fetch through here. Concurrent requests for the same resource share
// one upstream fetch, and recent responses are cached briefly.

export interface Upstream {
  entryURL: URL;
  /** Applied to every upstream request (e.g. to add an auth token). */
  prepare?: (url: URL) => URL;
}

export interface RelayResponse {
  status: number;
  headers: Record<string, string>;
  body: Uint8Array;
}

export class RelayError extends Error {
  constructor(readonly status: number, message: string) {
    super(message);
  }
}

const PLAYLIST_LIFETIME_MS = 1_000;
const SEGMENT_LIFETIME_MS = 60_000;
const CACHE_BYTE_LIMIT = 48 * 1024 * 1024;
const TOKEN_LIMIT = 4_000;
const KNOWN_EXTENSIONS = ['m3u8', 'ts', 'aac', 'm4s', 'mp4', 'key', 'vtt'];

export function isPlaylist(body: Uint8Array): boolean {
  const start = body[0] === 0xef && body[1] === 0xbb && body[2] === 0xbf ? 3 : 0;
  return new TextDecoder().decode(body.subarray(start, start + 7)) === '#EXTM3U';
}

export class Relay {
  private urlsByToken = new Map<string, URL>();
  private tokensByURL = new Map<string, string>();
  private nextToken = 0;
  private cache = new Map<string, { response: RelayResponse; expires: number }>();
  private inFlight = new Map<string, Promise<RelayResponse>>();

  constructor(
    /** Root-relative prefix for media URIs, e.g. `/stream/ab12cd/s/`. */
    private readonly mediaPrefix: string,
    private upstream: Upstream,
    private readonly onUnauthorized: () => Promise<Upstream | null> = async () => null,
  ) {}

  entry(range?: string): Promise<RelayResponse> {
    return this.fetch(this.upstream.entryURL, range);
  }

  media(token: string, range?: string): Promise<RelayResponse> {
    const url = this.urlsByToken.get(token);
    if (!url) throw new RelayError(404, 'Expired media reference');
    return this.fetch(url, range);
  }

  private fetch(url: URL, range?: string): Promise<RelayResponse> {
    const key = `${url.href}|${range ?? ''}`;
    const cached = this.cache.get(key);
    if (cached && cached.expires > Date.now()) return Promise.resolve(cached.response);
    const pending = this.inFlight.get(key);
    if (pending) return pending;
    const task = this.load(url, range, key).finally(() => this.inFlight.delete(key));
    this.inFlight.set(key, task);
    return task;
  }

  private async load(url: URL, range: string | undefined, key: string): Promise<RelayResponse> {
    const { body, status, contentType, contentRange } = await this.download(url, range);
    const playlist = isPlaylist(body);
    const headers: Record<string, string> = { 'Cache-Control': 'no-store' };
    let output = body;
    if (playlist) {
      output = new TextEncoder().encode(this.rewrite(new TextDecoder().decode(body), url));
      headers['Content-Type'] = 'application/vnd.apple.mpegurl';
    } else {
      headers['Content-Type'] = contentType ?? contentTypeFor(url);
      if (contentRange) headers['Content-Range'] = contentRange;
    }
    const response = { status, headers, body: output };
    this.store(key, response, playlist ? PLAYLIST_LIFETIME_MS : SEGMENT_LIFETIME_MS);
    return response;
  }

  private async download(url: URL, range?: string) {
    if (url.protocol === 'file:') {
      try {
        return { body: await Deno.readFile(url), status: 200, contentType: undefined, contentRange: undefined };
      } catch {
        throw new RelayError(404, "Stream data isn't ready yet");
      }
    }
    const target = this.upstream.prepare ? this.upstream.prepare(url) : url;
    const response = await fetch(target, {
      headers: range ? { Range: range } : {},
      signal: AbortSignal.timeout(20_000),
    });
    if (response.status === 401 || response.status === 403) {
      // Usually an expired session token; refresh it so the players' retries succeed.
      const refreshed = await this.onUnauthorized();
      if (refreshed) this.upstream = refreshed;
      throw new RelayError(502, 'Upstream session expired; refreshing');
    }
    if (!response.ok) throw new RelayError(502, `Upstream returned HTTP ${response.status}`);
    return {
      body: new Uint8Array(await response.arrayBuffer()),
      status: response.status,
      contentType: response.headers.get('Content-Type') ?? undefined,
      contentRange: response.headers.get('Content-Range') ?? undefined,
    };
  }

  rewrite(text: string, base: URL): string {
    return text
      .split('\n')
      .map((raw) => {
        const line = raw.trim();
        if (!line) return raw;
        if (!line.startsWith('#')) return this.localURI(line, base) ?? raw;
        return raw.replace(/URI="([^"]+)"/g, (whole, value) => {
          const local = this.localURI(value, base);
          return local ? `URI="${local}"` : whole;
        });
      })
      .join('\n');
  }

  private localURI(reference: string, base: URL): string | null {
    let url: URL;
    try {
      url = new URL(reference, base);
    } catch {
      return null;
    }
    if (!['http:', 'https:', 'file:'].includes(url.protocol)) return null;
    return this.mediaPrefix + this.token(url);
  }

  private token(url: URL): string {
    const existing = this.tokensByURL.get(url.href);
    if (existing) return existing;
    this.nextToken += 1;
    const extension = url.pathname.split('.').pop()?.toLowerCase() ?? '';
    const token = this.nextToken.toString(36) + (KNOWN_EXTENSIONS.includes(extension) ? `.${extension}` : '');
    this.urlsByToken.set(token, url);
    this.tokensByURL.set(url.href, token);
    // Live playlists roll forward forever; forget the oldest references.
    if (this.urlsByToken.size > TOKEN_LIMIT) {
      const [oldest, oldURL] = this.urlsByToken.entries().next().value!;
      this.urlsByToken.delete(oldest);
      this.tokensByURL.delete(oldURL.href);
    }
    return token;
  }

  private store(key: string, response: RelayResponse, lifetime: number) {
    const now = Date.now();
    for (const [cacheKey, entry] of this.cache) if (entry.expires <= now) this.cache.delete(cacheKey);
    this.cache.set(key, { response, expires: now + lifetime });
    let total = 0;
    for (const entry of this.cache.values()) total += entry.response.body.byteLength;
    for (const [cacheKey, entry] of [...this.cache].sort((a, b) => a[1].expires - b[1].expires)) {
      if (total <= CACHE_BYTE_LIMIT) break;
      this.cache.delete(cacheKey);
      total -= entry.response.body.byteLength;
    }
  }
}

function contentTypeFor(url: URL): string {
  const extension = url.pathname.split('.').pop()?.toLowerCase();
  return extension === 'ts' ? 'video/mp2t' : extension === 'aac' ? 'audio/aac' : extension === 'm4s' || extension === 'mp4' ? 'video/mp4' : extension === 'vtt' ? 'text/vtt' : 'application/octet-stream';
}
