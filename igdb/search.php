<?php
// Hollow — IGDB game search + per-game card details, fully write-through
// cached. POST only (GET rejected — keeps search text out of access logs).
// TWO MODES:
//
//   q=<text>   FAST search: ONE IGDB query, basic rows only (name, year,
//              type, genres, rating, summary, cover). No Steam, no
//              companies, no artwork — a cache miss costs one IGDB round
//              trip plus cover thumbnails. (v6 enriched all 12 results
//              inline = 12 sequential Steam calls ≈ 10-20s. Never again.)
//   id=<igdb>  CARD DETAILS for ONE game, fetched when the user actually
//              picks it: Steam appdetails + dev/publisher credits (deduped,
//              logos as PNG) + social links + key art + per-platform store
//              links + copyright. One pick = one IGDB query + one Steam
//              query, then cached forever (30d TTL).
//
// The ONLY place the Twitch/IGDB app credential lives. Hollow clients call
// this at AUTHORING time (composing a showcase board). EVERYTHING is cached
// on our side: images into ./covers/ as static files, metadata into a local
// SQLite DB (games.db). Repeated searches/picks are answered from OUR
// database with ZERO upstream traffic (neither IGDB nor Steam). Display in
// the app is pure P2P off replicated profile data: viewers never hit this
// endpoint, IGDB, Steam, or anything else.
//
// Deploy: upload this folder to /public_html/hollow/igdb/ (config.php holds
// the real credentials and is NOT in git — see config.php.example).

declare(strict_types=1);
require __DIR__ . '/config.php'; // defines IGDB_CLIENT_ID, IGDB_CLIENT_SECRET

// Never leak file paths / stack traces to the client on a fatal.
ini_set('display_errors', '0');

// POST ONLY. Params ride the POST body so search text never appears in the
// request URL — and therefore never lands in web-server access logs (which we
// don't control on shared hosting). GET is deliberately rejected: no released
// client ever used it, and accepting it would let query text leak into logs.
// POST also bypasses the hCDN edge cache entirely, sidestepping the stale-URL
// poisoning trap (see SEARCH_VER).
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

const COVERS_DIR = __DIR__ . '/covers';
const COVERS_URL = 'https://hollow.anonlisten.com/igdb/covers/';
const TOKEN_FILE = __DIR__ . '/token.json';
const DB_FILE    = __DIR__ . '/games.db';
const SEARCH_TTL = 30 * 24 * 3600; // re-ask upstream after 30 days
// Bump when the response schema grows — cached rows from older versions
// refetch so new fields backfill instead of serving nulls. The app appends
// this as a `v` query param (value ignored here) so every bump also busts
// any CDN-cached URLs from older versions (Hostinger hCDN rewrites
// Cache-Control and can serve year-stale responses for old URLs).
// v2: type. v3: Steam enrichment. v4: key art + PNG logos. v5: IGDB enum
// deprecation fixes. v6: minimal payload. v7: split search/details modes;
// stores matched by SOURCE NAME (Nintendo eShop etc.); full card restored.
// v8: search rows stripped to exactly what the picker shows (id/name/year/
// type/cover); "Twitch" no longer matches the itch store (substring bug);
// console chips get store-SEARCH fallback URLs when IGDB has no direct one.
// v9: genres ride the DETAILS payload (card Info section — they left the
// search rows in v8); company links deduped by KIND (no double globes).
const SEARCH_VER = 9;

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

// IGDB website-type id → a stable link "kind" the client maps to an icon.
// `company_website.category` is DEPRECATED (returns nothing) — the current
// source is the `type` reference; we request `websites.type.type` so each
// link carries {id, type-name} and match on BOTH (ids mirror the legacy
// enum). (10/11/12 = iphone/ipad/android app-store links — skipped.)
const WEBSITE_KINDS = [
    1  => 'official',
    2  => 'wikia',
    3  => 'wikipedia',
    4  => 'facebook',
    5  => 'twitter',
    6  => 'twitch',
    8  => 'instagram',
    9  => 'youtube',
    13 => 'steam',
    14 => 'reddit',
    15 => 'itch',
    16 => 'epicgames',
    17 => 'gog',
    18 => 'discord',
    19 => 'bluesky',
];

