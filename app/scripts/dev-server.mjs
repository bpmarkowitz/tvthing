// Serves the built webapp for a desktop browser and proxies /ext/* to the extension,
// standing in for Bridgething. Run the extension on its own first:
//
//   deno run -A dist/extension-dev.mjs
//   npm run dev
//
// then open http://localhost:5173/?browser (the Car Thing app) or /settings-dev (settings).
// TVTHING_PORT moves the extension off its usual port (set it for both commands).
import { createReadStream, existsSync, statSync } from 'node:fs';
import { request as httpRequest, createServer } from 'node:http';
import { extname, join, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(fileURLToPath(new URL('..', import.meta.url)), 'dist', 'app');
const extensionPort = Number(process.env.TVTHING_PORT ?? 17839);
const port = Number(process.env.PORT ?? 5173);
const types = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml', '.json': 'application/json' };

const settingsHost = fileURLToPath(new URL('settings-host.html', import.meta.url));

/** Stands in for Bridgething's native fetch from the settings page. */
async function settingsFetch(req, res) {
  let body = '';
  for await (const chunk of req) body += chunk;
  try {
    const request = JSON.parse(body);
    const response = await fetch(request.url, {
      method: request.method,
      headers: request.headers,
      body: request.body ? Buffer.from(request.body.data, request.body.kind === 'base64' ? 'base64' : 'utf8') : undefined,
      signal: AbortSignal.timeout(request.timeoutMs ?? 15_000),
    });
    const data = Buffer.from(await response.arrayBuffer()).toString('base64');
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: response.status, headers: [...response.headers], body: { kind: 'base64', data } }));
  } catch (error) {
    res.writeHead(502);
    res.end(`network: ${error.message}`);
  }
}

createServer((req, res) => {
  if (req.url === '/fetch' && req.method === 'POST') return settingsFetch(req, res);
  if (req.url === '/settings-dev') {
    res.writeHead(200, { 'Content-Type': 'text/html' });
    createReadStream(settingsHost).pipe(res);
    return;
  }
  if (req.url.startsWith('/ext/')) {
    const upstream = httpRequest(
      { host: '127.0.0.1', port: extensionPort, method: req.method, path: req.url.slice(4), headers: { ...req.headers, host: `127.0.0.1:${extensionPort}` } },
      (response) => {
        res.writeHead(response.statusCode ?? 502, response.headers);
        response.pipe(res);
      },
    );
    upstream.on('error', () => {
      res.writeHead(502);
      res.end();
    });
    req.pipe(upstream);
    return;
  }
  const path = normalize(join(root, new URL(req.url, 'http://x').pathname === '/' ? 'index.html' : new URL(req.url, 'http://x').pathname));
  if (!path.startsWith(root) || !existsSync(path) || statSync(path).isDirectory()) {
    res.writeHead(404);
    res.end();
    return;
  }
  res.writeHead(200, { 'Content-Type': types[extname(path)] ?? 'application/octet-stream' });
  createReadStream(path).pipe(res);
}).listen(port, () => console.log(`TV Thing dev: http://localhost:${port}/?browser (extension on ${extensionPort})`));
