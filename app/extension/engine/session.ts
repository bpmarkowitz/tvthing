// One tune of one channel, served under `/stream/<id>/`.
//
// A new session (with a new id) is created on every channel change, so requests left over
// from the previous channel fail cleanly instead of mixing streams.
//
// Routes below the session path:
// - `index.m3u8`: what the Car Thing and the host's audio player load
// - `source.m3u8`, `s/<token>`: the relayed upstream stream (also FFmpeg's input)
// - `o/<token>`: FFmpeg's output

import type { PlaybackMode, SourceReference } from '../../src/shared/library';
import { conversionVariant, evaluate, parsePlaylist, type Playlist, preferredVariant } from './playlist';
import { provider } from './providers';
import { Relay, RelayError, type RelayResponse } from './relay';
import { Transcoder } from './transcoder';

export type Delivery = { kind: 'direct' } | { kind: 'converted'; reason: string } | { kind: 'unconverted'; reason: string };

export interface SessionEnvironment {
  /** e.g. `http://127.0.0.1:17839` */
  origin: string;
  ffmpeg: () => string | null;
  log: (message: string) => void;
}

interface SourcePlaylists {
  multivariant: Playlist | null;
  media: Playlist;
}

const RETRY_AFTER_FAILURE_MS = 3_000;

export class StreamSession {
  readonly id = crypto.randomUUID().slice(0, 8);
  private preparation: Promise<Delivery> | null = null;
  private failedAt: number | null = null;
  private sourceRelay: Relay | null = null;
  private transcoder: Transcoder | null = null;
  private conversion: { onDemand: boolean; program?: number } = { onDemand: false };
  private output: { playlist: string; relay: Relay } | null = null;
  private lastAccess = Date.now();
  private stopped = false;

  constructor(
    readonly source: SourceReference,
    readonly playback: PlaybackMode,
    private readonly environment: SessionEnvironment,
  ) {}

  get playlistPath(): string {
    return `${this.basePath}/index.m3u8`;
  }

  private get basePath(): string {
    return `/stream/${this.id}`;
  }

  stop() {
    this.stopped = true;
    this.transcoder?.stop();
  }

  /** Stops FFmpeg when nobody has requested anything for a while. It restarts on demand. */
  suspendIfIdle(afterMs: number) {
    if (!this.transcoder?.running || Date.now() - this.lastAccess < afterMs) return;
    this.transcoder.stop();
    this.output = null;
    this.environment.log('Paused conversion while nothing is watching');
  }

  async handle(route: string[], range?: string): Promise<RelayResponse> {
    if (this.stopped) throw new RelayError(404, 'This channel is no longer playing');
    this.lastAccess = Date.now();
    const [first, second] = route;
    if (route.length === 1 && first === 'index.m3u8') {
      const delivery = await this.prepared();
      return delivery.kind === 'converted' ? this.convertedEntry(range) : this.requireSourceRelay().entry(range);
    }
    if (route.length === 1 && first === 'source.m3u8') {
      // FFmpeg reads this while preparation is still waiting on FFmpeg, so only the relay
      // (created early in preparation) is required here.
      if (!this.sourceRelay) await this.prepared();
      return this.requireSourceRelay().entry(range);
    }
    if (route.length === 2 && first === 's') return this.requireSourceRelay().media(second, range);
    if (route.length === 2 && first === 'o') {
      if (!this.output) throw new RelayError(404, 'Conversion restarted');
      return this.output.relay.media(second, range);
    }
    throw new RelayError(404, 'Not found');
  }

  // Preparation

  /** The in-progress or finished preparation, retrying a failed one after a pause. */
  private prepared(): Promise<Delivery> {
    if (this.preparation && (this.failedAt === null || Date.now() - this.failedAt < RETRY_AFTER_FAILURE_MS)) return this.preparation;
    this.failedAt = null;
    this.preparation = this.prepare();
    return this.preparation;
  }

