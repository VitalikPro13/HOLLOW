const http = require('http');
const crypto = require('crypto');
const admin = require('firebase-admin');
const path = require('path');

const PORT = parseInt(process.env.PUSH_PORT || '3001', 10);
const KEY_PATH = process.env.FIREBASE_KEY_PATH || path.join(__dirname, 'service-account.json');
// Shared secret with the relay (relay side: HOLLOW_PUSH_TOKEN). This process
// holds the Firebase Admin credential, and binding to 127.0.0.1 only limits WHO
// can reach it, not who may use it — without a check, any local process could
// send arbitrary pushes to arbitrary device tokens. Unset = accept unauthenticated
// callers as before, so the relay and the sidecar can be deployed independently;
// set it on both sides to enforce.
const PUSH_TOKEN = process.env.PUSH_TOKEN || '';

// Constant-time compare that does not leak length via early return.
function tokenOk(supplied) {
  if (!PUSH_TOKEN) return true;
  const a = Buffer.from(String(supplied || ''), 'utf8');
  const b = Buffer.from(PUSH_TOKEN, 'utf8');
  if (a.length !== b.length) return false;
  return crypto.timingSafeEqual(a, b);
}

// A token mismatch between relay and sidecar would kill EVERY push silently,
// which is indistinguishable from "nobody is offline". Log the fact of a
// rejection (never the caller, the supplied value, or any peer data) so the
// misconfiguration is visible in journalctl. Throttled to once a minute so a
// hostile local process cannot flood the journal.
let rejectedSinceLog = 0;
let lastRejectLog = 0;
function noteRejected() {
  rejectedSinceLog++;
  const now = Date.now();
  if (now - lastRejectLog < 60_000) return;
  lastRejectLog = now;
  console.error(
    `[push-sidecar] rejected ${rejectedSinceLog} unauthenticated push(es) in the last minute — ` +
    `if pushes have stopped working, check that HOLLOW_PUSH_TOKEN (relay) matches PUSH_TOKEN (sidecar)`
  );
  rejectedSinceLog = 0;
}

admin.initializeApp({
  credential: admin.credential.cert(KEY_PATH),
});

// Deterministic 31-bit hash of a peer_id, reproduced byte-for-byte in Dart
// (push_notification_service.dart `_iosCollapseId`). Used as the iOS
// apns-collapse-id so the APNs/NSE banner gets a notification identifier the
// Dart background handler can later target with `cancel(id)` to remove it and
// post a single content banner in its place. FNV-1a, masked to 31 bits so it
// fits a Dart/Swift signed int and stays positive. NOT for security — only a
// stable cross-language id. MUST stay in sync with the Dart copy.
function iosCollapseId(peerId) {
  let h = 0x811c9dc5; // FNV offset basis
  for (let i = 0; i < peerId.length; i++) {
    h ^= peerId.charCodeAt(i) & 0xff;
    h = Math.imul(h, 0x01000193) >>> 0; // FNV prime, keep unsigned 32-bit
  }
  return (h & 0x7fffffff).toString(); // 31-bit positive, as a string
}

