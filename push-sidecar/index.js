const http = require('http');
const admin = require('firebase-admin');
const path = require('path');

const PORT = parseInt(process.env.PUSH_PORT || '3001', 10);
const KEY_PATH = process.env.FIREBASE_KEY_PATH || path.join(__dirname, 'service-account.json');

admin.initializeApp({
  credential: admin.credential.cert(KEY_PATH),
});

const server = http.createServer((req, res) => {
  if (req.method !== 'POST' || req.url !== '/push') {
    res.writeHead(404);
    res.end();
    return;
  }

  let body = '';
  req.on('data', chunk => { body += chunk; });
  req.on('end', async () => {
    try {
      const { token, platform, sender } = JSON.parse(body);
      if (!token) {
        res.writeHead(400);
        res.end('missing token');
        return;
      }

      const message = {
        token,
        data: { type: 'wake', ...(sender ? { sender } : {}) },
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