// IGDB external game source id for Steam (uid = Steam appid). The current
// field is `external_game_source` (reference; expanded name "Steam"); the
// legacy `category` enum used the same value and is kept as a fallback.
const EXTERNAL_STEAM = 1;

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
        // Per-game card details, fetched on PICK (?id=), not on search.
        $pdo->exec('CREATE TABLE IF NOT EXISTS game_details (
            id INTEGER PRIMARY KEY,
            steam_appid INTEGER,
            description TEXT,
            req_min TEXT,
            req_rec TEXT,
            platforms TEXT,      -- JSON array of platform slugs
            metacritic INTEGER,
            release_date TEXT,
            achievements INTEGER,
            companies TEXT,      -- JSON array of {name, role, logo?, links[]}
            artwork TEXT,        -- IGDB artwork image_id (landscape key art)
            developer TEXT,      -- legacy (v6), superseded by companies
            legal TEXT,          -- cleaned Steam legal_notice (one line)
            stores TEXT,         -- JSON {steam|playstation|xbox|nintendo|...: url}
            genres TEXT,         -- JSON array of genre names (card Info row)
            ver INTEGER NOT NULL DEFAULT 0,
            fetched_at INTEGER NOT NULL
        )');
        // Additive migrations (idempotent — duplicate-column errors ignored).
        try { $pdo->exec('ALTER TABLE searches ADD COLUMN ver INTEGER NOT NULL DEFAULT 0'); } catch (Throwable $e) {}
        try { $pdo->exec('ALTER TABLE game_details ADD COLUMN artwork TEXT'); } catch (Throwable $e) {}
        try { $pdo->exec('ALTER TABLE game_details ADD COLUMN developer TEXT'); } catch (Throwable $e) {}
        try { $pdo->exec('ALTER TABLE game_details ADD COLUMN legal TEXT'); } catch (Throwable $e) {}
        try { $pdo->exec('ALTER TABLE game_details ADD COLUMN stores TEXT'); } catch (Throwable $e) {}
        try { $pdo->exec('ALTER TABLE game_details ADD COLUMN genres TEXT'); } catch (Throwable $e) {}
        try { $pdo->exec('ALTER TABLE game_details ADD COLUMN ver INTEGER NOT NULL DEFAULT 0'); } catch (Throwable $e) {}
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

function igdb_query(string $endpoint, string $body): ?array {
    $resp = curl_req("https://api.igdb.com/v4/$endpoint", [
        'Client-ID: ' . IGDB_CLIENT_ID,
        'Authorization: Bearer ' . app_token(),
        'Accept: application/json',
    ], $body);
    if ($resp === null) return null;
    $j = json_decode($resp, true);
    return is_array($j) ? $j : null;
}

/// Ensure an IGDB image (cover / key art / company logo) sits in ./covers/;
/// return its URL or null. $size is an IGDB image size slug (t_cover_big /
/// t_720p / t_logo_med). $ext: 'jpg' for photos, 'png' for logos — IGDB
/// flattens transparency onto white when serving JPG, so logos MUST be PNG.
function cached_image(?string $imageId, string $size = 't_cover_big', string $ext = 'jpg'): ?string {
    if (!is_string($imageId) || !preg_match('/^[a-z0-9]+$/i', $imageId)) {
        return null;
    }
    $local = COVERS_DIR . "/$imageId.$ext";
    if (!is_file($local)) {
        if (!is_dir(COVERS_DIR)) @mkdir(COVERS_DIR, 0755, true);
        $img = curl_req("https://images.igdb.com/igdb/image/upload/$size/$imageId.$ext");
        if ($img !== null && strlen($img) > 0 && strlen($img) < 2_000_000) {
            @file_put_contents($local, $img, LOCK_EX);
        }
    }
    return is_file($local) ? COVERS_URL . "$imageId.$ext" : null;
}

