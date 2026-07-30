<?php
// Hollow — GIF + sticker search proxy (Klipy upstream), fully write-through
// cached. POST only (GET rejected — keeps search text out of access logs).
// THREE MODES:
//
//   q=<text>     Search. Rows cached 24 h per (kind, query, rating, page).
//   trending=1   Trending grid (the picker's default view). Cached 1 h.
//   categories=1 Category names. Cached 7 d.
//
// Common params: kind (gifs|stickers, default gifs — absent means gifs so a
// client older than the sticker feature keeps working untouched), page,
// per_page (8..50), rating (g|pg|pg-13|r, default pg — enforced server-side;
// the client may raise it, NSFW-off servers force it back down in the app),
// ver (reserved schema cache-buster).
//
// ID NAMESPACING — Klipy slugs are per-catalog, so a GIF and a sticker can
// carry the SAME slug while `items` is keyed by id alone. Sticker ids are
// therefore stored and handed out with a leading `~`; GIF ids stay bare so
// every media path already saved in a client's favourites keeps resolving.
// `~` is unreserved in URLs (RFC 3986) and outside the slug charset, so it
// can never collide with a real slug. fetch.php, full.php and .htaccess all
// accept the optional prefix.
//
// NORMALIZED RESPONSE — this is the contract the app codes to; everything
// Klipy-specific stays in this file so swapping providers is a PHP change,
// not an app release:
//
//   { "result": true,
//     "items": [ { "id":"...", "w":480, "h":270, "title":"...",
//                  "still":".../gifs/m/<id>.still.webp",
//                  "sm":   ".../gifs/m/<id>.sm.webp",
//                  "full": ".../gifs/f/<id>" } ],
//     "page": 1, "has_next": true, "meta": { "backoff_until": 0 } }
//
//   categories=1 instead returns { "result": true, "categories": ["..."] }.
//
// METADATA AND MEDIA ARE SEPARATE REQUESTS (the Phase-0 lesson): search
// responses return image URLs unconditionally and never download anything
// inline. Warm media is served directly by Apache; cold falls through to
// fetch.php / full.php (see .htaccess).
//
// PRIVACY — this source is published in the public Hollow repo so these
// claims are auditable:
//   * POST-only: query text travels in the body, never in a URL, so it
//     cannot land in standard web-server access logs.
//   * This script writes NO log of any kind. No IP+query pair exists
//     anywhere: queries are cached ANONYMOUSLY (the qkey row says "someone
//     once searched this", never who or from where).
//   * customer_id sent upstream is a random UUID minted per request,
//     never stored, never derived from anything about the user — Klipy
//     sees our server's IP and an unlinkable one-shot id.
//   * No ad-* params are ever sent; any ad-flagged item in the response is
//     stripped before caching.
//   * Abuse valve keyed by hash(ip + rotating daily salt) in a short-lived
//     table; raw IPs are never written and the salt rotates daily, so
//     yesterday's hashes are meaningless today.
//
// Only this endpoint ever talks to Klipy, and only at AUTHORING time (a
// user browsing the GIF picker). The moment a GIF is picked, the app
// downloads the bytes through full.php, re-encodes them into a
// content-addressed Hollow blob, and it replicates purely P2P/E2EE.
// Message RECEIVERS make zero HTTP requests, ever.
//
// Deploy: upload this folder (search.php, fetch.php, full.php, sweep.php,
// .htaccess) to /public_html/hollow/gifs/, copy config.php.example to
// config.php with the real key, and add an hourly cron for sweep.php
// (the media LRU cap is mandatory — the GIF long-tail is unbounded).

declare(strict_types=1);

ini_set('display_errors', '0');

require __DIR__ . '/config.php';

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
    http_response_code(405);
    header('Allow: POST');
    exit;
}

function param(string $name): string {
    return trim((string)($_POST[$name] ?? ''));
}

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');
header('X-Content-Type-Options: nosniff');
header('Referrer-Policy: no-referrer');
header('X-Robots-Tag: noindex');

