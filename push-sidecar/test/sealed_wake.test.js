// The sealed wakes Rust must open (crypto/push_seal.rs reads sealed_wake_vectors.json).
// The receiver keys are RFC 8291's example receiver. Encryption is random, so the file
// is written once and from then on checked:
//   HOLLOW_WRITE_PUSH_VECTORS=1 NODE_PATH=<web-push modules> node --test
const test = require('node:test');
const assert = require('node:assert');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const ece = require('http_ece');
const { buildMessage, SEALED_FIELD, PAD_TO } = require('../fcm');

const VECTORS = path.join(__dirname, 'sealed_wake_vectors.json');
const UA_PRIVATE = 'q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94';
const UA_PUBLIC = 'BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4';
const AUTH = 'BTBZMqHH6r4Tts7J_aSIgg';
const token = JSON.stringify({ v: 2, fcm: 'fixture-token', p256dh: UA_PUBLIC, auth: AUTH });

const CASES = [
  { platform: 'android', sender: '12D3KooWDmSenderDevice' },
  { platform: 'ios', sender: '12D3KooWChSenderDevice', server: 'a1b2c3d4e5f60718293a4b5c6d7e8f9012345678', channel: 'general-0001', mention: true },
];

function open(sealed) {
  const ecdh = crypto.createECDH('prime256v1');
  ecdh.setPrivateKey(Buffer.from(UA_PRIVATE, 'base64url'));
  return ece.decrypt(Buffer.from(sealed, 'base64url'), { version: 'aes128gcm', privateKey: ecdh, authSecret: AUTH });
}

test('the vectors are what the sidecar seals, and the receiver opens them', () => {
  if (process.env.HOLLOW_WRITE_PUSH_VECTORS === '1') {
    const now = Date.UTC(2026, 9, 18, 12);
    const cases = CASES.map(c => {
      const { message } = buildMessage({ token, ...c }, now);
      const { ts, ...wake } = JSON.parse(open(message.data[SEALED_FIELD]).toString('utf8'));
      assert.strictEqual(ts, now / 1000);
      return { platform: c.platform, data: message.data, wake };
    });
    // `wake` is what the phone hands on: the seal time stays inside.
    const out = { ua_private: UA_PRIVATE, ua_public: UA_PUBLIC, auth: AUTH, sealed_at: now / 1000, cases };
    fs.writeFileSync(VECTORS, `${JSON.stringify(out, null, 2)}\n`);
  }
  const v = JSON.parse(fs.readFileSync(VECTORS, 'utf8'));
  assert.strictEqual(v.cases.length, CASES.length);
  for (const [i, c] of v.cases.entries()) {
    assert.deepStrictEqual(Object.keys(c.data), [SEALED_FIELD]);
    const plain = open(c.data[SEALED_FIELD]);
    assert.strictEqual(plain.length, PAD_TO, 'padded to one size');
    const { ts, ...wake } = JSON.parse(plain.toString('utf8'));
    assert.strictEqual(ts, v.sealed_at, 'the seal time rides inside the block');
    assert.deepStrictEqual(wake, c.wake);
    assert.strictEqual(wake.sender, CASES[i].sender);
    assert.ok(!('cid' in wake), 'no banner id: grouping happens on the phone');
  }
  assert.strictEqual(v.cases[0].wake.type, 'wake');
  assert.strictEqual(v.cases[1].wake.type, 'channel_wake');
});

test('every sealed block carries the sidecar clock in seconds', () => {
  const before = Math.floor(Date.now() / 1000);
  for (const c of CASES) {
    const { message } = buildMessage({ token, ...c });
    const inner = JSON.parse(open(message.data[SEALED_FIELD]).toString('utf8'));
    assert.ok(Number.isInteger(inner.ts) && inner.ts >= before && inner.ts <= Math.floor(Date.now() / 1000) + 1, String(inner.ts));
  }
});
