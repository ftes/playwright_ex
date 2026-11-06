// Preloaded (`node -r`) into the long-lived Node.js processes the tests start: exits when stdin
// (the BEAM end of the port's pipe) closes, i.e. when the test BEAM goes away, however it dies.
// `process.exit` runs Playwright's 'exit' handlers, which kill the browsers this process launched.
// Only for a pipe (not /dev/null), and unref'd: it does not keep the process alive.
const fs = require('fs');

let stat;
try {
  stat = fs.fstatSync(0);
} catch {
}
if (stat && (stat.isFIFO() || stat.isSocket())) {
  process.stdin.on('end', () => process.exit(0));
  process.stdin.resume();
  process.stdin.unref?.();
}
