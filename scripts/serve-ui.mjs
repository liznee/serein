import { createReadStream, promises as fs } from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(scriptDir, '..');
const root = path.resolve(scriptDir, '..', 'ui');
const port = Number.parseInt(process.env.SEREIN_UI_PORT || process.env.PORT || '4173', 10);
const host = process.env.SEREIN_UI_HOST || '127.0.0.1';

const MIME = new Map([
  ['.css', 'text/css; charset=utf-8'],
  ['.glb', 'model/gltf-binary'],
  ['.html', 'text/html; charset=utf-8'],
  ['.ico', 'image/x-icon'],
  ['.jpg', 'image/jpeg'],
  ['.jpeg', 'image/jpeg'],
  ['.js', 'text/javascript; charset=utf-8'],
  ['.json', 'application/json; charset=utf-8'],
  ['.md', 'text/markdown; charset=utf-8'],
  ['.mp4', 'video/mp4'],
  ['.png', 'image/png'],
  ['.svg', 'image/svg+xml; charset=utf-8'],
  ['.webp', 'image/webp'],
]);

function safePath(urlPath) {
  let pathname;
  try {
    pathname = decodeURIComponent(new URL(urlPath, 'http://localhost').pathname);
  } catch {
    return null;
  }
  const documentRoutes = new Map([
    ['/README.md', path.join(repositoryRoot, 'README.md')],
    ['/docs/DEPLOYMENT.md', path.join(repositoryRoot, 'docs', 'DEPLOYMENT.md')],
  ]);
  if (documentRoutes.has(pathname)) return documentRoutes.get(pathname);

  const relative = pathname === '/' ? 'index.html' : pathname.replace(/^\/+/, '');
  const resolved = path.resolve(root, relative);
  return resolved === root || resolved.startsWith(`${root}${path.sep}`) ? resolved : null;
}

function parseRange(value, size) {
  const match = /^bytes=(\d*)-(\d*)$/.exec(value || '');
  if (!match) return null;
  let start = match[1] ? Number.parseInt(match[1], 10) : null;
  let end = match[2] ? Number.parseInt(match[2], 10) : null;
  if (start === null) {
    const suffix = end;
    if (!suffix || suffix < 1) return null;
    start = Math.max(0, size - suffix);
    end = size - 1;
  } else {
    end = end === null ? size - 1 : Math.min(end, size - 1);
  }
  if (start < 0 || start >= size || end < start) return null;
  return { start, end };
}

const server = http.createServer(async (request, response) => {
  if (!['GET', 'HEAD'].includes(request.method || '')) {
    response.writeHead(405, { Allow: 'GET, HEAD' });
    response.end();
    return;
  }

  const filePath = safePath(request.url || '/');
  if (!filePath) {
    response.writeHead(400);
    response.end('Bad request');
    return;
  }

  let stat;
  try {
    stat = await fs.stat(filePath);
  } catch {
    response.writeHead(404);
    response.end('Not found');
    return;
  }
  if (!stat.isFile()) {
    response.writeHead(404);
    response.end('Not found');
    return;
  }

  const contentType = MIME.get(path.extname(filePath).toLowerCase()) || 'application/octet-stream';
  const headers = {
    'Accept-Ranges': 'bytes',
    'Content-Type': contentType,
    'Cache-Control': contentType.startsWith('video/') ? 'public, max-age=3600' : 'no-cache',
  };
  const rangeHeader = request.headers.range;
  if (rangeHeader) {
    const range = parseRange(rangeHeader, stat.size);
    if (!range) {
      response.writeHead(416, { ...headers, 'Content-Range': `bytes */${stat.size}` });
      response.end();
      return;
    }
    const length = range.end - range.start + 1;
    response.writeHead(206, {
      ...headers,
      'Content-Length': length,
      'Content-Range': `bytes ${range.start}-${range.end}/${stat.size}`,
    });
    if (request.method === 'HEAD') response.end();
    else createReadStream(filePath, range).pipe(response);
    return;
  }

  response.writeHead(200, { ...headers, 'Content-Length': stat.size });
  if (request.method === 'HEAD') response.end();
  else createReadStream(filePath).pipe(response);
});

server.listen(port, host, () => {
  console.log(`[serein] 官网预览: http://${host}:${port}/index.html`);
  console.log('[serein] 按 Ctrl+C 停止；视频已启用 HTTP Range 请求。');
});