  private async prepare(): Promise<Delivery> {
    try {
      const resolved = await provider(this.source.provider).resolve(this.source, false);
      this.sourceRelay = new Relay(`${this.basePath}/s/`, resolved, async () => {
        this.environment.log('Upstream rejected a request; refreshing the session');
        try {
          return await provider(this.source.provider).resolve(this.source, true);
        } catch {
          return null;
        }
      });
      const playlists = await this.sourcePlaylists();
      this.conversion = { onDemand: playlists.media.hasEndList, program: playlists.multivariant ? conversionVariant(playlists.multivariant) : undefined };
      const delivery = await this.chooseDelivery(playlists);
      if (delivery.kind === 'converted') await this.convertedEntry();
      this.environment.log(`Tuned (${describe(delivery)})`);
      return delivery;
    } catch (error) {
      this.failedAt = Date.now();
      this.environment.log(`Tune failed: ${message(error)}`);
      throw error;
    }
  }

  private async chooseDelivery(playlists: SourcePlaylists): Promise<Delivery> {
    const ffmpegAvailable = this.environment.ffmpeg() !== null;
    if (this.playback === 'direct') return { kind: 'direct' };
    if (this.playback === 'convert') {
      if (!ffmpegAvailable) throw new RelayError(503, "This channel is set to always convert, but FFmpeg isn't installed.");
      return { kind: 'converted', reason: 'Set to always convert' };
    }
    const segmentBytes = await this.sampleSegmentSize(playlists.media);
    const verdict = evaluate(playlists.multivariant, playlists.media, segmentBytes);
    if (verdict.direct) return { kind: 'direct' };
    return ffmpegAvailable ? { kind: 'converted', reason: verdict.reason } : { kind: 'unconverted', reason: verdict.reason };
  }

  /** The entry playlist and the media playlist the Car Thing would play from it, read through the relay (which also warms its cache). */
  private async sourcePlaylists(): Promise<SourcePlaylists> {
    const relay = this.requireSourceRelay();
    const entry = parsePlaylist(text(await relay.entry()));
    if (entry.variants.length === 0) return { multivariant: null, media: entry };
    const variant = preferredVariant(entry);
    const token = variant && tokenOf(variant.uri);
    if (!token) return { multivariant: entry, media: entry };
    return { multivariant: entry, media: parsePlaylist(text(await relay.media(token))) };
  }

  /** Fetches the newest segment, where playback starts, so the relay also has it cached. */
  private async sampleSegmentSize(media: Playlist): Promise<number | undefined> {
    const uri = media.segmentURIs[media.segmentURIs.length - 1];
    const token = uri && tokenOf(uri);
    if (!token || !this.sourceRelay) return undefined;
    try {
      return (await this.sourceRelay.media(token)).body.byteLength;
    } catch {
      return undefined;
    }
  }

  private async convertedEntry(range?: string): Promise<RelayResponse> {
    const playlist = await this.requireTranscoder().playlist();
    if (this.output?.playlist !== playlist) {
      this.output = { playlist, relay: new Relay(`${this.basePath}/o/`, { entryURL: new URL(`file://${playlist}`) }) };
    }
    return this.output.relay.entry(range);
  }

  private requireTranscoder(): Transcoder {
    if (this.transcoder) return this.transcoder;
    const executable = this.environment.ffmpeg();
    if (!executable) throw new RelayError(503, "FFmpeg isn't installed.");
    this.transcoder = new Transcoder(
      executable,
      { url: new URL(`${this.environment.origin}${this.basePath}/source.m3u8`), ...this.conversion },
      this.environment.log,
    );
    return this.transcoder;
  }

  private requireSourceRelay(): Relay {
    if (!this.sourceRelay) throw new RelayError(503, "Stream isn't ready yet");
    return this.sourceRelay;
  }
}

/** Relay URIs end in their token: `/stream/<session>/s/<token>`. */
function tokenOf(uri: string): string | undefined {
  return uri.split('/').pop() || undefined;
}

function text(response: RelayResponse): string {
  return new TextDecoder().decode(response.body);
}

export function message(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function describe(delivery: Delivery): string {
  switch (delivery.kind) {
    case 'direct':
      return 'direct';
    case 'converted':
      return `converting: ${delivery.reason}`;
    case 'unconverted':
      return `direct without FFmpeg: ${delivery.reason}`;
  }
}