/// Steam ships requirements as an HTML blob (<strong>OS:</strong> …<br>). Flatten
/// to readable plain text: list items / <br> → newlines, tags stripped, entities
/// decoded, capped. Returns null for empty/absent input.
function clean_requirements($html): ?string {
    if (!is_string($html) || $html === '') return null;
    // Turn structural tags into line breaks before stripping.
    $html = preg_replace('#<\s*/?(li|br|p|div|ul)[^>]*>#i', "\n", $html);
    $text = html_entity_decode(strip_tags($html), ENT_QUOTES | ENT_HTML5, 'UTF-8');
    // Steam prefixes with "Minimum:" / "Recommended:" — drop leading label.
    $text = preg_replace('/^\s*(minimum|recommended)\s*:?\s*/iu', '', $text);
    // Collapse whitespace runs, one item per line, trim blank lines.
    $lines = [];
    foreach (preg_split('/\R+/u', $text) as $line) {
        $line = trim(preg_replace('/\s+/u', ' ', $line));
        if ($line !== '') $lines[] = $line;
    }
    if (!$lines) return null;
    $out = implode("\n", array_slice($lines, 0, 12));
    return mb_substr($out, 0, 800);
}

/// Steam's `legal_notice` is an HTML-laced paragraph (often several lines of
/// trademark boilerplate). Keep just the copyright line: strip tags, take the
/// first line (preferring one that starts with ©), cap it short.
function clean_legal($html): ?string {
    if (!is_string($html) || $html === '') return null;
    $html = preg_replace('#<\s*br[^>]*>#i', "\n", $html);
    $text = html_entity_decode(strip_tags($html), ENT_QUOTES | ENT_HTML5, 'UTF-8');
    $lines = [];
    foreach (preg_split('/\R+/u', $text) as $line) {
        $line = trim(preg_replace('/\s+/u', ' ', $line));
        if ($line !== '') $lines[] = $line;
    }
    if (!$lines) return null;
    $pick = $lines[0];
    foreach ($lines as $line) {
        if (str_starts_with($line, '©') || stripos($line, 'copyright') === 0) {
            $pick = $line;
            break;
        }
    }
    return mb_substr($pick, 0, 160);
}

/// Fetch + normalize Steam appdetails for one appid. Returns a partial detail
/// array (only the fields Steam supplies), or [] on any failure — enrichment
/// is best-effort and never blocks the IGDB result.
function steam_details(int $appid): array {
    // `l=english` for stable English requirements/description; cc omitted (no price).
    $resp = curl_req("https://store.steampowered.com/api/appdetails?appids=$appid&l=english");
    if ($resp === null) return [];
    $j = json_decode($resp, true);
    $node = $j[$appid] ?? $j[(string)$appid] ?? null;
    if (!is_array($node) || empty($node['success']) || !is_array($node['data'] ?? null)) {
        return [];
    }
    $d = $node['data'];
    $out = ['steam_appid' => $appid];

    if (!empty($d['short_description']) && is_string($d['short_description'])) {
        $out['description'] = mb_substr($d['short_description'], 0, 1000);
    }
    // Requirements: platform-specific arrays each with minimum/recommended HTML.
    $reqMin = $reqRec = null;
    foreach (['pc_requirements', 'mac_requirements', 'linux_requirements'] as $rk) {
        $r = $d[$rk] ?? null;
        if (is_array($r)) {
            $reqMin = $reqMin ?? clean_requirements($r['minimum'] ?? null);
            $reqRec = $reqRec ?? clean_requirements($r['recommended'] ?? null);
        }
        if ($reqMin && $reqRec) break;
    }
    if ($reqMin !== null) $out['req_min'] = $reqMin;
    if ($reqRec !== null) $out['req_rec'] = $reqRec;

    $legal = clean_legal($d['legal_notice'] ?? null);
    if ($legal !== null) $out['legal'] = $legal;

    if (isset($d['metacritic']['score'])) {
        $out['metacritic'] = (int)$d['metacritic']['score'];
    }
    if (!empty($d['release_date']['date']) && is_string($d['release_date']['date'])
            && empty($d['release_date']['coming_soon'])) {
        $out['release_date'] = mb_substr($d['release_date']['date'], 0, 40);
    }
    if (isset($d['achievements']['total'])) {
        $out['achievements'] = (int)$d['achievements']['total'];
    }
    // Platform booleans for platform_slugs().
    foreach (['windows', 'mac', 'linux'] as $pk) {
        if (!empty($d['platforms'][$pk])) $out[$pk] = true;
    }
    return $out;
}

