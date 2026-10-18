const crypto = require('crypto');
const webpush = require('web-push');

// The one data field a sealed wake carries (AR-26). The app registers its FCM or APNs
// token as {v:2, fcm, p256dh, auth}; a bare token is a 0.12.1 client and gets the plain
// payload it was built for.
const SEALED_FIELD = 'sealed';
const MAX_FCM_TOKEN = 4096;
const FCM_TOKEN = /^[A-Za-z0-9_:.-]+$/;
const B64URL = /^[A-Za-z0-9_-]+$/;
// Every sealed wake is padded to this many bytes, so its length tells a DM from a
// channel wake no more than its content does.
const PAD_TO = 512;

// Deterministic 31-bit hash of a peer_id, reproduced byte-for-byte in Dart
// (push_notification_service.dart `_iosCollapseId`): a 0.12.1 phone cancels the APNs
// banner by it. FNV-1a, masked to 31 bits so it fits a signed int. NOT for security.
function iosCollapseId(peerId) {
  let h = 0x811c9dc5;
  for (let i = 0; i < peerId.length; i++) {
    h ^= peerId.charCodeAt(i) & 0xff;
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return (h & 0x7fffffff).toString();
}

function decodeKey(value, length) {
  if (typeof value !== 'string' || !B64URL.test(value)) return null;
  const buf = Buffer.from(value, 'base64url');
  return buf.length === length && buf.toString('base64url') === value ? buf : null;
}

function isCurvePoint(raw) {
  if (raw[0] !== 0x04) return false;
  try {
    crypto.createPublicKey({
      key: { kty: 'EC', crv: 'P-256', x: raw.subarray(1, 33).toString('base64url'), y: raw.subarray(33).toString('base64url') },
      format: 'jwk',
    });
    return true;
  } catch (_) {
    return false;
  }
}

// {fcm, keys} for a token the relay forwarded, or null when it is JSON that is not a
// valid key set (never handed to FCM as a token).
function parseNativeToken(token) {
  if (typeof token !== 'string' || token.length === 0) return null;
  if (!token.startsWith('{')) return { fcm: token, keys: null };
  let t;
  try {
    t = JSON.parse(token);
  } catch (_) {
    return null;
  }
  if (!t || t.v !== 2) return null;
  const { fcm } = t;
  if (typeof fcm !== 'string' || fcm.length === 0 || fcm.length > MAX_FCM_TOKEN || !FCM_TOKEN.test(fcm)) return null;
  const p256dh = decodeKey(t.p256dh, 65);
  const auth = decodeKey(t.auth, 16);
  if (!p256dh || !auth || !isCurvePoint(p256dh)) return null;
  return { fcm, keys: { p256dh: t.p256dh, auth: t.auth } };
}

// The wake fields the relay supplies, as FCM data strings.
function wakeData({ sender, server, channel, mention }) {
  return server
    ? {
        type: 'channel_wake',
        ...(sender ? { sender } : {}),
        server,
        ...(channel ? { channel } : {}),
        mention: mention ? '1' : '0',
      }
    : { type: 'wake', ...(sender ? { sender } : {}) };
}

function seal(keys, inner) {
  const json = JSON.stringify(inner);
  const size = json.length <= PAD_TO ? PAD_TO : Math.ceil(json.length / 128) * 128;
  // JSON allows trailing whitespace, so the padding needs no framing of its own.
  const { cipherText } = webpush.encrypt(keys.p256dh, keys.auth, json.padEnd(size, ' '), 'aes128gcm');
  return cipherText.toString('base64url');
}

// VISIBLE alert push (priority 10), not a silent background push, which iOS throttles
// to a few an hour. The alert is generic; mutable-content lets the extension fill it in
// on the device, content-available wakes the Dart handler.
function apnsBlock(collapseId) {
  return {
    headers: {
      'apns-priority': '10',
      'apns-push-type': 'alert',
      ...(collapseId ? { 'apns-collapse-id': collapseId } : {}),
    },
    payload: {
      aps: {
        alert: { title: 'Hollow', body: 'New message' },
        sound: 'default',
        'mutable-content': 1,
        'content-available': 1,
      },
    },
  };
}

// The firebase-admin message for one wake, or {error} for a token that cannot carry one.
function buildMessage({ token, platform, sender, server, channel, mention }, now = Date.now()) {
  const parsed = parseNativeToken(token);
  if (!parsed) return { error: 'bad_token' };
  const data = wakeData({ sender, server, channel, mention });
  // One banner per sender, or per channel, replaced by newer wakes.
  const collapseKey = server ? `${server}:${channel || ''}` : sender || '';

  if (!parsed.keys) {
    const message = { token: parsed.fcm, data };
    if (platform === 'android') message.android = { priority: 'high' };
    else if (platform === 'ios') message.apns = apnsBlock(collapseKey ? iosCollapseId(collapseKey) : null);
    return { message };
  }

  // The seal time lets the phone refuse a blob delivered again later. Grouping and
  // replacing banners happen on the phone, so Apple gets no collapse id to link
  // wakes of one conversation.
  const inner = { ...data, ts: Math.floor(now / 1000) };
  const message = { token: parsed.fcm, data: { [SEALED_FIELD]: seal(parsed.keys, inner) } };
  if (platform === 'android') message.android = { priority: 'high' };
  else if (platform === 'ios') message.apns = apnsBlock(null);
  return { message };
}

module.exports = { buildMessage, parseNativeToken, wakeData, iosCollapseId, SEALED_FIELD, PAD_TO };