const DB_FILE        = __DIR__ . '/gifs.db';
const SEARCH_TTL     = 24 * 3600;      // re-ask upstream after a day
const TRENDING_TTL   = 3600;           // trending shifts hourly
const CATEGORIES_TTL = 7 * 24 * 3600;  // effectively static
const EMPTY_TTL      = 3600;           // negative cache — typos must not re-hit upstream
const CATEGORIES_KEY = "\x00categories";
const RATINGS        = ['g', 'pg', 'pg-13', 'r'];
const DEFAULT_RATING = 'pg';
// Upstream catalogs we proxy, and the id prefix each one's rows carry.
// Anything not in here is refused rather than forwarded — the kind lands in
// an upstream URL path segment.
const KINDS          = ['gifs' => '', 'stickers' => '~'];
const DEFAULT_KIND   = 'gifs';
// Abuse valve: fixed window per salted-ip-hash. Generous — a debounced
// picker session is tens of requests, not hundreds.
const RATE_WINDOW    = 300;
const RATE_MAX       = 150;
// Bump when the response schema changes — older cached rows refetch.
// v2: categories parse fixed to the LIVE Klipy shape
//     data:{locale, categories:[{category,query,preview_url}]} — the
//     published demo-app models (flat string list) were outdated.
const SEARCH_VER     = 2;

function fail(int $code, string $msg): void {
    http_response_code($code);
    echo json_encode(['result' => false, 'error' => $msg]);
    exit;
}

function db(): PDO {
    static $pdo = null;
    if ($pdo === null) {
        $pdo = new PDO('sqlite:' . DB_FILE);
        $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
        $pdo->exec('PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;');
        $pdo->exec('CREATE TABLE IF NOT EXISTS queries (
            qkey       TEXT PRIMARY KEY,
            ids        TEXT NOT NULL,
            has_next   INTEGER NOT NULL DEFAULT 0,
            ver        INTEGER NOT NULL DEFAULT 0,
            fetched_at INTEGER NOT NULL
        )');
        // The fetch registry: only ids this table knows are fetchable by
        // fetch.php / full.php, and the upstream variant URLs come from
        // src_json — NEVER from the request. This must not become an open
        // proxy.
        $pdo->exec('CREATE TABLE IF NOT EXISTS items (
            id         TEXT PRIMARY KEY,
            w          INTEGER NOT NULL,
            h          INTEGER NOT NULL,
            title      TEXT NOT NULL DEFAULT \'\',
            provider   TEXT NOT NULL DEFAULT \'klipy\',
            sm_ext     TEXT NOT NULL DEFAULT \'webp\',
            src_json   TEXT NOT NULL,
            fetched_at INTEGER NOT NULL
        )');
        // Single-flight lock: 50 users hitting the same cold term in one
        // second produce ONE upstream call.
        $pdo->exec('CREATE TABLE IF NOT EXISTS inflight (
            qkey       TEXT PRIMARY KEY,
            started_at INTEGER NOT NULL
        )');
        // Abuse valve. khash = sha256(daily salt | ip) prefix — raw IPs
        // never touch disk and rows expire in minutes (sweep + inline prune).
        $pdo->exec('CREATE TABLE IF NOT EXISTS ratelimit (
            khash        TEXT PRIMARY KEY,
            count        INTEGER NOT NULL,
            window_start INTEGER NOT NULL
        )');
        // Single-row odds and ends (backoff deadline, rotating salt).
        $pdo->exec('CREATE TABLE IF NOT EXISTS meta (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        )');
    }
    return $pdo;
}

function meta_get(string $key): ?string {
    $stmt = db()->prepare('SELECT value FROM meta WHERE key = ?');
    $stmt->execute([$key]);
    $v = $stmt->fetchColumn();
    return $v === false ? null : (string)$v;
}

function meta_set(string $key, string $value): void {
    db()->prepare('INSERT INTO meta (key, value) VALUES (?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value')
        ->execute([$key, $value]);
}

function backoff_until(): int {
    return (int)(meta_get('backoff_until') ?? '0');
}

/// True while a stored upstream backoff is active — serve cache only.
function in_backoff(): bool {
    return backoff_until() > time();
}

// ─── Abuse valve ────────────────────────────────────────────────────────────