/// Build the platform slug list. Prefer Steam's booleans (clean PC/Mac/Linux),
/// merge in IGDB platform names (consoles etc.) mapped to stable slugs.
function platform_slugs(array $steam, array $igdbPlatforms): array {
    $slugs = [];
    if (!empty($steam['windows'])) $slugs['pc'] = true;
    if (!empty($steam['mac']))     $slugs['mac'] = true;
    if (!empty($steam['linux']))   $slugs['linux'] = true;
    // IGDB platform names → coarse slug the client has an icon for.
    $map = [
        '/windows|pc \(microsoft|microsoft windows/i' => 'pc',
        '/\bmac\b|mac os|macos/i'                      => 'mac',
        '/linux/i'                                     => 'linux',
        '/playstation|ps[1-5]\b|psp|ps vita/i'         => 'playstation',
        '/xbox/i'                                      => 'xbox',
        '/nintendo|switch|wii|game boy|3ds|\bds\b/i'   => 'nintendo',
        '/android/i'                                   => 'android',
        '/\bios\b|iphone|ipad/i'                       => 'ios',
    ];
    foreach ($igdbPlatforms as $p) {
        if (!is_string($p) || $p === '') continue;
        foreach ($map as $re => $slug) {
            if (preg_match($re, $p)) { $slugs[$slug] = true; break; }
        }
    }
    // Stable display order.
    $order = ['pc', 'mac', 'linux', 'playstation', 'xbox', 'nintendo', 'android', 'ios'];
    $out = [];
    foreach ($order as $s) if (isset($slugs[$s])) $out[] = $s;
    return $out;
}

/// Numeric source id of an external_games row (expanded reference or legacy
/// numeric category, which is deprecated and empty on new data).
function external_source_id(array $ext): int {
    $src = $ext['external_game_source'] ?? null;
    if (is_array($src)) {
        $id = (int)($src['id'] ?? 0);
        if ($id > 0) return $id;
    } elseif (is_int($src) || (is_string($src) && ctype_digit($src))) {
        return (int)$src;
    }
    return (int)($ext['category'] ?? 0);
}

/// Expanded source NAME of an external_games row ('' when unexpanded).
function external_source_name(array $ext): string {
    $src = $ext['external_game_source'] ?? null;
    if (is_array($src) && is_string($src['name'] ?? null)) {
        return $src['name'];
    }
    return '';
}

/// Map an external_games row to the store slug the card's platform chips
/// link to. Matched by SOURCE NAME first (robust — the new
/// external_game_sources ids are NOT guaranteed to mirror the legacy enum,
/// and the legacy enum never had Nintendo at all), numeric id as fallback.
function store_slug(array $ext): ?string {
    $name = strtolower(external_source_name($ext));
    if ($name !== '') {
        // Twitch FIRST — "Twitch" contains "itch", and Twitch directory
        // links are not a store (live-data bug, v8).
        if (str_contains($name, 'twitch'))      return null;
        if (str_contains($name, 'steam'))       return 'steam';
        if (str_contains($name, 'playstation')) return 'playstation';
        if (str_contains($name, 'xbox') || str_contains($name, 'microsoft')) return 'xbox';
        if (str_contains($name, 'nintendo') || str_contains($name, 'eshop')) return 'nintendo';
        if (str_contains($name, 'gog'))         return 'gog';
        if (str_contains($name, 'epic'))        return 'epicgames';
        if (str_contains($name, 'itch'))        return 'itch';
        return null;
    }
    return match (external_source_id($ext)) {
        1  => 'steam',
        5  => 'gog',
        26 => 'epicgames',
        30 => 'itch',
        11, 31 => 'xbox',
        36 => 'playstation',
        default => null,
    };
}

