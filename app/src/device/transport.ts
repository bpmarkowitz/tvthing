import type { BridgethingClient, HttpHeader, HttpMethod } from '@bridgething/client';
import { EXTENSION_ORIGIN } from '../shared/api';
import { LinkError, type Response } from './link';

export interface TransportRequest {
  url: string;
  method: HttpMethod;
  headers: HttpHeader[];
  body: Uint8Array | null;
  timeoutMs: number;
}

/** How requests reach the computer. Throws `LinkError` when it can't be reached. */
export interface Transport {
  request(request: TransportRequest): Promise<Response>;
}

/** On the Car Thing: requests travel over USB and Bridgething performs them on the computer. */
export class BridgethingTransport implements Transport {
  constructor(private readonly client: BridgethingClient) {}

  async request({ url, method, headers, body, timeoutMs }: TransportRequest): Promise<Response> {
    const result = await this.client.net.fetch(
      { request: { url, method, headers, body, timeoutMs, redirect: 'follow' } },
      { timeoutMs: timeoutMs + 2_000 },
    );
    if (result.ok) return result.response.response;
    if (result.kind === 'protocol') throw new LinkError(`Bridgething error: ${JSON.stringify(result.error)}`);
    const error = result.error.error;
    switch (error.type) {
      case 'requestFailed':
        throw new LinkError(/refused|connect/i.test(error.data.reason) ? 'TV Thing’s helper isn’t running on your computer' : `Request failed: ${error.data.reason}`);
      case 'timeout':
        throw new LinkError('Your computer took too long to answer');
      case 'noGateway':
      case 'unavailable':
        throw new LinkError('The Car Thing isn’t connected to a computer');
    }
  }
}

/**
 * For development in a desktop browser (`npm run dev`): the dev server proxies `/ext/*`
 * to the extension (run standalone), standing in for Bridgething.
 */
export class BrowserTransport implements Transport {
  async request({ url, method, headers, body, timeoutMs }: TransportRequest): Promise<Response> {
    const target = url.replace(EXTENSION_ORIGIN, `${location.origin}/ext`);
    const controller = new AbortController();
    const timer = window.setTimeout(() => controller.abort(), timeoutMs);
    try {
      const response = await fetch(target, {
        method,
        headers: headers.map(({ name, value }) => [name, value] as [string, string]),
        body: body ? new Blob([body as Uint8Array<ArrayBuffer>]) : undefined,
        signal: controller.signal,
      });
      return { status: response.status, body: new Uint8Array(await response.arrayBuffer()) };
    } catch (error) {
      throw new LinkError((error as Error).name === 'AbortError' ? 'Your computer took too long to answer' : 'TV Thing’s helper isn’t running on your computer');
    } finally {
      window.clearTimeout(timer);
    }
  }
}
