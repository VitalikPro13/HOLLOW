<?php
// Hollow — IGDB image media (covers / key art / company logos),
// read-through cache. Warm files in ./covers/ are served directly by
// Apache (see .htaccess) with no PHP in the path; this script runs only on
// a MISS: it validates the name against the `images` registry in games.db
// (only ids search.php has handed out are fetchable — this must never
// become an open proxy), pulls the image from the IGDB CDN once at the
// registered size slug, stores it atomically, and streams it with
// immutable caching.

declare(strict_types=1);

ini_set('display_errors', '0');

const COVERS_DIR = __DIR__ . '/covers';
const DB_FILE    = __DIR__ . '/games.db';
const MAX_BYTES  = 2_000_000;

const MIME = ['jpg' => 'image/jpeg', 'png' => 'image/png'];

function deny(int $code): void {
    http_response_code($code);
    // Short negative cache: a missing/failed image retries in minutes and
    // is never pinned for the immutable year.
    header('Cache-Control: public, max-age=120');
    exit;
}

function image_headers(string $ext, int $length): void {
    header('Content-Type: ' . MIME[$ext]);
    header('Content-Length: ' . $length);
    header('Cache-Control: public, max-age=31536000, immutable');
    header('X-Content-Type-Options: nosniff');
}

function curl_fetch(string $url, ?int &$status = null): ?string {
    $ch = curl_init($url);
    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT        => 15,
        CURLOPT_FOLLOWLOCATION => true,
        CURLOPT_MAXREDIRS      => 3,
    ]);
    $body = curl_exec($ch);
    $status = (int)curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
    curl_close($ch);
    return $body === false ? null : $body;
}

$f = (string)($_GET['f'] ?? '');
if (!preg_match('/^([a-z0-9]{1,40})\.(jpg|png)$/i', $f, $m)) deny(404);
$imageId = $m[1];
$ext = strtolower($m[2]);

// The id must be one search.php has handed out — refuse everything else.
// The size slug comes from OUR registry, never from the request.
$pdo = new PDO('sqlite:' . DB_FILE);
$pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
$pdo->exec('PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;');
$stmt = $pdo->prepare('SELECT size FROM images WHERE image_id = ? AND ext = ?');
$stmt->execute([$imageId, $ext]);
$size = $stmt->fetchColumn();
if ($size === false) deny(404);

$local = COVERS_DIR . "/$imageId.$ext";
if (is_file($local)) {
    // Normally Apache serves warm files before PHP is reached — this covers
    // a race with a parallel cold fetch and direct fetch.php hits.
    image_headers($ext, (int)filesize($local));
    readfile($local);
    exit;
}

if (!is_dir(COVERS_DIR)) @mkdir(COVERS_DIR, 0755, true);
$img = curl_fetch("https://images.igdb.com/igdb/image/upload/$size/$imageId.$ext", $status);
if ($img === null || $status !== 200 || strlen($img) === 0 || strlen($img) > MAX_BYTES) {
    deny(404);
}
// Atomic write (tmp + rename) — a parallel request never reads a partial
// file; a lost race just overwrites with identical bytes.
$tmp = $local . '.tmp.' . getmypid();
if (@file_put_contents($tmp, $img, LOCK_EX) !== false) {
    @rename($tmp, $local);
}
image_headers($ext, strlen($img));
echo $img;