/// Per-store URLs for the card's clickable platform chips. First seen wins;
/// Steam composed from the appid when IGDB carries no URL. https only.
function extract_stores(array $externals, ?int $steamAppid): array {
    $stores = [];
    foreach ($externals as $ext) {
        if (!is_array($ext)) continue;
        $slug = store_slug($ext);
        if ($slug === null || isset($stores[$slug])) continue;
        $url = $ext['url'] ?? null;
        if (is_string($url) && preg_match('#^https://#i', $url)) {
            $stores[$slug] = mb_substr($url, 0, 300);
        }
    }
    if (!isset($stores['steam']) && $steamAppid !== null) {
        $stores['steam'] = "https://store.steampowered.com/app/$steamAppid";
    }
    return $stores;
}

/// Console chips should still be clickable when IGDB carries no direct
/// store entry (its eShop/PS/Xbox coverage is spotty — live-verified:
/// Zelda TOTK has NO eShop external). Fall back to the store's own SEARCH
/// page for the game — honest and useful, never a fabricated product URL.
/// Only for platforms the game is actually on.
function store_search_fallbacks(string $name, array $platforms, array $stores): array {
    if ($name === '') return $stores;
    $n = rawurlencode($name);
    $fallbacks = [
        'playstation' => "https://store.playstation.com/en-us/search/$n",
        'xbox'        => "https://www.xbox.com/en-us/search/results/games?q=$n",
        'nintendo'    => "https://www.nintendo.com/us/search/#q=$n",
    ];
    foreach ($fallbacks as $slug => $url) {
        if (!isset($stores[$slug]) && in_array($slug, $platforms, true)) {
            $stores[$slug] = $url;
        }
    }
    return $stores;
}

/// Resolve a link "kind" from a company website row (expanded `type`
/// reference {id, type}; legacy numeric `category` as fallback).
function website_kind(array $w): ?string {
    $t = $w['type'] ?? null;
    if (is_array($t)) {
        $kind = WEBSITE_KINDS[(int)($t['id'] ?? 0)] ?? null;
        if ($kind !== null) return $kind;
        $name = strtolower(trim((string)($t['type'] ?? '')));
        if ($name !== '' && in_array($name, WEBSITE_KINDS, true)) return $name;
    } elseif (is_int($t) || (is_string($t) && ctype_digit($t))) {
        $kind = WEBSITE_KINDS[(int)$t] ?? null;
        if ($kind !== null) return $kind;
    }
    return WEBSITE_KINDS[(int)($w['category'] ?? 0)] ?? null;
}

