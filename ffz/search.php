<?php
// Hollow — FrankerFaceZ emote search + global sets, fully write-through
// cached. POST only (GET rejected — keeps search text out of access logs).
// THREE MODES:
//
//   q=<text>   Emote search: ONE FFZ query (sorted by usage), rows cached
//              30 days.
//   curated=1  Hand-picked popular emotes (the picker's default view) —
//              a hardcoded list, so it costs ZERO FFZ API points.
//   global=1   The FFZ global emote sets (effectively static; re-asked
//              weekly). Legacy default — kept as the client's fallback.
//
// METADATA AND MEDIA ARE SEPARATE REQUESTS (v2). Search responses return
// image URLs unconditionally and never download anything inline — a cold
// search is one FFZ API round trip and nothing else. The URLs point at
// ./emotes/; warm files are served directly by Apache, cold ones fall
// through to fetch.php (see .htaccess), which pulls from the FFZ CDN once,
// caches forever, and streams. (v1 downloaded every result's image
// sequentially inside the search request — a cold search stalled 3-6s.)
//
// This endpoint is the ONLY thing that ever talks to FFZ. Hollow clients
// call it at AUTHORING time (browsing the picker's FFZ tab); the moment an
// emote is picked, the app downloads OUR cached image, re-encodes it into a
// content-addressed Hollow blob, and it replicates purely P2P. Viewers never
// contact FFZ, its CDN, or this endpoint — FFZ never learns a user's IP
// beyond the person actively browsing the catalog (and with this proxy, not
// even theirs: all upstream traffic comes from the web server).
//
// RATE LIMITS: FFZ unauthenticated = 120 points/min PER IP (GCRA leaky
// bucket) — and through this proxy every user shares the server's ONE
// bucket, so caching is mandatory, not polite. Every search hits the FFZ
// API at most once ever (30d TTL); on a 429 we honor Retry-After with a
// stored backoff and serve from cache only. (Image fetches ride the CDN,
// not the API — they don't spend points.)
//
// Deploy: upload this folder (search.php, fetch.php, .htaccess) to
// /public_html/hollow/ffz/ (no credentials needed — the FFZ v1 API is
// public).

declare(strict_types=1);

ini_set('display_errors', '0');

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

const EMOTES_DIR = __DIR__ . '/emotes';
const EMOTES_URL = 'https://hollow.anonlisten.com/ffz/emotes/';
const DB_FILE    = __DIR__ . '/ffz.db';
const SEARCH_TTL = 30 * 24 * 3600;  // re-ask upstream after 30 days
const GLOBAL_TTL = 7 * 24 * 3600;   // global sets barely change
const GLOBAL_KEY = "\x00global";    // searches-table key for the global sets
const MAX_ROWS   = 36;              // one picker page
// Bump when the response schema changes — older cached rows refetch.
// v2: read-through media — rows return URLs unconditionally; bytes are
//     pulled by fetch.php on first image request, never inside a search.
const SEARCH_VER = 2;

