<?php
// Hollow — IGDB game search with a full write-through cache.
//
// The ONLY place the Twitch/IGDB app credential lives. Hollow clients call
// this at AUTHORING time (composing a showcase board). EVERYTHING is cached
// on our side: covers into ./covers/ as static files, and all game METADATA
// (title, year, type, genres, rating, summary) into a local SQLite DB
// (games.db) keyed per game, plus a search→results index. A repeated or
// previously-seen search is answered from OUR database with ZERO IGDB
// traffic — the 4 req/s app cap only ever sees brand-new searches.
// Display in the app is pure P2P off replicated profile data: viewers
// never hit this endpoint, IGDB, or anything else.
//
// Deploy: upload this folder to /public_html/hollow/igdb/ (config.php holds
// the real credentials and is NOT in git — see config.php.example).

declare(strict_types=1);
require __DIR__ . '/config.php'; // defines IGDB_CLIENT_ID, IGDB_CLIENT_SECRET

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');

const COVERS_DIR = __DIR__ . '/covers';
const COVERS_URL = 'https://hollow.anonlisten.com/igdb/covers/';
const TOKEN_FILE = __DIR__ . '/token.json';
const DB_FILE    = __DIR__ . '/games.db';
const SEARCH_TTL = 30 * 24 * 3600; // re-ask IGDB for a query after 30 days
// Bump when the response schema grows — cached searches from older versions
// refetch so new fields (e.g. `type`) backfill instead of serving nulls.
const SEARCH_VER = 2;

// IGDB legacy `category` enum → human tag (fallback; `game_type.type` is
// the current source — `category` is deprecated and returns empty).
const GAME_TYPES = [
    0 => 'Main Game', 1 => 'DLC', 2 => 'Expansion', 3 => 'Bundle',
    4 => 'Standalone', 5 => 'Mod', 6 => 'Episode', 7 => 'Season',
    8 => 'Remake', 9 => 'Remaster', 10 => 'Expanded Game', 11 => 'Port',
    12 => 'Fork', 13 => 'Pack', 14 => 'Update',
];

// Shorten IGDB's game_type strings to chip-sized tags.
const TYPE_SHORT = [
    'DLC / Addon' => 'DLC',
    'Standalone Expansion' => 'Standalone',
    'Expanded Game' => 'Expanded',
];

function fail(int $code, string $msg): void {
    http_response_code($code);
    echo json_encode(['error' => $msg]);
    exit;
}

function db(): PDO {
    static $pdo = null;
    if ($pdo === null) {
        $pdo = new PDO('sqlite:' . DB_FILE);
        $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
        $pdo->exec('PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;');
        $pdo->exec('CREATE TABLE IF NOT EXISTS games (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            year INTEGER,
            type TEXT,
            cover_image_id TEXT,
            genres TEXT,
            rating INTEGER,
            summary TEXT,
            fetched_at INTEGER NOT NULL
        )');
        $pdo->exec('CREATE TABLE IF NOT EXISTS searches (
            q TEXT PRIMARY KEY,
            game_ids TEXT NOT NULL,
            fetched_at INTEGER NOT NULL
        )');
        // Additive migration (idempotent — duplicate-column errors ignored).
        try { $pdo->exec('ALTER TABLE searches ADD COLUMN ver INTEGER NOT NULL DEFAULT 0'); } catch (Throwable $e) {}
    }
    return $pdo;
}

function curl_req(string $url, array $headers = [], ?string $post = null): ?string {
    $ch = curl_init($url);
    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT        => 15,
        CURLOPT_HTTPHEADER     => $headers,
        CURLOPT_FOLLOWLOCATION => true,
        CURLOPT_MAXREDIRS      => 3,
    ]);
    if ($post !== null) {
        curl_setopt($ch, CURLOPT_POST, true);
        curl_setopt($ch, CURLOPT_POSTFIELDS, $post);
    }
    $body = curl_exec($ch);
    $status = curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
    curl_close($ch);
    if ($body === false || $status < 200 || $status >= 300) return null;
    return $body;
}

function app_token(): string {
    // Cached client_credentials token (~60 day expiry; refresh at T-1h).
    if (is_file(TOKEN_FILE)) {
        $t = json_decode((string)file_get_contents(TOKEN_FILE), true);
        if (is_array($t) && ($t['expires_at'] ?? 0) > time() + 3600) {
            return $t['access_token'];
        }
    }
    $resp = curl_req(
        'https://id.twitch.tv/oauth2/token'
        . '?client_id=' . urlencode(IGDB_CLIENT_ID)
        . '&client_secret=' . urlencode(IGDB_CLIENT_SECRET)
        . '&grant_type=client_credentials',
        [], ''
    );
    $j = $resp !== null ? json_decode($resp, true) : null;
    if (!is_array($j) || empty($j['access_token'])) {
        fail(502, 'igdb_auth_failed');
    }
    @file_put_contents(TOKEN_FILE, json_encode([
        'access_token' => $j['access_token'],
        'expires_at'   => time() + (int)($j['expires_in'] ?? 0),
    ]), LOCK_EX);
    return $j['access_token'];
}

/// Ensure the cover for $imageId sits in ./covers/; return its URL or null.
function cached_cover(?string $imageId): ?string {
    if (!is_string($imageId) || !preg_match('/^[a-z0-9]+$/i', $imageId)) {
        return null;
    }
    $local = COVERS_DIR . "/$imageId.jpg";
    if (!is_file($local)) {
        if (!is_dir(COVERS_DIR)) @mkdir(COVERS_DIR, 0755, true);
        $img = curl_req("https://images.igdb.com/igdb/image/upload/t_cover_big/$imageId.jpg");
        if ($img !== null && strlen($img) > 0 && strlen($img) < 2_000_000) {
            @file_put_contents($local, $img, LOCK_EX);
        }
    }
    return is_file($local) ? COVERS_URL . "$imageId.jpg" : null;
}

