// Serves the built webapp for a desktop browser and proxies /mac/* to the Mac engine,
// standing in for Bridgething. Open http://localhost:5173/?browser
//
//   MAC_PORT=17839 npm run dev
import { createReadStream, existsSync, statSync } from 'node:fs';
import { request as httpRequest, createServer } from 'node:http';
import { extname, join, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(fileURLToPath(new URL('..', import.meta.url)), 'dist', 'app');
const macPort = Number(process.env.MAC_PORT ?? 17839);
const port = Number(process.env.PORT ?? 5173);
const types = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml', '.json': 'application/json' };

createServer((req, res) => {
  if (req.url.startsWith('/mac/')) {
    const upstream = httpRequest(
      { host: '127.0.0.1', port: macPort, method: req.method, path: req.url.slice(4), headers: { ...req.headers, host: `127.0.0.1:${macPort}` } },
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
}).listen(port, () => console.log(`TV Thing dev: http://localhost:${port}/?browser (Mac engine on ${macPort})`));
