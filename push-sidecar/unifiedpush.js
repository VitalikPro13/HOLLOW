const dns = require('dns');
const https = require('https');
const net = require('net');
const webpush = require('web-push');

// The relay forwards whatever endpoint a client registered, so without these
// limits the sidecar would POST to any URL a client names, including hosts
// inside this machine's network.
const MAX_TOKEN_LEN = 2048;
const MAX_ENDPOINT_LEN = 1024;
const ALLOW_PRIVATE = process.env.UNIFIEDPUSH_ALLOW_PRIVATE === '1';
// Matches the relay's offline buffer: a wake older than that finds nothing.
const TTL_SECS = 24 * 60 * 60;
const TIMEOUT_MS = 5000;

const vapidDetails =
  process.env.VAPID_PUBLIC_KEY && process.env.VAPID_PRIVATE_KEY && process.env.VAPID_SUBJECT
    ? {
        subject: process.env.VAPID_SUBJECT,
        publicKey: process.env.VAPID_PUBLIC_KEY,
        privateKey: process.env.VAPID_PRIVATE_KEY,
      }
    : null;

const blocked = new net.BlockList();
for (const [addr, prefix] of [
  ['0.0.0.0', 8], ['10.0.0.0', 8], ['100.64.0.0', 10], ['127.0.0.0', 8],
  ['169.254.0.0', 16], ['172.16.0.0', 12], ['192.0.0.0', 24], ['192.0.2.0', 24],
  ['192.168.0.0', 16], ['198.18.0.0', 15], ['198.51.100.0', 24], ['203.0.113.0', 24],
  ['224.0.0.0', 4], ['240.0.0.0', 4],
]) blocked.addSubnet(addr, prefix, 'ipv4');
for (const [addr, prefix] of [
  ['::', 128], ['::1', 128], ['64:ff9b::', 96], ['100::', 64], ['2001:db8::', 32],
  ['fc00::', 7], ['fe80::', 10], ['ff00::', 8],
]) blocked.addSubnet(addr, prefix, 'ipv6');

function isPublicAddress(address, family) {
  if (family === 6 || family === 'IPv6') {
    // An IPv4-mapped address is judged as the IPv4 address it carries.
    const mapped = /^::ffff:(\d+\.\d+\.\d+\.\d+)$/i.exec(address);
    if (mapped) return !blocked.check(mapped[1], 'ipv4');
    return !blocked.check(address, 'ipv6');
  }
  return !blocked.check(address, 'ipv4');
}

// Filters inside the socket's own resolution, so the address that is checked
// is the address that is connected to.
function guardedLookup(hostname, options, callback) {
  dns.lookup(hostname, { ...options, all: true }, (err, addresses) => {
    if (err) return callback(err);
    const allowed = ALLOW_PRIVATE
      ? addresses
      : addresses.filter(a => isPublicAddress(a.address, a.family));
    if (allowed.length === 0) {
      const e = new Error('endpoint resolves to a non-public address');
      e.code = 'ENDPOINT_NOT_PUBLIC';
      return callback(e);
    }
    if (options.all) return callback(null, allowed);
    callback(null, allowed[0].address, allowed[0].family);
  });
}

const agent = new https.Agent({ lookup: guardedLookup, keepAlive: true, maxSockets: 16 });

const B64URL = /^[A-Za-z0-9_-]+={0,2}$/;

// Parses the app's registration, or null when anything is missing or off.
function parseToken(token) {
  if (typeof token !== 'string' || token.length > MAX_TOKEN_LEN) return null;
  let t;
  try {
    t = JSON.parse(token);
  } catch (_) {
    return null;
  }
  if (!t || t.v !== 1) return null;
  const { endpoint, p256dh, auth } = t;
  if (typeof endpoint !== 'string' || endpoint.length > MAX_ENDPOINT_LEN) return null;
  if (typeof p256dh !== 'string' || !B64URL.test(p256dh) || p256dh.length > 128) return null;
  if (typeof auth !== 'string' || !B64URL.test(auth) || auth.length > 64) return null;
  let url;
  try {
    url = new URL(endpoint);
  } catch (_) {
    return null;
  }
  if (url.protocol !== 'https:' || url.username || url.password) return null;
  // Sockets skip the lookup for an IP literal, so the guard runs here too.
  const literal = url.hostname.replace(/^\[|\]$/g, '');
  const family = net.isIP(literal);
  if (family && !ALLOW_PRIVATE && !isPublicAddress(literal, family)) return null;
  return { url, subscription: { endpoint, keys: { p256dh, auth } } };
}

// Encrypts [data] to the device's key set and posts it to its endpoint.
// Resolves to the HTTP status and body code the relay gets back.
async function sendUnifiedPush(token, data) {
  const parsed = parseToken(token);
  if (!parsed) return { status: 400, code: 'bad_unifiedpush_token' };
  // The path is the device's private address on the push server; only the
  // host is ever logged.
  const host = parsed.url.host;
  try {
    const r = await webpush.sendNotification(parsed.subscription, JSON.stringify(data), {
      TTL: TTL_SECS,
      urgency: 'high',
      contentEncoding: 'aes128gcm',
      vapidDetails,
      agent,
      timeout: TIMEOUT_MS,
    });
    console.log(`[push-sidecar] sent platform=unifiedpush host=${host} status=${r.statusCode}`);
    return { status: 200, code: 'ok' };
  } catch (err) {
    if (err.statusCode === 404 || err.statusCode === 410) {
      console.error(`[push-sidecar] endpoint gone platform=unifiedpush host=${host} status=${err.statusCode}`);
      return { status: 410, code: 'token_expired' };
    }
    if (err.code === 'ENDPOINT_NOT_PUBLIC') {
      console.error(`[push-sidecar] refused platform=unifiedpush host=${host} (non-public address)`);
      return { status: 400, code: 'endpoint_not_public' };
    }
    console.error(
      `[push-sidecar] UnifiedPush error host=${host} status=${err.statusCode || '-'} msg=${err.message || err}`
    );
    return { status: 502, code: 'error' };
  }
}

module.exports = { sendUnifiedPush, parseToken, isPublicAddress };
