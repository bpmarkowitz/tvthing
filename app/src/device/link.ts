import type { HttpHeader, HttpMethod } from '@bridgething/client';
import { EXTENSION_ORIGIN, type Health, type HostTimeline, type SessionReply, type SessionRequest } from '../shared/api';
import type { Transport } from './transport';

export interface Response {
  status: number;
  body: Uint8Array;
}

export class LinkError extends Error {
  constructor(message: string, readonly status?: number) {
    super(message);
    this.name = 'LinkError';
  }
}

/**
 * TV Thing's extension, running on the computer. Requests are carried over USB by
 * Bridgething and performed there, so this is the computer's loopback address.
 */
export class ExtensionLink {
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

  health(): Promise<Health> {
    return this.call('GET', '/api/v1/health', undefined, 4_000);
  }

  /** Starts a fresh stream for a channel; the reply's playlist is what both players load. */
  createSession(request: SessionRequest): Promise<SessionReply> {
    return this.call('POST', '/api/v1/sessions', request);
  }

  /** Where the host player's position counts from, once it has loaded the stream. */
  hostTimeline(session: string): Promise<HostTimeline> {
    return this.call('GET', `/api/v1/sessions/${session}/host`, undefined, 3_000);
  }

  /** Forgets where the host player started, before it loads the stream again. */
  resetHostTimeline(session: string): Promise<HostTimeline> {
    return this.call('DELETE', `/api/v1/sessions/${session}/host`, undefined, 3_000);
  }

  /** Sends a line to Bridgething's log on the computer. Never throws. */
  log(message: string): void {
    console.log('[TV Thing]', message);
    this.call('POST', '/api/v1/log', { message }, 3_000).catch(() => {});
  }

  private async call<T>(method: HttpMethod, path: string, json?: unknown, timeoutMs = 6_000): Promise<T> {
    const response = await this.fetch(EXTENSION_ORIGIN + path, { method, json, timeoutMs });
    const parsed = parseJSON(response.body);
    if (response.status < 200 || response.status >= 300) {
      throw new LinkError((parsed as { error?: string }).error ?? `TV Thing answered HTTP ${response.status}`, response.status);
    }
    return parsed as T;
  }
}

/** The `{ error }` message in an extension response body, if there is one. */
export function errorMessage(body: Uint8Array | string): string | undefined {
  const parsed = parseJSON(typeof body === 'string' ? new TextEncoder().encode(body) : body) as { error?: unknown };
  return typeof parsed.error === 'string' ? parsed.error : undefined;
}

function parseJSON(body: Uint8Array): unknown {
  try {
    return JSON.parse(new TextDecoder().decode(body) || '{}');
  } catch {
    return {};
  }
}