/// Daily rotating salt: random bytes regenerated on first request of each
/// UTC day. Derived-from-nothing, so old khash values cannot be joined
/// across days even by us.
function daily_salt(): string {
    $today = gmdate('Y-m-d');
    if (meta_get('salt_day') !== $today) {
        meta_set('salt', bin2hex(random_bytes(16)));
        meta_set('salt_day', $today);
        db()->exec('DELETE FROM ratelimit'); // old hashes are dead weight
    }
    return (string)meta_get('salt');
}

function rate_gate(): void {
    $now = time();
    $khash = substr(hash('sha256', daily_salt() . '|' . ($_SERVER['REMOTE_ADDR'] ?? '')), 0, 16);
    // Inline prune keeps the table minutes-deep even without the cron.
    db()->prepare('DELETE FROM ratelimit WHERE window_start < ?')->execute([$now - 2 * RATE_WINDOW]);
    $stmt = db()->prepare('SELECT count, window_start FROM ratelimit WHERE khash = ?');
    $stmt->execute([$khash]);
    $row = $stmt->fetch(PDO::FETCH_ASSOC);
    if (!$row || (int)$row['window_start'] < $now - RATE_WINDOW) {
        db()->prepare('INSERT INTO ratelimit (khash, count, window_start) VALUES (?, 1, ?)
            ON CONFLICT(khash) DO UPDATE SET count = 1, window_start = excluded.window_start')
            ->execute([$khash, $now]);
        return;
    }
    if ((int)$row['count'] >= RATE_MAX) {
        fail(429, 'rate_limited');
    }
    db()->prepare('UPDATE ratelimit SET count = count + 1 WHERE khash = ?')->execute([$khash]);
}

// ─── Upstream ───────────────────────────────────────────────────────────────

function curl_req(string $url, ?int &$status = null, ?array &$headers = null): ?string {
    $collected = [];
    $ch = curl_init($url);
    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_CONNECTTIMEOUT => 5,
        CURLOPT_TIMEOUT        => 10,
        CURLOPT_FOLLOWLOCATION => true,
        CURLOPT_MAXREDIRS      => 3,
        CURLOPT_USERAGENT      => 'Hollow-gif-cache/1.0 (+https://hollow.anonlisten.com)',
        CURLOPT_HEADERFUNCTION => function ($ch, $line) use (&$collected) {
            $parts = explode(':', $line, 2);
            if (count($parts) === 2) {
                $collected[strtolower(trim($parts[0]))] = trim($parts[1]);
            }
            return strlen($line);
        },
    ]);
    $body = curl_exec($ch);
    $status = (int)curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
    curl_close($ch);
    $headers = $collected;
    if ($body === false) return null;
    return $body;
}

/// One Klipy API call with backoff handling. $kind selects the catalog
/// segment ('gifs' | 'stickers'), $path the operation under it. Returns the
/// decoded inner "data" object, or null.
function klipy_query(string $kind, string $path, array $params): ?array {
    if (in_backoff()) return null;
    // Random one-shot customer id — see the PRIVACY header block.
    $params['customer_id'] = bin2hex(random_bytes(16));
    // $kind is whitelist-checked at request parse; never interpolate a raw
    // param into a URL path.
    $url = 'https://api.klipy.com/api/v1/' . rawurlencode(KLIPY_API_KEY)
         . '/' . $kind . '/' . $path . '?' . http_build_query($params);
    $body = curl_req($url, $status, $headers);
    if ($status === 429) {
        $retry = (int)($headers['retry-after'] ?? 60);
        meta_set('backoff_until', (string)(time() + max(5, min(3600, $retry))));
        return null;
    }
    if ($body === null || $status < 200 || $status >= 300) {
        // Upstream down / unreachable: short backoff so a broken Klipy does
        // not have every cold query eat a 10s timeout.
        meta_set('backoff_until', (string)(time() + 60));
        return null;
    }
    $j = json_decode($body, true);
    if (!is_array($j) || empty($j['result'])) return null;
    return is_array($j['data'] ?? null) ? $j['data'] : null;
}

// ─── Normalization / ingest ─────────────────────────────────────────────────