/// Extract dev/publisher credits from IGDB involved_companies — DEDUPED by
/// company name (a company that both develops and publishes appears ONCE
/// with role "devpub", not twice — looking at you, Valve). Logos cached as
/// PNG (alpha kept), links deduped by URL.
function extract_companies(array $involved): array {
    $byName = [];
    foreach ($involved as $ic) {
        if (!is_array($ic)) continue;
        $co = $ic['company'] ?? null;
        if (!is_array($co) || empty($co['name'])) continue;
        $isDev = !empty($ic['developer']);
        $isPub = !empty($ic['publisher']);
        if (!$isDev && !$isPub) continue; // skip porting/supporting-only
        $name = mb_substr((string)$co['name'], 0, 80);
        $key = mb_strtolower($name);

        if (!isset($byName[$key])) {
            $logoUrl = null;
            if (!empty($co['logo']['image_id']) && is_string($co['logo']['image_id'])) {
                $logoUrl = cached_image($co['logo']['image_id'], 't_logo_med', 'png');
            }
            $links = [];
            $seenKinds = [];
            foreach (($co['websites'] ?? []) as $w) {
                if (!is_array($w) || empty($w['url']) || !is_string($w['url'])) continue;
                $kind = website_kind($w);
                if ($kind === null) continue;
                if (!preg_match('#^https?://#i', $w['url'])) continue;
                // ONE link per kind — IGDB often lists near-duplicate URLs
                // (http/https, trailing slash) which rendered as twin globes.
                if (isset($seenKinds[$kind])) continue;
                $seenKinds[$kind] = true;
                $links[] = ['kind' => $kind, 'url' => mb_substr($w['url'], 0, 300)];
                if (count($links) >= 8) break;
            }
            $entry = ['name' => $name, 'dev' => false, 'pub' => false];
            if ($logoUrl !== null) $entry['logo'] = $logoUrl;
            if ($links) $entry['links'] = $links;
            $byName[$key] = $entry;
        }
        if ($isDev) $byName[$key]['dev'] = true;
        if ($isPub) $byName[$key]['pub'] = true;
    }

    $companies = [];
    foreach ($byName as $c) {
        $role = $c['dev'] && $c['pub'] ? 'devpub' : ($c['dev'] ? 'dev' : 'pub');
        $entry = ['name' => $c['name'], 'role' => $role];
        if (!empty($c['logo']))  $entry['logo'] = $c['logo'];
        if (!empty($c['links'])) $entry['links'] = $c['links'];
        $companies[] = $entry;
        if (count($companies) >= 6) break; // credit a handful, not a phone book
    }
    // Developers first, then dev+pub, then publishers.
    $rank = ['dev' => 0, 'devpub' => 1, 'pub' => 2];
    usort($companies, fn($a, $b) => $rank[$a['role']] <=> $rank[$b['role']]);
    return $companies;
}

/// Full card payload from a game_details row (or the equivalent synthetic
/// array on the fetch path — single source of truth for the JSON shape).
function details_row_to_json(?array $row): ?array {
    if ($row === null) return null;
    $platforms = json_decode((string)($row['platforms'] ?? '[]'), true);
    $companies = json_decode((string)($row['companies'] ?? '[]'), true);
    $stores    = json_decode((string)($row['stores'] ?? '{}'), true);
    $genres = json_decode((string)($row['genres'] ?? '[]'), true);
    $out = [];
    // Landscape key art (IGDB artworks, t_720p) — the card's hero image.
    $art = cached_image($row['artwork'] ?? null, 't_720p');
    if ($art !== null) $out['artwork'] = $art;
    if (!empty($row['description'])) $out['description'] = (string)$row['description'];
    if (is_array($genres) && $genres) $out['genres'] = array_values($genres);
    if (!empty($row['req_min']))     $out['req_min'] = (string)$row['req_min'];
    if (!empty($row['req_rec']))     $out['req_rec'] = (string)$row['req_rec'];
    if (is_array($platforms) && $platforms) $out['platforms'] = array_values($platforms);
    if ($row['metacritic'] !== null) $out['metacritic'] = (int)$row['metacritic'];
    if (!empty($row['release_date'])) $out['release_date'] = (string)$row['release_date'];
    if ($row['achievements'] !== null) $out['achievements'] = (int)$row['achievements'];
    if (is_array($companies) && $companies) $out['companies'] = $companies;
    if (!empty($row['legal'])) $out['legal'] = (string)$row['legal'];
    if (is_array($stores) && $stores) $out['stores'] = $stores;
    return $out ?: null;
}

function emit(array|string $payload): void {
    echo json_encode($payload, JSON_INVALID_UTF8_SUBSTITUTE);
    exit;
}

$pdo = db();
$now = time();

