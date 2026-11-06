// The server of upstream's 'should handle TLS renegotiation with client certificates'
// (tests/library/client-certificates.spec.ts), run with the driver's Node.js: Erlang's :ssl
// cannot ask for a client certificate in a renegotiation (playwright-python uses pyOpenSSL).
// The request handler is upstream's, verbatim. Usage: node tls_renegotiation_server.js <assets dir>
// (tests/assets). Prints (port=>N) once it listens.
const fs = require('fs');
const https = require('https');
const path = require('path');
const zlib = require('zlib');

const assets = process.argv[2];
const asset = p => path.join(assets, p);

const server = https.createServer({
  key: fs.readFileSync(asset('client-certificates/server/server_key.pem')),
  cert: fs.readFileSync(asset('client-certificates/server/server_cert.pem')),
  ca: [fs.readFileSync(asset('client-certificates/server/server_cert.pem'))],
  requestCert: false, // Initially don't request client cert
  rejectUnauthorized: false,
  // TLSv1.3 does not support renegotiation
  minVersion: 'TLSv1.2',
  maxVersion: 'TLSv1.2',
});

server.on('request', async (req, res) => {
  if (!req.socket)
    return;
  const renegotiate = () => new Promise((resolve, reject) => {
    req.socket.renegotiate({
      requestCert: true,
      rejectUnauthorized: false
    }, err => {
      if (err)
        reject(err);
      else
        resolve();
    });
  });
  if (req.url === '/') {
    res.writeHead(200, { 'Content-Type': 'text/html', 'connection': 'close' });
    res.end();
  } else if (req.url === '/from-fetch-api') {
    res.writeHead(200, {
      'Content-Type': 'text/plain',
      'Transfer-Encoding': 'chunked',
      // A renegotiated connection must not be reused: a second renegotiation on
      // the same socket trips Node's tls.CLIENT_RENEG_LIMIT and destroys it.
      'Connection': 'close'
    });
    res.flushHeaders();

    await new Promise(resolve => req.once('data', data => {
      res.write(`server received: ${data.toString()}\n`);
      resolve();
    }));

    await renegotiate();
    for (let i = 0; i < 4; i++) {
      res.write(`${i}-from-server\n`);
      // Best-effort to trigger a new chunk
      await new Promise(resolve => setTimeout(resolve, 100));
    }
    res.end('server closed the connection');
  } else if (req.url === '/style.css') {
    res.writeHead(200, {
      'Content-Type': 'text/css',
      'Content-Encoding': 'gzip',
      'Transfer-Encoding': 'chunked',
      'Connection': 'close'
    });
    res.flushHeaders();

    await renegotiate();

    const stylesheet = `
          button {
            background-color: red;
          }
        `;

    const stylesheetBuffer = await new Promise((resolve, reject) => {
      zlib.gzip(stylesheet, (err, buffer) => {
        if (err)
          reject(err);
        else
          resolve(buffer);
      });
    });
    for (let i = 0; i < stylesheetBuffer.length; i += 100) {
      res.write(stylesheetBuffer.slice(i, i + 100));
      // Best-effort to trigger a new chunk
      await new Promise(resolve => setTimeout(resolve, 20));
    }
    res.end();
  } else {
    res.writeHead(404);
    res.end();
  }
});

server.listen(0, 'localhost', () => console.log(`(port=>${server.address().port})`));