/// Klipy item shape (confirmed against their published client models):
///   { slug, title, blur_preview, type,
///     file: { hd|md|sm|xs: { gif|webp|mp4: {url,width,height,size} } } }
/// Ads arrive as { type:"ad", width, height, content } — stripped.
const SIZE_SLOTS = ['sm', 'xs', 'md', 'hd']; // preference order for grid dims

function variant(array $file, string $slot, string $fmt): ?array {
    $v = $file[$slot][$fmt] ?? null;
    return (is_array($v) && is_string($v['url'] ?? null) && $v['url'] !== '') ? $v : null;
}

/// Normalize one Klipy item into a registry row + response row. `$prefix`
/// namespaces the id by catalog (see the ID NAMESPACING note up top).
/// No download happens here — URLs are handed out unconditionally and
/// fetch.php / full.php materialize bytes on first request.
function ingest_item(array $e, int $now, string $prefix): ?array {
    if (($e['type'] ?? '') === 'ad') return null;
    $slug = (string)($e['slug'] ?? '');
    // Validate the BARE slug: the prefix is ours, not the provider's.
    if (!preg_match('/^[A-Za-z0-9_-]{1,100}$/', $slug)) return null;
    $id = $prefix . $slug;
    $file = $e['file'] ?? null;
    if (!is_array($file)) return null;

    // Grid dims + the sm ext we will hand out. Items with no gif/webp in
    // any slot are unusable to us (mp4-only = clips) and are dropped.
    $w = 0; $h = 0; $smExt = '';
    foreach (SIZE_SLOTS as $slot) {
        foreach (['webp', 'gif'] as $fmt) {
            $v = variant($file, $slot, $fmt);
            if ($v !== null) {
                $w = (int)($v['width'] ?? 0);
                $h = (int)($v['height'] ?? 0);
                $smExt = $fmt;
                break 2;
            }
        }
    }
    if ($smExt === '' || $w <= 0 || $h <= 0) return null;

    $title = mb_substr((string)($e['title'] ?? ''), 0, 120);

    db()->prepare('INSERT INTO items (id, w, h, title, provider, sm_ext, src_json, fetched_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            w=excluded.w, h=excluded.h, title=excluded.title,
            sm_ext=excluded.sm_ext, src_json=excluded.src_json,
            fetched_at=excluded.fetched_at')
        ->execute([$id, $w, $h, $title, 'klipy', $smExt,
                   json_encode($file, JSON_INVALID_UTF8_SUBSTITUTE), $now]);

    return item_row_to_json([
        'id' => $id, 'w' => $w, 'h' => $h, 'title' => $title, 'sm_ext' => $smExt,
    ]);
}

function item_row_to_json(array $row): array {
    $id = (string)$row['id'];
    return [
        'id'    => $id,
        'w'     => (int)$row['w'],
        'h'     => (int)$row['h'],
        'title' => (string)$row['title'],
        'still' => GIFS_BASE_URL . "m/$id.still.webp",
        'sm'    => GIFS_BASE_URL . "m/$id.sm." . $row['sm_ext'],
        'full'  => GIFS_BASE_URL . "f/$id",
    ];
}

// ─── Cache plumbing ─────────────────────────────────────────────────────────

function emit_items(array $items, int $page, bool $hasNext): void {
    echo json_encode([
        'result'   => true,
        'items'    => $items,
        'page'     => $page,
        'has_next' => $hasNext,
        'meta'     => ['backoff_until' => backoff_until()],
    ], JSON_INVALID_UTF8_SUBSTITUTE);
    exit;
}

function cached_row(string $qkey): ?array {
    $stmt = db()->prepare('SELECT ids, has_next, ver, fetched_at FROM queries WHERE qkey = ?');
    $stmt->execute([$qkey]);
    $hit = $stmt->fetch(PDO::FETCH_ASSOC);
    return $hit === false ? null : $hit;
}

/// Serve a cached id list if fresh (or while a backoff makes stale beat
/// nothing). Exits on hit.
function serve_cached_items(string $qkey, int $ttl, int $page, bool $allowStale = false): void {
    $now = time();
    $hit = cached_row($qkey);
    if (!$hit || (int)$hit['ver'] !== SEARCH_VER) return;
    $ids = json_decode((string)$hit['ids'], true) ?: [];
    $effTtl = $ids ? $ttl : min($ttl, EMPTY_TTL); // negative cache is shorter
    if ((int)$hit['fetched_at'] <= $now - $effTtl) {
        // Stale — but if upstream is limiting/down, stale beats nothing.
        if (!$allowStale && !in_backoff()) return;
    }
    if (!$ids) { emit_items([], $page, false); }
    $ph = implode(',', array_fill(0, count($ids), '?'));
    $g = db()->prepare("SELECT * FROM items WHERE id IN ($ph)");
    $g->execute($ids);
    $byId = [];
    foreach ($g->fetchAll(PDO::FETCH_ASSOC) as $row) {
        $byId[(string)$row['id']] = $row;
    }
    $out = [];
    foreach ($ids as $id) { // preserve upstream relevance order
        if (isset($byId[(string)$id])) {
            $out[] = item_row_to_json($byId[(string)$id]);
        }
    }
    emit_items($out, $page, (bool)(int)$hit['has_next']);
}

function store_query(string $qkey, array $ids, bool $hasNext): void {
    db()->prepare('INSERT INTO queries (qkey, ids, has_next, ver, fetched_at) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(qkey) DO UPDATE SET ids=excluded.ids, has_next=excluded.has_next,
            ver=excluded.ver, fetched_at=excluded.fetched_at')
        ->execute([$qkey, json_encode($ids), $hasNext ? 1 : 0, SEARCH_VER, time()]);
}

// ─── Single-flight ──────────────────────────────────────────────────────────

function acquire_flight(string $qkey): bool {
    $now = time();
    db()->prepare('DELETE FROM inflight WHERE started_at < ?')->execute([$now - 20]);
    try {
        db()->prepare('INSERT INTO inflight (qkey, started_at) VALUES (?, ?)')
            ->execute([$qkey, $now]);
        return true;
    } catch (PDOException $e) {
        return false;
    }
}

function release_flight(string $qkey): void {
    db()->prepare('DELETE FROM inflight WHERE qkey = ?')->execute([$qkey]);
}

/// Someone else is already asking upstream for this qkey: wait for their
/// row to land (poll ≤6 s), then serve it; on timeout fall back to stale.
function wait_for_flight(string $qkey, int $ttl, int $page): void {
    $deadline = microtime(true) + 6.0;
    while (microtime(true) < $deadline) {
        usleep(250_000);
        $hit = cached_row($qkey);
        if ($hit && (int)$hit['ver'] === SEARCH_VER && (int)$hit['fetched_at'] > time() - 30) {
            serve_cached_items($qkey, $ttl, $page, true); // exits
        }
    }
    serve_cached_items($qkey, $ttl, $page, true);
    emit_items([], $page, false);
}

/// Cold path shared by search + trending: single-flight, one upstream call,
/// ingest, cache, emit. All emits happen AFTER the lock release — PHP's
/// `finally` does not run on exit(), so emitting inside the try would leak
/// the inflight row until its 20s stale timeout.
function fetch_and_serve(
    string $qkey, int $ttl, string $kind, string $path, array $params, int $page
): void {
    if (!acquire_flight($qkey)) {
        wait_for_flight($qkey, $ttl, $page); // exits
    }
    $data = null;
    $out = [];
    $ids = [];
    $hasNext = false;
    $prefix = KINDS[$kind];
    try {
        $data = klipy_query($kind, $path, $params);
        if ($data !== null) {
            $now = time();
            foreach (($data['data'] ?? []) as $e) {
                if (!is_array($e)) continue;
                $row = ingest_item($e, $now, $prefix);
                if ($row !== null) {
                    $out[] = $row;
                    $ids[] = $row['id'];
                }
            }
            $hasNext = (bool)($data['has_next'] ?? false);
            store_query($qkey, $ids, $hasNext);
        }
    } finally {
        release_flight($qkey);
    }
    if ($data === null) {
        serve_cached_items($qkey, $ttl, $page, true); // stale beats nothing
        emit_items([], $page, false);
    }
    emit_items($out, $page, $hasNext);
}

// ─── Request handling ───────────────────────────────────────────────────────

rate_gate();

$page = max(1, min(100, (int)(param('page') ?: '1')));
$perPage = (int)(param('per_page') ?: '24');
$perPage = max(8, min(50, $perPage));
$rating = param('rating');
if (!in_array($rating, RATINGS, true)) $rating = DEFAULT_RATING;
$kind = param('kind');
if (!isset(KINDS[$kind])) $kind = DEFAULT_KIND;
// Cache-key namespace. Empty for gifs ON PURPOSE: every GIF row already in
// the cache stays valid, so shipping stickers costs nobody a cold grid.
$kns = $kind === DEFAULT_KIND ? '' : "$kind:";

// ═══ MODE C: categories=1 — category names, effectively static. ═══
if (param('categories') !== '') {
    $catKey = $kns . CATEGORIES_KEY;
    $hit = cached_row($catKey);
    $cached = $hit ? (json_decode((string)$hit['ids'], true) ?: []) : [];
    // An empty cached list is a FAILED fetch, not a real answer — hold it
    // only for the negative-cache window, never the full 7 days.
    $ttl = $cached ? CATEGORIES_TTL : EMPTY_TTL;
    $fresh = $hit && (int)$hit['ver'] === SEARCH_VER
        && (int)$hit['fetched_at'] > time() - $ttl;
    if ($fresh || ($hit && in_backoff())) {
        echo json_encode([
            'result' => true,
            'categories' => $cached,
            'meta' => ['backoff_until' => backoff_until()],
        ], JSON_INVALID_UTF8_SUBSTITUTE);
        exit;
    }
    // Live categories shape: data = { locale, categories: [ {category,
    // query, preview_url} ] }. Only the names leave this server —
    // preview_url points at Klipy's CDN, and clients must never talk to
    // anything but our proxy. Flat string lists (the shape Klipy's demo
    // apps still model) are tolerated in case the API varies.
    $data = klipy_query($kind, 'categories', []);
    $names = [];
    $list = is_array($data['categories'] ?? null) ? $data['categories'] : ($data ?? []);
    foreach ($list as $c) {
        $n = is_array($c) ? (string)($c['category'] ?? $c['query'] ?? '')
                          : (is_string($c) ? $c : '');
        if ($n !== '') $names[] = mb_substr($n, 0, 64);
    }
    if ($names || !$cached) {
        store_query($catKey, $names, false);
    } else {
        $names = $cached; // keep stale over empty
    }
    echo json_encode(['result' => true, 'categories' => $names,
        'meta' => ['backoff_until' => backoff_until()]], JSON_INVALID_UTF8_SUBSTITUTE);
    exit;
}

// ═══ MODE B: trending=1 — the picker's default view. ═══
if (param('trending') !== '') {
    $qkey = "t:$kns$rating:$perPage:$page";
    serve_cached_items($qkey, TRENDING_TTL, $page);
    fetch_and_serve($qkey, TRENDING_TTL, $kind, 'trending',
        ['page' => $page, 'per_page' => $perPage, 'rating' => $rating], $page);
}

// ═══ MODE A: q= — search. ═══
$q = param('q');
if ($q === '' || mb_strlen($q) > 64) {
    emit_items([], $page, false);
}
// Normalize into the cache key: lowercase, collapse whitespace, strip
// trailing punctuation — "Cat " and "cat" must be one entry. If stripping
// empties the query (":)", "<3"), keep the un-stripped form.
$norm = mb_strtolower(trim(preg_replace('/\s+/u', ' ', $q)));
$stripped = preg_replace('/[\p{P}\p{S}]+$/u', '', $norm);
if (is_string($stripped) && trim($stripped) !== '') $norm = trim($stripped);
$qkey = "s:$kns$rating:$perPage:$page:$norm";

serve_cached_items($qkey, SEARCH_TTL, $page);
fetch_and_serve($qkey, SEARCH_TTL, $kind, 'search',
    ['q' => $norm, 'page' => $page, 'per_page' => $perPage, 'rating' => $rating], $page);