// ═══ MODE B: id= — card details for ONE game, fetched on pick. ═══
$idParam = param('id');
if ($idParam !== '') {
    if (!ctype_digit($idParam)) emit(['id' => 0, 'details' => null]);
    $gameId = (int)$idParam;

    // 1. Serve from OUR database when fresh and same schema version.
    $stmt = $pdo->prepare('SELECT * FROM game_details WHERE id = ?');
    $stmt->execute([$gameId]);
    $row = $stmt->fetch(PDO::FETCH_ASSOC);
    if ($row && (int)$row['ver'] === SEARCH_VER
            && (int)$row['fetched_at'] > $now - SEARCH_TTL) {
        emit(['id' => $gameId, 'details' => details_row_to_json($row)]);
    }

    // 2. Miss → ONE IGDB query for this game + ONE Steam query.
    $games = igdb_query('games',
        'fields name,summary,genres.name,platforms.name,artworks.image_id,'
        . 'external_games.category,external_games.uid,external_games.url,'
        . 'external_games.external_game_source.name,'
        . 'involved_companies.developer,involved_companies.publisher,'
        . 'involved_companies.company.name,'
        . 'involved_companies.company.logo.image_id,'
        . 'involved_companies.company.websites.category,'
        . 'involved_companies.company.websites.type.type,'
        . 'involved_companies.company.websites.url; '
        . "where id = $gameId; limit 1;"
    );
    if ($games === null) fail(502, 'igdb_query_failed');
    $g = $games[0] ?? null;
    if (!is_array($g)) emit(['id' => $gameId, 'details' => null]);

    $externals = array_filter(($g['external_games'] ?? []), 'is_array');
    $steamAppid = null;
    foreach ($externals as $ext) {
        if (store_slug($ext) === 'steam'
                && !empty($ext['uid']) && ctype_digit((string)$ext['uid'])) {
            $steamAppid = (int)$ext['uid'];
            break;
        }
    }
    $steam = $steamAppid !== null ? steam_details($steamAppid) : [];

    $igdbPlatforms = [];
    foreach (($g['platforms'] ?? []) as $p) {
        if (is_array($p) && !empty($p['name'])) $igdbPlatforms[] = (string)$p['name'];
    }
    $platforms = platform_slugs($steam, $igdbPlatforms);
    $stores = store_search_fallbacks(
        (string)($g['name'] ?? ''),
        $platforms,
        extract_stores($externals, $steamAppid),
    );
    $companies = extract_companies($g['involved_companies'] ?? []);

    $artworkId = null;
    foreach (($g['artworks'] ?? []) as $aw) {
        if (is_array($aw) && !empty($aw['image_id']) && is_string($aw['image_id'])) {
            $artworkId = $aw['image_id'];
            break;
        }
    }

    $summary = isset($g['summary']) ? mb_substr((string)$g['summary'], 0, 1000) : null;
    $description = $steam['description'] ?? $summary;
    $genres = [];
    foreach (($g['genres'] ?? []) as $gen) {
        if (is_array($gen) && !empty($gen['name'])) $genres[] = (string)$gen['name'];
        if (count($genres) >= 4) break;
    }

    $pdo->prepare('INSERT INTO game_details
        (id, steam_appid, description, req_min, req_rec, platforms, metacritic,
         release_date, achievements, companies, artwork, legal, stores, genres, ver, fetched_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            steam_appid=excluded.steam_appid, description=excluded.description,
            req_min=excluded.req_min, req_rec=excluded.req_rec,
            platforms=excluded.platforms, metacritic=excluded.metacritic,
            release_date=excluded.release_date, achievements=excluded.achievements,
            companies=excluded.companies, artwork=excluded.artwork,
            legal=excluded.legal, stores=excluded.stores,
            genres=excluded.genres, ver=excluded.ver, fetched_at=excluded.fetched_at')
        ->execute([
            $gameId,
            $steamAppid,
            $description,
            $steam['req_min'] ?? null,
            $steam['req_rec'] ?? null,
            json_encode($platforms),
            $steam['metacritic'] ?? null,
            $steam['release_date'] ?? null,
            $steam['achievements'] ?? null,
            json_encode($companies),
            $artworkId,
            $steam['legal'] ?? null,
            json_encode($stores),
            json_encode($genres),
            SEARCH_VER,
            $now,
        ]);

    emit(['id' => $gameId, 'details' => details_row_to_json([
        'description'  => $description,
        'req_min'      => $steam['req_min'] ?? null,
        'req_rec'      => $steam['req_rec'] ?? null,
        'platforms'    => json_encode($platforms),
        'metacritic'   => $steam['metacritic'] ?? null,
        'release_date' => $steam['release_date'] ?? null,
        'achievements' => $steam['achievements'] ?? null,
        'companies'    => json_encode($companies),
        'artwork'      => $artworkId,
        'legal'        => $steam['legal'] ?? null,
        'stores'       => json_encode($stores),
        'genres'       => json_encode($genres),
    ])]);
}

// ═══ MODE A: q= — fast search, basic rows only. ═══
$q = param('q');
if ($q === '' || mb_strlen($q) > 100) {
    emit([]);
}
// Normalized cache key: case/whitespace variants share one entry.
$qkey = mb_strtolower(preg_replace('/\s+/u', ' ', $q));

// Search rows carry EXACTLY what the picker renders: name, year, type
// badge, cover thumbnail. Nothing else rides the search path (v8).
function game_row_to_json(array $row): array {
    return [
        'id'    => (int)$row['id'],
        'name'  => (string)$row['name'],
        'year'  => $row['year'] !== null ? (int)$row['year'] : null,
        'type'  => $row['type'] !== null && $row['type'] !== '' ? (string)$row['type'] : null,
        'cover' => cached_image($row['cover_image_id'] ?? null),
    ];
}

// ── 1. Serve from OUR database when we've seen this search before. ──
$stmt = $pdo->prepare('SELECT game_ids, fetched_at, ver FROM searches WHERE q = ?');
$stmt->execute([$qkey]);
$hit = $stmt->fetch(PDO::FETCH_ASSOC);
if ($hit && (int)$hit['ver'] === SEARCH_VER
        && (int)$hit['fetched_at'] > $now - SEARCH_TTL) {
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
            if (isset($byId[(int)$id])) {
                $out[] = game_row_to_json($byId[(int)$id]);
            }
        }
    }
    emit($out);
}

