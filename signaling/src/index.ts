// Haven Signaling Service — Cloudflare Worker
//
// A lightweight phone book: maps a room code to a list of online peer addresses.
// Once peers connect via libp2p, Kademlia DHT handles everything — this service
// is only needed for the initial bootstrap.

interface Env {
  PEERS: KVNamespace;
}

interface PeerEntry {
  peer_id: string;
  addresses: string[];
  last_seen: number;
}

interface RegisterRequest {
  room_code: string;
  peer_id: string;
  addresses: string[];
  timestamp: number;
  public_key: string; // base64 protobuf-encoded Ed25519 public key
  signature: string; // base64 Ed25519 signature
}

const MAX_PEERS_PER_ROOM = 50;
const MAX_ADDRS_PER_PEER = 5;
const STALE_THRESHOLD_SECS = 600; // 10 minutes
const KV_TTL_SECS = 86400; // 24 hours (garbage collection backstop)
const TIMESTAMP_SKEW_SECS = 300; // 5 minutes anti-replay window

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type",
};

function jsonResponse(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json", ...CORS_HEADERS },
  });
}

function errorResponse(message: string, status: number): Response {
  return jsonResponse({ error: message }, status);
}

/** Extract 32-byte raw Ed25519 public key from base64 libp2p protobuf encoding. */
function extractEd25519PublicKey(base64PubKey: string): Uint8Array {
  const raw = Uint8Array.from(atob(base64PubKey), (c) => c.charCodeAt(0));
  if (raw.length !== 36) {
    throw new Error(`Expected 36-byte protobuf key, got ${raw.length}`);
  }
  // Header: 08 01 12 20 = Ed25519 type + 32-byte length
  if (
    raw[0] !== 0x08 ||
    raw[1] !== 0x01 ||
    raw[2] !== 0x12 ||
    raw[3] !== 0x20
  ) {
    throw new Error("Not a valid Ed25519 protobuf public key");
  }
  return raw.slice(4);
}

/** Verify Ed25519 signature using Web Crypto API. */
async function verifySignature(
  publicKeyBase64: string,
  signatureBase64: string,
  message: string
): Promise<boolean> {
  try {
    const rawKey = extractEd25519PublicKey(publicKeyBase64);
    const key = await crypto.subtle.importKey(
      "raw",
      rawKey,
      { name: "Ed25519" },
      false,
      ["verify"]
    );
    const sig = Uint8Array.from(atob(signatureBase64), (c) => c.charCodeAt(0));
    const data = new TextEncoder().encode(message);
    return await crypto.subtle.verify("Ed25519", key, sig, data);
  } catch {
    return false;
  }
}

/** Filter out stale peers and enforce caps. */
function filterFresh(peers: PeerEntry[], nowSecs: number): PeerEntry[] {
  return peers.filter((p) => nowSecs - p.last_seen < STALE_THRESHOLD_SECS);
}

async function handleRegister(
  request: Request,
  env: Env
): Promise<Response> {
  let body: RegisterRequest;
  try {
    body = await request.json();
  } catch {
    return errorResponse("Invalid JSON body", 400);
  }

  const { room_code, peer_id, addresses, timestamp, public_key, signature } =
    body;

  // Validate required fields.
  if (!room_code || !peer_id || !addresses || !timestamp || !public_key || !signature) {
    return errorResponse("Missing required fields", 400);
  }

  if (typeof room_code !== "string" || room_code.length < 1 || room_code.length > 64) {
    return errorResponse("Invalid room_code", 400);
  }

  if (!Array.isArray(addresses) || addresses.length === 0) {
    return errorResponse("addresses must be a non-empty array", 400);
  }

  // Anti-replay: timestamp must be within 5 minutes.
  const nowSecs = Math.floor(Date.now() / 1000);
  if (Math.abs(nowSecs - timestamp) > TIMESTAMP_SKEW_SECS) {
    return errorResponse("Timestamp too far from server time", 403);
  }

  // Verify Ed25519 signature.
  const addrsJoined = addresses.slice(0, MAX_ADDRS_PER_PEER).join(",");
  const signedMessage = `haven-register:${room_code}:${peer_id}:${addrsJoined}:${timestamp}`;

  const valid = await verifySignature(public_key, signature, signedMessage);
  if (!valid) {
    return errorResponse("Invalid signature", 403);
  }

  // Read existing room data.
  const kvKey = `room:${room_code}`;
  const existing = await env.PEERS.get<PeerEntry[]>(kvKey, "json");
  let peers = existing ? filterFresh(existing, nowSecs) : [];

  // Upsert this peer.
  const trimmedAddrs = addresses.slice(0, MAX_ADDRS_PER_PEER);
  const idx = peers.findIndex((p) => p.peer_id === peer_id);
  if (idx >= 0) {
    peers[idx] = {
      peer_id,
      addresses: trimmedAddrs,
      last_seen: nowSecs,
    };
  } else {
    if (peers.length >= MAX_PEERS_PER_ROOM) {
      // Evict oldest peer.
      peers.sort((a, b) => a.last_seen - b.last_seen);
      peers.shift();
    }
    peers.push({
      peer_id,
      addresses: trimmedAddrs,
      last_seen: nowSecs,
    });
  }

  // Write back to KV.
  await env.PEERS.put(kvKey, JSON.stringify(peers), {
    expirationTtl: KV_TTL_SECS,
  });

  return jsonResponse({ ok: true, peers_in_room: peers.length });
}

async function handleBootstrap(
  roomCode: string,
  env: Env
): Promise<Response> {
  if (!roomCode || roomCode.length > 64) {
    return errorResponse("Invalid room code", 400);
  }

  const kvKey = `room:${roomCode}`;
  const existing = await env.PEERS.get<PeerEntry[]>(kvKey, "json");

  if (!existing || existing.length === 0) {
    return jsonResponse({ peers: [] });
  }

  const nowSecs = Math.floor(Date.now() / 1000);
  const fresh = filterFresh(existing, nowSecs);

  // Return up to 10 peers.
  const result = fresh.slice(0, 10).map((p) => ({
    peer_id: p.peer_id,
    addresses: p.addresses,
  }));

  return jsonResponse({ peers: result });
}

function handleHealth(): Response {
  return jsonResponse({ status: "ok", service: "haven-signaling" });
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    // Handle CORS preflight.
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: CORS_HEADERS });
    }

    const url = new URL(request.url);
    const path = url.pathname;

    // POST /register
    if (request.method === "POST" && path === "/register") {
      return handleRegister(request, env);
    }

    // GET /bootstrap/{room_code}
    if (request.method === "GET" && path.startsWith("/bootstrap/")) {
      const roomCode = decodeURIComponent(path.slice("/bootstrap/".length));
      return handleBootstrap(roomCode, env);
    }

    // GET /health
    if (request.method === "GET" && path === "/health") {
      return handleHealth();
    }

    return errorResponse("Not found", 404);
  },
};