// The picker's default view: ~110 hand-curated popular Twitch emotes.
// Backbone = FFZ's own most-used emotes (sort=count-desc, 2026-07), plus
// guaranteed slots for iconic BTTV/7TV-culture names (catJAM, Clueless,
// xdd, blobDance…) that FFZ hosts but ranks lower. Rows are
// [id, name, owner, animated, usage] — all metadata is baked in, so this
// mode NEVER touches the FFZ API, only its image CDN (once per emote,
// via fetch.php).
const CURATED = [
    [128054, 'OMEGALUL', 'DourGent', 0, 212917],
    [210748, 'Pog', 'Teyn', 0, 193931],
    [231552, 'PepeHands', 'igoresque', 0, 171984],
    [270930, 'widepeepoHappy', 'black__tic_tac', 0, 161895],
    [139407, 'LULW', 'Ian678', 0, 153004],
    [243789, 'Pepega', 'adew', 0, 152775],
    [381875, 'KEKW', 'Keesual', 0, 149599],
    [214681, 'monkaW', 'voparoS_', 0, 144798],
    [239504, '5Head', 'SublimedTV', 0, 137333],
    [214129, 'POGGERS', 'Klotzi', 0, 133464],
    [130762, 'monkaS', 'FabulousPotato69', 0, 124718],
    [162146, 'AYAYA', 'FoveVever', 0, 117399],
    [64785, 'PepeLaugh', 'Lukas_Wergutz', 0, 113322],
    [303899, 'widepeepoSad', 'rSHERMS', 0, 110711],
    [425196, 'Sadge', 'vicneeI', 0, 103214],
    [33355, 'FeelsBadMan', 'Urboymag', 0, 101997],
    [236895, 'HYPERS', 'Ruse69Master', 0, 96483],
    [418189, 'YEP', 'yaYEET_xD', 0, 89003],
    [145947, 'FeelsOkayMan', 'nitrousgranola', 0, 84634],
    [218860, 'Kapp', 'Teyn', 0, 79053],
    [185890, 'EZY', 'baxx', 0, 78968],
    [229760, 'HandsUp', 'Zugren', 0, 74105],
    [174942, 'PepoThink', 'Taliiz', 0, 71546],
    [274406, '3Head', 'timmytoina', 0, 67993],
    [131597, 'FeelsWeirdMan', 'baxx', 0, 67063],
    [240746, 'monkaHmm', 'Klotzi', 0, 65496],
    [145916, 'KKomrade', 'igoresque', 0, 56490],
    [218530, 'PepoG', 'Ludw1G', 0, 55018],
    [167431, 'monkaOMEGA', 'KaiOwei', 0, 54971],
    [187256, 'monkaGun', 'DevinIsDead', 0, 54032],
    [262458, 'peepoBlanket', 'multigrain_cheerios', 0, 53655],
    [268204, 'monkaEyes', 'libertyass', 0, 53063],
    [64210, 'FeelsStrongMan', 'Lukas_Wergutz', 0, 52775],
    [228449, 'peepoHappy', 'Klotzi', 0, 50243],
    [204717, 'HYPERBRUH', 'Goran42069', 0, 49747],
    [237857, 'monkaTOS', 'voparoS_', 0, 47901],
    [250614, 'peepoLove', 'voparoS_', 0, 47469],
    [165742, 'weSmart', 'PhatSaM', 0, 47203],
    [109777, 'FeelsGoodMan', 'Pauliii23', 0, 46323],
    [229486, 'KKonaW', 'FabulousPotato69', 0, 43301],
    [536927, 'FeelsDankMan', 'icdb', 0, 42928],
    [116831, 'REEeee', 'Shin_The_Cat', 0, 41405],
    [390750, 'KEKWait', 'foxboxx', 0, 39366],
    [507766, 'Prayge', 'prayge_boi', 0, 29179],
    [230082, 'peepoSad', 'Nclnat', 0, 28748],
    [47399, 'YouDied', 'レボ', 0, 25731],
    [298485, 'pikachuS', 'Ktr4ks_', 0, 23654],
    [318914, 'peepoClown', 'nis5e', 0, 22849],
    [563443, 'COPIUM', 'Guzu', 0, 22535],
    [457124, 'WICKED', 'SeVeJj', 0, 20607],
    [510861, 'Madge', 'H3RRRO', 0, 20139],
    [267880, 'peepoWTF', 'Froxtea', 0, 19238],
    [421124, 'WeirdChamp', 'sundizzle', 0, 18672],
    [257284, 'POGGIES', 'CleanBin', 0, 18504],
    [28798, 'PressF', 'NaedPlays', 0, 17572],
    [557676, 'PauseChamp', 'REZN0R', 0, 16980],
    [227992, 'Pepepains', 'Karl_Kons', 0, 16769],
    [410314, 'Okayge', 'pajlada', 0, 16419],
    [191246, 'Thonk', 'oskart', 0, 15335],
    [308193, '4Weird', 'NyroLoL', 0, 14936],
    [120593, 'TRIGGERED', 'vegashi269', 0, 14421],
    [337645, 'widepeepoBlanket', 'owmyneck', 0, 13809],
    [244322, 'PeepoGlad', 'RuneBiegelPedersen', 0, 12802],
    [428011, 'Stonks', 'Stefik_O', 0, 12368],
    [341427, 'pepeJAM', 'm60_', 0, 12295],
    [405602, 'Hmm', 'BenceFoldi', 0, 12103],
    [517647, 'PagMan', 'endmylife64', 0, 11524],
    [67872, 'ThisIsFine', 'ChaosShadowMKW', 0, 10576],
    [377799, 'pepePoint', 'Ruh_', 0, 10135],
    [298847, 'Clap', 'qnhp', 0, 9146],
    [590443, 'Bedge', 'emerc0m', 0, 9054],
    [237403, 'peepoHug', 'Teaguenho', 0, 9053],
    [214658, 'PepeLmao', 'Vycilien', 0, 8981],
    [70179, 'FacePalm', 'The_Shed_Arcade', 0, 8651],
    [167498, 'KKona', 'nitrousgranola', 0, 8350],
    [201244, 'pepeGun', 'voparoS_', 0, 7924],
    [475175, 'Susge', 'vicneeI', 0, 7834],
    [357348, 'SadCat', 'sunred_', 0, 7598],
    [337787, 'widepeepoHug', 'HelixFlame', 0, 7354],
    [444667, 'dankHug', 'tataxmei', 0, 6076],
    [556604, 'PogO', 'MAKKUSU', 0, 5751],
    [600212, 'Wokege', 'aftonXY', 0, 4807],
    [652079, 'Clueless', 'tomso', 0, 4018],
    [332541, 'peepoRiot', 'senkerai', 0, 3386],
    [411818, 'Weirdge', 'Eduaard', 0, 3155],
    [564062, 'catJAM', 'Erkkthebeast', 0, 3047],
    [469502, 'LETSGO', 'Saluth_', 0, 2875],
    [422810, 'PogU', 'ali2465', 0, 2505],
    [354434, 'Gigachad', 'mofumoufu', 0, 2460],
    [569240, 'ICANT', 'PendrivE', 0, 1952],
    [319304, 'pepeD', 'WalmsleyGames', 0, 1805],
    [518983, 'Booba', 'gooeygoon_', 0, 1477],
    [334008, 'peepoRun', 'baoryo', 0, 1467],
    [302083, 'PeepoGiggle', 'Zyth_Dr', 0, 1042],
    [226921, 'monkaX', 'sleepyspaceraccoon', 0, 998],
    [474605, 'peepoLeave', 'Luuuwun', 0, 841],
    [704227, 'Xdd', 'Cinnamonclown54', 0, 465],
    [724093, 'ratJAM', 'mrchonks', 1, 410],
    [725690, 'blobDance', 'RodsKaden', 1, 316],
    [302960, 'YIKES', 'Weest', 0, 276],
    [720817, 'NODDERS', 'TrippyColour', 1, 275],
    [380518, 'Jebaited', 'NinjaMushroom', 0, 272],
    [720568, 'modCheck', 'ZonianMidian', 1, 272],
    [676592, 'Aware', 'tomso', 0, 270],
    [580668, 'Hopium', 'AuliaU', 0, 244],
    [720563, 'catKISS', 'ZonianMidian', 1, 228],
    [546916, 'STARE', 'Olajvr', 0, 148],
    [725721, 'NOPERS', 'RodsKaden', 1, 143],
    [720579, 'NOTED', 'ZonianMidian', 1, 129],
    [720572, 'VIBE', 'ZonianMidian', 1, 110],
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
        $pdo->exec('CREATE TABLE IF NOT EXISTS emotes (
            id         INTEGER PRIMARY KEY,
            name       TEXT NOT NULL,
            owner      TEXT NOT NULL DEFAULT \'\',
            animated   INTEGER NOT NULL DEFAULT 0,
            usage      INTEGER NOT NULL DEFAULT 0,
            ext        TEXT NOT NULL DEFAULT \'png\',
            fetched_at INTEGER NOT NULL
        )');
        $pdo->exec('CREATE TABLE IF NOT EXISTS searches (
            q          TEXT PRIMARY KEY,
            emote_ids  TEXT NOT NULL,
            ver        INTEGER NOT NULL DEFAULT 0,
            fetched_at INTEGER NOT NULL
        )');
        // Single-row odds and ends (429 backoff deadline).
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

/// True while a stored FFZ 429 backoff is active — serve cache only.
function in_backoff(): bool {
    $until = (int)(meta_get('backoff_until') ?? '0');
    return $until > time();
}

function curl_req(string $url, ?int &$status = null, ?array &$headers = null): ?string {
    $collected = [];
    $ch = curl_init($url);
    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT        => 15,
        CURLOPT_FOLLOWLOCATION => true,
        CURLOPT_MAXREDIRS      => 3,
        CURLOPT_USERAGENT      => 'Hollow-emote-cache/1.0 (+https://hollow.anonlisten.com)',
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

/// One FFZ API call with 429 backoff handling. Returns decoded JSON or null.
function ffz_query(string $path): ?array {
    if (in_backoff()) return null;
    $body = curl_req('https://api.frankerfacez.com/v1/' . $path, $status, $headers);
    if ($status === 429) {
        $retry = (int)($headers['retry-after'] ?? 60);
        meta_set('backoff_until', (string)(time() + max(5, min(3600, $retry))));
        return null;
    }
    if ($body === null || $status < 200 || $status >= 300) return null;
    $j = json_decode($body, true);
    return is_array($j) ? $j : null;
}

/// Ext already recorded for an id ('' when the id is new). fetch.php owns
/// this column after first insert: animated emotes default to 'gif' but can
/// fall back to 'webp' when the CDN has no GIF variant — that discovery
/// must survive re-ingest, or handed-out URLs flip back to a dead .gif.
function recorded_ext(int $id): string {
    $stmt = db()->prepare('SELECT ext FROM emotes WHERE id = ?');
    $stmt->execute([$id]);
    $v = $stmt->fetchColumn();
    return $v === false ? '' : (string)$v;
}

/// Normalize one FFZ emoticon object into a cached row + response row.
/// No download happens here — the URL is handed out unconditionally and
/// fetch.php materializes the bytes on first request.
function ingest_emote(array $e, int $now): ?array {
    $id = (int)($e['id'] ?? 0);
    $name = (string)($e['name'] ?? '');
    if ($id <= 0 || $name === '') return null;
    $owner = '';
    if (is_array($e['owner'] ?? null)) {
        $owner = (string)($e['owner']['display_name'] ?? $e['owner']['name'] ?? '');
    }
    $animated = !empty($e['animated']);
    $usage = (int)($e['usage_count'] ?? 0);

    $ext = recorded_ext($id);
    if ($ext === '') $ext = $animated ? 'gif' : 'png';

    // ext deliberately NOT updated on conflict — see recorded_ext().
    db()->prepare('INSERT INTO emotes (id, name, owner, animated, usage, ext, fetched_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            name=excluded.name, owner=excluded.owner, animated=excluded.animated,
            usage=excluded.usage, fetched_at=excluded.fetched_at')
        ->execute([$id, mb_substr($name, 0, 64), mb_substr($owner, 0, 64),
                   $animated ? 1 : 0, $usage, $ext, $now]);

    return [
        'id' => $id, 'name' => $name, 'owner' => $owner,
        'animated' => $animated, 'url' => EMOTES_URL . "$id.$ext", 'usage' => $usage,
    ];
}

function emote_row_to_json(array $row): array {
    return [
        'id'       => (int)$row['id'],
        'name'     => (string)$row['name'],
        'owner'    => (string)$row['owner'],
        'animated' => (bool)$row['animated'],
        'url'      => EMOTES_URL . $row['id'] . '.' . $row['ext'],
        'usage'    => (int)$row['usage'],
    ];
}

function serve_cached_search(string $qkey, int $ttl): void {
    $now = time();
    $stmt = db()->prepare('SELECT emote_ids, fetched_at, ver FROM searches WHERE q = ?');
    $stmt->execute([$qkey]);
    $hit = $stmt->fetch(PDO::FETCH_ASSOC);
    if (!$hit || (int)$hit['ver'] !== SEARCH_VER || (int)$hit['fetched_at'] <= $now - $ttl) {
        // Stale — but if FFZ is rate-limiting us, stale beats nothing.
        if (!$hit || !in_backoff()) return;
    }
    $ids = json_decode((string)$hit['emote_ids'], true) ?: [];
    if (!$ids) { emit([]); }
    $ph = implode(',', array_fill(0, count($ids), '?'));
    $g = db()->prepare("SELECT * FROM emotes WHERE id IN ($ph)");
    $g->execute($ids);
    $byId = [];
    foreach ($g->fetchAll(PDO::FETCH_ASSOC) as $row) {
        $byId[(int)$row['id']] = $row;
    }
    $out = [];
    foreach ($ids as $id) { // preserve upstream relevance order
        if (isset($byId[(int)$id])) {
            $out[] = emote_row_to_json($byId[(int)$id]);
        }
    }
    emit($out);
}

function store_search(string $qkey, array $ids): void {
    db()->prepare('INSERT INTO searches (q, emote_ids, ver, fetched_at) VALUES (?, ?, ?, ?)
        ON CONFLICT(q) DO UPDATE SET emote_ids=excluded.emote_ids,
            ver=excluded.ver, fetched_at=excluded.fetched_at')
        ->execute([$qkey, json_encode($ids), SEARCH_VER, time()]);
}

function emit(array $payload): void {
    echo json_encode($payload, JSON_INVALID_UTF8_SUBSTITUTE);
    exit;
}

$now = time();

// ═══ MODE C: curated=1 — hand-picked popular defaults (see CURATED). ═══
// Zero FFZ API cost and zero downloads: every row is returned immediately;
// images warm up through fetch.php as clients actually render them. Rows
// are registered in the db so fetch.php's id check accepts them.
if (param('curated') !== '') {
    $pdo = db();
    $ids = array_column(CURATED, 0);
    $ph = implode(',', array_fill(0, count($ids), '?'));
    $stmt = $pdo->prepare("SELECT id, ext FROM emotes WHERE id IN ($ph)");
    $stmt->execute($ids);
    $extById = [];
    foreach ($stmt->fetchAll(PDO::FETCH_ASSOC) as $r) {
        $extById[(int)$r['id']] = (string)$r['ext'];
    }

    $pdo->beginTransaction();
    // ext deliberately NOT updated on conflict — see recorded_ext().
    $ins = $pdo->prepare('INSERT INTO emotes (id, name, owner, animated, usage, ext, fetched_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            name=excluded.name, owner=excluded.owner, animated=excluded.animated,
            usage=excluded.usage')
        ;
    $out = [];
    foreach (CURATED as [$id, $cname, $cowner, $canim, $cusage]) {
        $ext = $extById[$id] ?? ($canim === 1 ? 'gif' : 'png');
        $ins->execute([$id, $cname, $cowner, $canim, $cusage, $ext, $now]);
        $out[] = [
            'id' => $id, 'name' => $cname, 'owner' => $cowner,
            'animated' => $canim === 1,
            'url' => EMOTES_URL . "$id.$ext", 'usage' => $cusage,
        ];
    }
    $pdo->commit();
    emit($out);
}

// ═══ MODE B: global=1 — the FFZ global emote sets. ═══
if (param('global') !== '') {
    serve_cached_search(GLOBAL_KEY, GLOBAL_TTL);

    $j = ffz_query('set/global');
    if ($j === null) {
        // Upstream down / backoff and no cache — empty, never an error page.
        emit([]);
    }
    $out = [];
    $ids = [];
    foreach (($j['sets'] ?? []) as $set) {
        foreach (($set['emoticons'] ?? []) as $e) {
            if (!is_array($e)) continue;
            $row = ingest_emote($e, $now);
            if ($row !== null) {
                $out[] = $row;
                $ids[] = $row['id'];
            }
        }
    }
    store_search(GLOBAL_KEY, $ids);
    emit($out);
}

// ═══ MODE A: q= — emote search, most-used first. ═══
$q = param('q');
if ($q === '' || mb_strlen($q) > 64) {
    emit([]);
}
$qkey = mb_strtolower(preg_replace('/\s+/u', ' ', $q));

serve_cached_search($qkey, SEARCH_TTL);

$j = ffz_query('emoticons?q=' . rawurlencode($q) . '&sort=count-desc&per_page=' . MAX_ROWS . '&page=1');
if ($j === null) {
    emit([]);
}
$out = [];
$ids = [];
foreach (($j['emoticons'] ?? []) as $e) {
    if (!is_array($e)) continue;
    $row = ingest_emote($e, $now);
    if ($row !== null) {
        $out[] = $row;
        $ids[] = $row['id'];
    }
}
store_search($qkey, $ids);
emit($out);