// ── 2. Cache miss → ONE IGDB query (exactly the picker's fields), persist. ──
$body = 'search "' . str_replace(['\\', '"'], ['\\\\', '\\"'], $q) . '"; '
      . 'fields name,cover.image_id,first_release_date,game_type.type,category; '
      . 'limit 12;';
$games = igdb_query('games', $body);
if ($games === null) fail(502, 'igdb_query_failed');

$upsertGame = $pdo->prepare('INSERT INTO games (id, name, year, type, cover_image_id, genres, rating, summary, fetched_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET
        name=excluded.name, year=excluded.year, type=excluded.type,
        cover_image_id=excluded.cover_image_id, genres=excluded.genres,
        rating=excluded.rating, summary=excluded.summary,
        fetched_at=excluded.fetched_at');

$out = [];
$ids = [];
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

    $upsertGame->execute([
        $id, (string)$g['name'], $year, $type,
        is_string($imageId) ? $imageId : null,
        '[]', null, null, $now,
    ]);

    $ids[] = $id;
    $out[] = [
        'id'    => $id,
        'name'  => (string)$g['name'],
        'year'  => $year,
        'type'  => $type,
        'cover' => cached_image(is_string($imageId) ? $imageId : null),
    ];
}

$pdo->prepare('INSERT INTO searches (q, game_ids, fetched_at, ver) VALUES (?, ?, ?, ?)
    ON CONFLICT(q) DO UPDATE SET game_ids=excluded.game_ids, fetched_at=excluded.fetched_at, ver=excluded.ver')
    ->execute([$qkey, json_encode($ids), $now, SEARCH_VER]);

emit($out);
