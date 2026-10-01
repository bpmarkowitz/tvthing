import type { HttpHeader, HttpMethod } from '@bridgething/client';
import type { Transport } from './transport';

/**
 * The TV Thing Mac app's local server. Requests are carried over USB by Bridgething and
 * performed on the Mac, so this is the Mac's loopback address, not the Car Thing's.
 */
export const MAC_ORIGIN = 'http://127.0.0.1:17839';

// Mirrors `DeviceAPI` in the Mac app (TVThingKit/Server/DeviceAPI.swift).
// Swift omits `nil` values, so optional fields may be absent rather than null.

export interface ChannelInfo {
  id: string;
  number: number;
  name: string;
  /** Car Thing button (0–3) this channel is saved to. */
  favorite?: number;
}

export interface DeviceState {
  api: number;
  /** Changes whenever anything on screen should update. */
  revision: number;
  /** Changes only when the stream itself changes. */
  session?: { id: string; playlist: string };
  channel?: ChannelInfo;
  channels: ChannelInfo[];
  phase: 'preparing' | 'playing' | 'failed' | 'empty';
  message?: string;
  display: DisplayOptions;
  /** Mac audio muted; the picture keeps playing. */
  muted: boolean;
  /** Mac audio volume, 0–1. */
  volume: number;
}

/** How much one knob detent changes the volume (mirrors `TVThingEngine.volumeStep`). */
export const VOLUME_STEP = 0.05;

export interface DisplayOptions {
  /** Horizontal CRT scanlines over the picture. */
  scanlines: boolean;
}

export type TuneTarget = { channel: string } | { favorite: number } | { step: number };

export interface SyncReport {
  session: string;
  /** Program-date-time of the frame on screen, in Unix milliseconds. */
  position: number | null;
  playing: boolean;
  /** Increments each time playback (re)starts, so the Mac knows to re-align audio. */
  generation: number;
  /** False while the picture is hidden; the Mac keeps audio silent to match. */
  visible: boolean;
}

export interface Response {
  status: number;
  body: Uint8Array;
}

export class MacLinkError extends Error {
  constructor(message: string, readonly status?: number) {
    super(message);
    this.name = 'MacLinkError';
  }
}

/** Typed access to the Mac app, plus raw byte fetching for the video loader. */
export class MacLink {
  constructor(private readonly transport: Transport) {}

  fetch(
    url: string,
    options: { method?: HttpMethod; json?: unknown; headers?: HttpHeader[]; timeoutMs?: number } = {},
  ): Promise<Response> {
    const headers = [...(options.headers ?? [])];
    let body: Uint8Array | null = null;
    if (options.json !== undefined) {
      body = new TextEncoder().encode(JSON.stringify(options.json));
      headers.push({ name: 'Content-Type', value: 'application/json' });
    }
    return this.transport.request({ url, method: options.method ?? 'GET', headers, body, timeoutMs: options.timeoutMs ?? 10_000 });
  }

  state(): Promise<DeviceState> {
    return this.call('GET', '/api/v1/state');
  }

  tune(target: TuneTarget): Promise<DeviceState> {
    return this.call('POST', '/api/v1/tune', target);
  }

  saveFavorite(slot: number, channel?: string): Promise<DeviceState> {
    return this.call('POST', '/api/v1/favorites', channel ? { slot, channel } : { slot });
  }

  /** Toggles the Mac's audio, or sets it when `muted` is given. */
  mute(muted?: boolean): Promise<DeviceState> {
    return this.call('POST', '/api/v1/mute', muted === undefined ? {} : { muted });
  }

  /** Moves the Mac's audio volume by knob detents. */
  adjustVolume(steps: number): Promise<DeviceState> {
    return this.call('POST', '/api/v1/volume', { steps });
  }

  async sync(report: SyncReport): Promise<void> {
    await this.call('POST', '/api/v1/sync', report, 3_000);
  }

  /** Sends a line to Settings → Diagnostics on the Mac. Never throws. */
  log(message: string): void {
    console.log('[TV Thing]', message);
    this.call('POST', '/api/v1/log', { message }, 3_000).catch(() => {});
  }

  private async call<T>(method: HttpMethod, path: string, json?: unknown, timeoutMs = 6_000): Promise<T> {
    const response = await this.fetch(MAC_ORIGIN + path, { method, json, timeoutMs });
    const text = new TextDecoder().decode(response.body);
    let parsed: unknown = {};
    try {
      parsed = JSON.parse(text || '{}');
    } catch {
      // Non-JSON bodies are reported by status below.
    }
    if (response.status < 200 || response.status >= 300) {
      const message = (parsed as { error?: string }).error ?? `The Mac app answered HTTP ${response.status}`;
      throw new MacLinkError(message, response.status);
    }
    return parsed as T;
  }
}