function game_row_to_json(array $row): array {
    return [
        'id'      => (int)$row['id'],
        'name'    => (string)$row['name'],
        'year'    => $row['year'] !== null ? (int)$row['year'] : null,
        'type'    => $row['type'] !== null && $row['type'] !== '' ? (string)$row['type'] : null,
        'cover'   => cached_cover($row['cover_image_id'] ?? null),
        'genres'  => json_decode((string)($row['genres'] ?? '[]'), true) ?: [],
        'rating'  => $row['rating'] !== null ? (int)$row['rating'] : null,
        'summary' => $row['summary'] !== null && $row['summary'] !== '' ? (string)$row['summary'] : null,
    ];
}

$q = trim((string)($_GET['q'] ?? ''));
if ($q === '' || mb_strlen($q) > 100) {
    echo '[]';
    exit;
}
// Normalized cache key: case/whitespace variants share one entry.
$qkey = mb_strtolower(preg_replace('/\s+/', ' ', $q));

$pdo = db();

// ── 1. Serve from OUR database when we've seen this search before. ──
$stmt = $pdo->prepare('SELECT game_ids, fetched_at, ver FROM searches WHERE q = ?');
$stmt->execute([$qkey]);
$hit = $stmt->fetch(PDO::FETCH_ASSOC);
if ($hit && (int)$hit['ver'] === SEARCH_VER
        && (int)$hit['fetched_at'] > time() - SEARCH_TTL) {
    $ids = json_decode((string)$hit['game_ids'], true) ?: [];
    $out = [];
    if ($ids) {
        $ph = implode(',', array_fill(0, count($ids), '?'));
        $g = $pdo->prepare("SELECT * FROM games WHERE id IN ($ph)");
        $g->execute($ids);
        $byId = [];
        foreach ($g->fetchAll(PDO::FETCH_ASSOC) as $row) {
            $byId[(int)$row['id']] = $row;
        }
        foreach ($ids as $id) { // preserve IGDB's relevance order
            if (isset($byId[(int)$id])) $out[] = game_row_to_json($byId[(int)$id]);
        }
    }
    echo json_encode($out);
    exit;
}

// ── 2. Cache miss → ONE IGDB query, then persist everything. ──
$token = app_token();
$body = 'search "' . str_replace(['\\', '"'], ['\\\\', '\\"'], $q) . '"; '
      . 'fields name,cover.image_id,first_release_date,game_type.type,category,genres.name,total_rating,summary; '
      . 'limit 12;';
$resp = curl_req('https://api.igdb.com/v4/games', [
    'Client-ID: ' . IGDB_CLIENT_ID,
    'Authorization: Bearer ' . $token,
    'Accept: application/json',
], $body);
if ($resp === null) fail(502, 'igdb_query_failed');
$games = json_decode($resp, true);
if (!is_array($games)) fail(502, 'igdb_bad_response');

$upsert = $pdo->prepare('INSERT INTO games (id, name, year, type, cover_image_id, genres, rating, summary, fetched_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET
        name=excluded.name, year=excluded.year, type=excluded.type,
        cover_image_id=excluded.cover_image_id, genres=excluded.genres,
        rating=excluded.rating, summary=excluded.summary,
        fetched_at=excluded.fetched_at');

$out = [];
$ids = [];
$now = time();
foreach ($games as $g) {
    if (!is_array($g) || empty($g['name']) || empty($g['id'])) continue;
    $id = (int)$g['id'];
    $year = isset($g['first_release_date']) ? (int)gmdate('Y', (int)$g['first_release_date']) : null;
    // Current source: game_type expander; legacy category as fallback.
    $type = null;
    if (!empty($g['game_type']['type']) && is_string($g['game_type']['type'])) {
        $type = TYPE_SHORT[$g['game_type']['type']] ?? $g['game_type']['type'];
    } elseif (isset($g['category'])) {
        $type = GAME_TYPES[(int)$g['category']] ?? null;
    }
    $imageId = $g['cover']['image_id'] ?? null;
    $genres = [];
    foreach (($g['genres'] ?? []) as $gen) {
        if (!empty($gen['name'])) $genres[] = (string)$gen['name'];
    }
    $rating = isset($g['total_rating']) ? (int)round((float)$g['total_rating']) : null;
    $summary = isset($g['summary']) ? mb_substr((string)$g['summary'], 0, 1000) : null;

    $upsert->execute([
        $id, (string)$g['name'], $year, $type,
        is_string($imageId) ? $imageId : null,
        json_encode($genres), $rating, $summary, $now,
    ]);
    $ids[] = $id;
    $out[] = [
        'id'      => $id,
        'name'    => (string)$g['name'],
        'year'    => $year,
        'type'    => $type,
        'cover'   => cached_cover(is_string($imageId) ? $imageId : null),
        'genres'  => $genres,
        'rating'  => $rating,
        'summary' => $summary,
    ];
}

$pdo->prepare('INSERT INTO searches (q, game_ids, fetched_at, ver) VALUES (?, ?, ?, ?)
    ON CONFLICT(q) DO UPDATE SET game_ids=excluded.game_ids, fetched_at=excluded.fetched_at, ver=excluded.ver')
    ->execute([$qkey, json_encode($ids), $now, SEARCH_VER]);

echo json_encode($out);
