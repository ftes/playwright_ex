// Upstream-JS repro of workers.spec "should attribute network activity for worker inside iframe
// to the iframe" (its wait-for-worker part), with the driver's own playwright-core.
// usage: scripts/linux/run node scripts/linux/js/worker_iframe.js <iterations>   (prints ok/HANG per iteration)
const http = require('http');
const fs = require('fs');
const path = require('path');
const { chromium } = require(process.env.PW_CORE);
// Upstream's test assets: the host's checkout, else the one the test suite downloaded.
const assets = (process.env.PLAYWRIGHT_EX_UPSTREAM || path.join(process.env.PW_CORE, '../../upstream')) + '/tests/assets';

async function attachFrame(page, frameId, url) {
  const handle = await page.evaluateHandle(async ({ frameId, url }) => {
    const frame = document.createElement('iframe');
    frame.src = url;
    frame.id = frameId;
    document.body.appendChild(frame);
    await new Promise(x => frame.onload = x);
    return frame;
  }, { frameId, url });
  return await handle.asElement().contentFrame();
}

(async () => {
  const server = http.createServer((req, res) => {
    const file = path.join(assets, req.url.split('?')[0]);
    fs.readFile(file, (err, data) => {
      if (err) { res.writeHead(404); res.end(); return; }
      const type = file.endsWith('.js') ? 'text/javascript' : file.endsWith('.css') ? 'text/css' : 'text/html';
      res.writeHead(200, { 'content-type': type + '; charset=utf-8', 'cache-control': 'no-cache, no-store' });
      res.end(data);
    });
  });
  await new Promise(r => server.listen(0, r));
  const prefix = `http://localhost:${server.address().port}`;
  const browser = await chromium.launch();
  const n = +process.argv[2] || 20;
  let hangs = 0;
  for (let i = 0; i < n; i++) {
    const context = await browser.newContext();
    const page = await context.newPage();
    await page.goto(prefix + '/empty.html');
    try {
      await Promise.all([
        page.waitForEvent('worker', { timeout: 10000 }),
        attachFrame(page, 'frame1', prefix + '/worker/worker.html'),
      ]);
      console.log(`${i} ok`);
    } catch (e) {
      hangs++;
      console.log(`${i} HANG ${e.message.split('\n')[0]}`);
    }
    await context.close();
  }
  console.log(`done: ${hangs}/${n} hangs`);
  await browser.close();
  server.close();
})();