const server = http.createServer((req, res) => {
  if (req.method !== 'POST' || req.url !== '/push') {
    res.writeHead(404);
    res.end();
    return;
  }

  if (!tokenOk(req.headers['x-push-token'])) {
    // No detail in the body and nothing logged about the caller — a rejected
    // push says only that it was rejected.
    noteRejected();
    res.writeHead(401);
    res.end('unauthorized');
    return;
  }

  let body = '';
  req.on('data', chunk => { body += chunk; });
  req.on('end', async () => {
    try {
      const { token, platform, sender, server, channel, mention } = JSON.parse(body);
      if (!token) {
        res.writeHead(400);
        res.end('missing token');
        return;
      }

      // Channel pushes (server set) carry the opaque server/channel ids so the
      // on-device handler can resolve names + check local notification settings
      // — same exposure class as the sender peer_id, never any content.
      const isChannel = !!server;
      const message = {
        token,
        data: isChannel
          ? {
              type: 'channel_wake',
              ...(sender ? { sender } : {}),
              server,
              ...(channel ? { channel } : {}),
              mention: mention ? '1' : '0', // FCM data values must be strings
            }
          : { type: 'wake', ...(sender ? { sender } : {}) },
      };

      if (platform === 'android') {
        message.android = { priority: 'high' };
      } else if (platform === 'ios') {
        // VISIBLE alert push (priority 10), NOT a pure silent background push.
        // Pure content-available:1 pushes are throttled/dropped by iOS by design
        // ("opportunities, not guarantees", ~2-3/hr) — unusable for a messenger.
        // A priority-10 alert with apns-push-type:alert is delivered immediately
        // and is not throttled.
        //
        // Privacy: the alert body is a GENERIC "New message" with ZERO metadata
        // (no sender, no content) — Apple/APNs never see who or what. The real
        // sender/text/image are filled in on-device:
        //   - mutable-content:1 → a Notification Service Extension can rewrite
        //     title/body + attach the image before display (rich, like Android).
        //   - content-available:1 → also wakes the Dart bg handler (Tier 2) to
        //     persist the decrypted message to the DB so it's present on open.
        // The `sender` peer_id rides in the data block (already E2E-opaque) for
        // the on-device handler/extension to resolve the cached profile.
        message.apns = {
          headers: {
            'apns-priority': '10',
            'apns-push-type': 'alert',
            // Collapse all pushes from the same sender into ONE notification on
            // device, keyed by the (E2E-opaque) peer_id. This is what makes the
            // two iOS notification systems converge instead of stacking:
            //   1. the APNs alert banner (shown on delivery),
            //   2. the NSE rewrite (name + avatar, mutable-content:1),
            //   3. the Dart bg handler's local notification (decrypted content).
            // The collapse-id is a deterministic 31-bit hash of the sender
            // peer_id (NOT the raw peer_id) so it doubles as the iOS
            // notification IDENTIFIER that the Dart background handler can target
            // with flutter_local_notifications `cancel(id)` — the plugin removes
            // delivered notifications by stringified integer id, so the id must
            // be an integer both sides compute identically (see iosCollapseId /
            // the Dart `_iosCollapseId`). Flow: this alert banner shows name +
            // avatar instantly (grabs attention) → Dart fetches+decrypts the
            // message → Dart cancels THIS notification by the same id and posts
            // ONE silent content banner under the same threadIdentifier (sender).
            // Result: a single per-peer banner that swaps generic → real content,
            // never two stacked. Only set when we have a sender (generic wake
            // has none).
            //
            // Channel pushes collapse by "server:channel" instead — one banner
            // per channel that newer pushes replace (matched in Dart/NSE).
            ...(isChannel
              ? { 'apns-collapse-id': iosCollapseId(`${server}:${channel || ''}`) }
              : sender ? { 'apns-collapse-id': iosCollapseId(sender) } : {}),
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

      const msgId = await admin.messaging().send(message);
      console.log(`[push-sidecar] sent platform=${platform || '?'} token=${String(token).slice(0, 12)}… id=${msgId}`);
      res.writeHead(200);
      res.end('ok');
    } catch (err) {
      const code = err.code || '';
      if (code === 'messaging/registration-token-not-registered' ||
          code === 'messaging/invalid-registration-token') {
        console.error(`[push-sidecar] token expired platform=${platform || '?'} token=${String(token).slice(0, 12)}…`);
        res.writeHead(410);
        res.end('token_expired');
      } else {
        console.error(`[push-sidecar] FCM error platform=${platform || '?'} code=${code} msg=${err.message || err}`);
        res.writeHead(500);
        res.end('error');
      }
    }
  });
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`[push-sidecar] listening on 127.0.0.1:${PORT}`);
});
