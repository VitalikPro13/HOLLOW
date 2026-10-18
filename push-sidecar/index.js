const http = require('http');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { sendUnifiedPush } = require('./unifiedpush');
const { buildMessage, wakeData } = require('./fcm');

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

// Firebase is optional: a self-hosted relay has no service account, and its
// UnifiedPush sends must still work. firebase-admin is an optional dependency
// for the same reason, so it is required only when the key exists.
let admin = null;
if (fs.existsSync(KEY_PATH)) {
  admin = require('firebase-admin');
  admin.initializeApp({ credential: admin.credential.cert(KEY_PATH) });
} else {
  console.log('[push-sidecar] no Firebase service account, FCM/APNs disabled (UnifiedPush only)');
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
    let token;
    let platform;
    try {
      const parsed = JSON.parse(body);
      ({ token, platform } = parsed);
      if (!token) {
        res.writeHead(400);
        res.end('missing token');
        return;
      }

      if (platform === 'unifiedpush') {
        const { status, code } = await sendUnifiedPush(token, wakeData(parsed));
        res.writeHead(status);
        res.end(code);
        return;
      }

      if (!admin) {
        res.writeHead(503);
        res.end('fcm_disabled');
        return;
      }

      // Plain 0.12.1 tokens get the ids in the clear; keyed tokens one sealed field
      // (fcm.js). The ids are E2E-opaque but map who writes to whom.
      const { message, error } = buildMessage(parsed);
      if (error) {
        res.writeHead(400);
        res.end(error);
        return;
      }

      await admin.messaging().send(message);
      // No logging - a sent push says when someone was sent a message.
      res.writeHead(200);
      res.end('ok');
    } catch (err) {
      const code = err.code || '';
      if (code === 'messaging/registration-token-not-registered' ||
          code === 'messaging/invalid-registration-token') {
        console.error(`[push-sidecar] token expired platform=${platform || '?'}`);
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
