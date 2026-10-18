// What Google and Apple get for each wake (fcm.js). A 0.12.1 token (a bare FCM token) gets
// exactly the payload it always got; a token that carries a key set gets one sealed field.
//   NODE_PATH=<web-push modules> node --test
const test = require('node:test');
const assert = require('node:assert');
const crypto = require('node:crypto');
const { buildMessage, parseNativeToken, SEALED_FIELD } = require('../fcm');

const b64u = buf => Buffer.from(buf).toString('base64url');

function keyedToken(fcm = 'fcm-token:APA91b_x-1') {
  const ecdh = crypto.createECDH('prime256v1');
  ecdh.generateKeys();
  const auth = crypto.randomBytes(16);
  const token = JSON.stringify({ v: 2, fcm, p256dh: b64u(ecdh.getPublicKey()), auth: b64u(auth) });
  return { token, ecdh, auth };
}

// The payloads 0.12.1 clients were built against, written out by hand.
test('a plain android token gets exactly the 0.12.1 payload', () => {
  assert.deepStrictEqual(buildMessage({ token: 'tok', platform: 'android', sender: 'dev1' }), {
    message: { token: 'tok', data: { type: 'wake', sender: 'dev1' }, android: { priority: 'high' } },
  });
  assert.deepStrictEqual(
    buildMessage({ token: 'tok', platform: 'android', sender: 'dev1', server: 's1', channel: 'c1', mention: true }),
    {
      message: {
        token: 'tok',
        data: { type: 'channel_wake', sender: 'dev1', server: 's1', channel: 'c1', mention: '1' },
        android: { priority: 'high' },
      },
    },
  );
});

test('a plain ios token gets exactly the 0.12.1 payload', () => {
  const aps = {
    alert: { title: 'Hollow', body: 'New message' },
    sound: 'default',
    'mutable-content': 1,
    'content-available': 1,
  };
  assert.deepStrictEqual(buildMessage({ token: 'tok', platform: 'ios', sender: 'dev1' }), {
    message: {
      token: 'tok',
      data: { type: 'wake', sender: 'dev1' },
      apns: {
        headers: { 'apns-priority': '10', 'apns-push-type': 'alert', 'apns-collapse-id': '1762235127' },
        payload: { aps },
      },
    },
  });
  assert.deepStrictEqual(
    buildMessage({ token: 'tok', platform: 'ios', server: 's1', channel: 'c1', mention: false }),
    {
      message: {
        token: 'tok',
        data: { type: 'channel_wake', server: 's1', channel: 'c1', mention: '0' },
        apns: {
          headers: { 'apns-priority': '10', 'apns-push-type': 'alert', 'apns-collapse-id': '277189821' },
          payload: { aps },
        },
      },
    },
  );
  assert.deepStrictEqual(buildMessage({ token: 'tok', platform: 'ios' }).message.apns.headers, {
    'apns-priority': '10',
    'apns-push-type': 'alert',
  });
});

// Ids long and distinctive enough that a random base64url blob cannot hold them by chance.
const SENDER = '12D3KooWSenderDeviceIdForTheWireTest';
const SERVER = 'a1b2c3d4e5f60718293a4b5c6d7e8f9012345678';
const CHANNEL = 'general-channel-for-the-wire-test';

// Everything Google or Apple reads besides the sealed blob itself.
function outsideTheBlob(message) {
  const { data, ...rest } = message;
  assert.deepStrictEqual(Object.keys(data), [SEALED_FIELD]);
  assert.match(data[SEALED_FIELD], /^[A-Za-z0-9_-]+$/);
  return JSON.stringify(rest);
}

test('a keyed android token gets one sealed field and nothing that names anyone', () => {
  const { token } = keyedToken();
  const { message } = buildMessage({ token, platform: 'android', sender: SENDER, server: SERVER, channel: CHANNEL, mention: true });
  assert.strictEqual(message.token, 'fcm-token:APA91b_x-1');
  // No collapse key, tag or other grouping hint either.
  assert.deepStrictEqual(message.android, { priority: 'high' });
  const wire = outsideTheBlob(message);
  for (const id of [SENDER, SERVER, CHANNEL, 'channel_wake', 'mention', 'collapse']) assert.ok(!wire.includes(id), id);
  assert.ok(!JSON.stringify(message).includes(SENDER));
});

test('DM and channel blobs are the same length', () => {
  const { token } = keyedToken();
  const dm = buildMessage({ token, platform: 'android', sender: 'a'.repeat(52) }).message.data[SEALED_FIELD];
  const ch = buildMessage({
    token, platform: 'android', sender: 'a'.repeat(52), server: 'b'.repeat(40), channel: 'c'.repeat(36), mention: true,
  }).message.data[SEALED_FIELD];
  assert.strictEqual(dm.length, ch.length);
});

test('a keyed ios token keeps the generic alert and carries no collapse id', () => {
  const { token } = keyedToken();
  for (const wake of [{ sender: SENDER }, { sender: SENDER, server: SERVER, channel: CHANNEL, mention: false }, {}]) {
    const { message } = buildMessage({ token, platform: 'ios', ...wake });
    assert.deepStrictEqual(message.apns, {
      headers: { 'apns-priority': '10', 'apns-push-type': 'alert' },
      payload: {
        aps: { alert: { title: 'Hollow', body: 'New message' }, sound: 'default', 'mutable-content': 1, 'content-available': 1 },
      },
    });
    const wire = outsideTheBlob(message);
    for (const id of [SENDER, SERVER, CHANNEL, 'collapse', 'thread']) assert.ok(!wire.includes(id), id);
  }
});

test('a JSON token that is not a valid key set is refused, never sent to FCM as a token', () => {
  const ecdh = crypto.createECDH('prime256v1');
  ecdh.generateKeys();
  const good = { v: 2, fcm: 'tok', p256dh: b64u(ecdh.getPublicKey()), auth: b64u(crypto.randomBytes(16)) };
  for (const bad of [
    '{not json',
    JSON.stringify({ ...good, v: 3 }),
    JSON.stringify({ ...good, fcm: '' }),
    JSON.stringify({ ...good, fcm: 'has space' }),
    JSON.stringify({ ...good, fcm: 'x'.repeat(4097) }),
    JSON.stringify({ ...good, p256dh: b64u(Buffer.alloc(65, 1)) }),
    JSON.stringify({ ...good, p256dh: b64u(ecdh.getPublicKey()).slice(2) }),
    JSON.stringify({ ...good, auth: b64u(crypto.randomBytes(15)) }),
  ]) {
    assert.strictEqual(parseNativeToken(bad), null, bad.slice(0, 60));
    assert.deepStrictEqual(buildMessage({ token: bad, platform: 'android', sender: 'd' }), { error: 'bad_token' });
  }
  assert.deepStrictEqual(parseNativeToken('plain-token'), { fcm: 'plain-token', keys: null });
});
