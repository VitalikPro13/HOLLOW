// The UnifiedPush address guard (unifiedpush.js): a client names the URL, so the sidecar
// must never post to this machine or the networks behind it. Needs web-push on the module
// path (`npm install`, or NODE_PATH=/opt/hollow-push/node_modules on the relay box).
//   node --test
const test = require('node:test');
const assert = require('node:assert');
const os = require('node:os');
const { parseToken, isPublicAddress, blockOwnAddresses } = require('../unifiedpush');

const token = endpoint => JSON.stringify({ v: 1, endpoint, p256dh: 'BOrKey', auth: 'authKey' });

test('a public https endpoint is taken', () => {
  assert.ok(parseToken(token('https://ntfy.sh/up123')));
  assert.ok(parseToken(token('https://93.184.215.14/up123')));
});

test('loopback, private and metadata literals are refused', () => {
  for (const host of ['127.0.0.1', '10.1.2.3', '192.168.1.1', '169.254.169.254', '[::1]', '[fd00::1]']) {
    assert.strictEqual(parseToken(token(`https://${host}/up`)), null, host);
  }
});

test("this machine's own addresses are refused", () => {
  const own = Object.values(os.networkInterfaces()).flat().filter(Boolean);
  assert.ok(own.length > 0);
  for (const a of own) assert.strictEqual(isPublicAddress(a.address, a.family), false, a.address);
});

test('an address an interface carries is refused, by name and as a literal', () => {
  blockOwnAddresses({ eth0: [{ address: '93.184.216.34', family: 'IPv4' }, { address: '2606:2800:220:1::1', family: 6 }] });
  assert.strictEqual(isPublicAddress('93.184.216.34', 4), false);
  assert.strictEqual(isPublicAddress('2606:2800:220:1::1', 'IPv6'), false);
  assert.strictEqual(parseToken(token('https://93.184.216.34/up')), null);
  assert.strictEqual(isPublicAddress('93.184.216.35', 4), true, 'a neighbour stays public');
});
