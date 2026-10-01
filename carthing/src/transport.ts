import type { BridgethingClient, HttpHeader, HttpMethod } from '@bridgething/client';
import { MAC_ORIGIN, MacLinkError, type Response } from './mac';

export interface TransportRequest {
  url: string;
  method: HttpMethod;
  headers: HttpHeader[];
  body: Uint8Array | null;
  timeoutMs: number;
}

/** How requests reach the Mac. Throws `MacLinkError` when the Mac can't be reached. */
export interface Transport {
  request(request: TransportRequest): Promise<Response>;
}

/** On the Car Thing: requests travel over USB and Bridgething performs them on the Mac. */
export class BridgethingTransport implements Transport {
  constructor(private readonly client: BridgethingClient) {}

  async request({ url, method, headers, body, timeoutMs }: TransportRequest): Promise<Response> {
    const result = await this.client.net.fetch(
      { request: { url, method, headers, body, timeoutMs, redirect: 'follow' } },
      { timeoutMs: timeoutMs + 2_000 },
    );
    if (result.ok) return result.response.response;
    if (result.kind === 'protocol') throw new MacLinkError(`Bridgething error: ${JSON.stringify(result.error)}`);
    const error = result.error.error;
    switch (error.type) {
      case 'requestFailed':
        throw new MacLinkError(/refused|connect/i.test(error.data.reason) ? 'TV Thing isn’t running on your Mac' : `Request failed: ${error.data.reason}`);
      case 'timeout':
        throw new MacLinkError('Your Mac took too long to answer');
      case 'noGateway':
      case 'unavailable':
        throw new MacLinkError('The Car Thing isn’t connected to a Mac');
    }
  }
}

/**
 * For development in a desktop browser (`npm run dev`): the dev server proxies `/mac/*`
 * to the Mac app, standing in for Bridgething.
 */
export class BrowserTransport implements Transport {
  async request({ url, method, headers, body, timeoutMs }: TransportRequest): Promise<Response> {
    const target = url.replace(MAC_ORIGIN, `${location.origin}/mac`);
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
      throw new MacLinkError((error as Error).name === 'AbortError' ? 'Your Mac took too long to answer' : 'TV Thing isn’t running on your Mac');
    } finally {
      window.clearTimeout(timer);
    }
  }
}
