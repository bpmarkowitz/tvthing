// TV Thing's local server, on the computer's loopback. The Car Thing reaches it through
// Bridgething's net.fetch; Bridgething's host player and FFmpeg load stream URLs from it.

import { API_VERSION, EXTENSION_PORT, type Health, type LogRequest, type SessionReply, type SessionRequest } from '../../src/shared/api';
import { message, StreamSession } from './session';
import { RelayError } from './relay';
import { locateFFmpeg, Transcoder } from './transcoder';

const IDLE_CONVERSION_MS = 45_000;

export interface ServerOptions {
  version: string;
  log: (message: string) => void;
  port?: number;
}

export class Engine {
  private server: Deno.HttpServer | null = null;
  private session: StreamSession | null = null;
  private housekeeping: ReturnType<typeof setInterval> | null = null;
  private ffmpegPath: string | null | undefined;
  private readonly port: number;
  private readonly origin: string;

  constructor(private readonly options: ServerOptions) {
    this.port = options.port ?? EXTENSION_PORT;
    this.origin = `http://127.0.0.1:${this.port}`;
  }

  async start() {
    await Transcoder.removeStaleOutput();
    this.server = Deno.serve({ hostname: '127.0.0.1', port: this.port, onListen: () => this.options.log(`Listening on ${this.origin}`) }, (request) =>
      this.respond(request)
    );
    this.housekeeping = setInterval(() => this.session?.suspendIfIdle(IDLE_CONVERSION_MS), 5_000);
  }

  async stop() {
    if (this.housekeeping !== null) clearInterval(this.housekeeping);
    this.session?.stop();
    this.session = null;
    await this.server?.shutdown();
    this.server = null;
  }

  /** Looked up once, then again whenever it was missing (so installing FFmpeg needs no restart). */
  private ffmpeg(): string | null {
    if (!this.ffmpegPath) this.ffmpegPath = locateFFmpeg();
    return this.ffmpegPath;
  }

  private async respond(request: Request): Promise<Response> {
    // Web pages can reach loopback servers too. Their requests carry a foreign Host, and
    // cross-site posts can't send JSON without a CORS preflight, which this never approves.
    const host = request.headers.get('host')?.toLowerCase();
    if (host && host !== `127.0.0.1:${this.port}` && host !== `localhost:${this.port}`) return error('Forbidden host', 400);
    if (request.method === 'POST' && !request.headers.get('content-type')?.startsWith('application/json')) {
      return error('Expected JSON', 415);
    }
    try {
      return await this.route(request);
    } catch (caught) {
      return error(message(caught), caught instanceof RelayError ? caught.status : 502);
    }
  }

  private async route(request: Request): Promise<Response> {
    const parts = new URL(request.url).pathname.split('/').filter(Boolean);
    const path = parts.join('/');
    if (request.method === 'GET' && path === 'api/v1/health') {
      const health: Health = { app: 'TV Thing', version: this.options.version, api: API_VERSION, ffmpeg: this.ffmpeg() !== null };
      return json(health);
    }
    if (request.method === 'POST' && path === 'api/v1/sessions') {
      const body = (await request.json()) as SessionRequest;
      if (typeof body?.source?.provider !== 'string' || typeof body.source.value !== 'string') return error('Missing source', 400);
      this.session?.stop();
      const session = new StreamSession(body.source, body.playback ?? 'automatic', {
        origin: this.origin,
        ffmpeg: () => this.ffmpeg(),
        log: this.options.log,
      });
      this.session = session;
      const reply: SessionReply = { id: session.id, playlist: session.playlistPath };
      return json(reply);
    }
    if (request.method === 'POST' && path === 'api/v1/log') {
      const body = (await request.json()) as LogRequest;
      this.options.log(`Car Thing: ${String(body?.message ?? '').slice(0, 500)}`);
      return json({ ok: true });
    }
    if ((request.method === 'GET' || request.method === 'HEAD') && parts[0] === 'stream') {
      const session = this.session;
      if (!session || parts[1] !== session.id || parts.length < 3) return error('This stream has ended', 404);
      const result = await session.handle(parts.slice(2), request.headers.get('range') ?? undefined);
      return new Response(request.method === 'HEAD' ? null : (result.body as Uint8Array<ArrayBuffer>), {
        status: result.status,
        headers: result.headers,
      });
    }
    return error('Not found', 404);
  }
}

function json(value: unknown): Response {
  return new Response(JSON.stringify(value), { headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' } });
}

function error(text: string, status: number): Response {
  return new Response(JSON.stringify({ error: text }), { status, headers: { 'Content-Type': 'application/json' } });
}
