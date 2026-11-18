// Fake npm registry for one private package. Requires "Authorization: Bearer <TOKEN>" on EVERY request (like CodeArtifact) and
// logs what it saw (the token is never printed, only whether it matched). Usage: node registry.mjs <port> <tarball> <token> <log>
import http from 'node:http';
import fs from 'node:fs';
import crypto from 'node:crypto';

const [port, tarball, token, logFile] = [process.argv[2], process.argv[3], process.argv[4], process.argv[5]];
const data = fs.readFileSync(tarball);
const shasum = crypto.createHash('sha1').update(data).digest('hex');
const integrity = 'sha512-' + crypto.createHash('sha512').update(data).digest('base64');
const log = (m) => fs.appendFileSync(logFile, m + '\n');

http.createServer((req, res) => {
  const auth = req.headers['authorization'] || '';
  const ok = auth === `Bearer ${token}`;
  log(`${req.method} ${req.url} auth=${auth ? (ok ? 'valid' : 'WRONG') : 'none'}`);
  if (!ok) { res.writeHead(401, { 'content-type': 'application/json' }); res.end('{"error":"unauthorized"}'); return; }
  if (req.url.endsWith('.tgz')) { res.writeHead(200, { 'content-type': 'application/octet-stream' }); res.end(data); return; }
  if (decodeURIComponent(req.url).startsWith('/@example/priv')) {
    const body = {
      name: '@example/priv', 'dist-tags': { latest: '1.0.0' },
      versions: { '1.0.0': { name: '@example/priv', version: '1.0.0', dist: { tarball: `http://localhost:${port}/@example/priv/-/priv-1.0.0.tgz`, shasum, integrity } } },
    };
    res.writeHead(200, { 'content-type': 'application/json' }); res.end(JSON.stringify(body)); return;
  }
  res.writeHead(404); res.end('{}');
}).listen(Number(port), 'localhost', () => log('listening'));
