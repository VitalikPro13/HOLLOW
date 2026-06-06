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
        message.apns = {
          headers: {
            'apns-priority': '10',
            'apns-push-type': 'background',
          },
          payload: {
            aps: { 'content-available': 1 },
          },
        };
      }

      await admin.messaging().send(message);
      res.writeHead(200);
      res.end('ok');
    } catch (err) {
      const code = err.code || '';
      if (code === 'messaging/registration-token-not-registered' ||
          code === 'messaging/invalid-registration-token') {
        res.writeHead(410);
        res.end('token_expired');
      } else {
        console.error('[push-sidecar] FCM error:', err.message || err);
        res.writeHead(500);
        res.end('error');
      }
    }
  });
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`[push-sidecar] listening on 127.0.0.1:${PORT}`);
});
