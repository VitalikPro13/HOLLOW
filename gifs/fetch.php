<?php
// Hollow — GIF grid media (still + small animated variants), read-through
// cache. Warm files in ./m/ are served directly by Apache (see .htaccess)
// with no PHP in the path; this script runs only on a MISS: it validates
// the name against the `items` registry in gifs.db (only ids search.php
// has handed out are fetchable, and the upstream URL comes from OUR
// registry, never from the request — this must never become an open
// proxy), pulls from the Klipy CDN once, stores atomically, and streams
// with immutable caching.
//
// Variants:
//   <id>.still.webp  first animation frame, ≤150px wide, GENERATED here
//                    (Klipy has no still format) — the grid shows stills
//                    and animates only what is visible, which is the
//                    single biggest bandwidth lever in the whole feature.
//   <id>.sm.<ext>    Klipy's small animated variant, passed through.
//
// The send-time source ("full") is full.php — deliberately separate, it is
// never cached on disk.

declare(strict_types=1);

ini_set('display_errors', '0');

const MEDIA_DIR   = __DIR__ . '/m';
const DB_FILE     = __DIR__ . '/gifs.db';
const MAX_BYTES   = 6_000_000;
const STILL_WIDTH = 150;
const SIZE_SLOTS  = ['sm', 'xs', 'md', 'hd'];

const MIME = ['gif' => 'image/gif', 'webp' => 'image/webp'];

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
        CURLOPT_USERAGENT      => 'Hollow-gif-cache/1.0 (+https://hollow.anonlisten.com)',
    ]);
    $body = curl_exec($ch);
    $status = (int)curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
    curl_close($ch);
    return $body === false ? null : $body;
}

/// First upstream URL of format $fmt walking the size slots smallest-first.
function upstream_url(array $file, string $fmt): ?string {
    foreach (SIZE_SLOTS as $slot) {
        $v = $file[$slot][$fmt] ?? null;
        if (is_array($v) && is_string($v['url'] ?? null) && $v['url'] !== '') {
            return $v['url'];
        }
    }
    return null;
}

function fetch_first(array $urls): ?string {
    foreach ($urls as $url) {
        $bytes = curl_fetch($url, $status);
        if ($bytes !== null && $status === 200
            && strlen($bytes) > 0 && strlen($bytes) <= MAX_BYTES) {
            return $bytes;
        }
    }
    return null;
}

/// Atomic write (tmp + rename) — a parallel request never reads a partial
/// file; a lost race just overwrites with identical bytes.
function store(string $local, string $bytes): void {
    $tmp = $local . '.tmp.' . getmypid();
    if (@file_put_contents($tmp, $bytes, LOCK_EX) !== false) {
        @rename($tmp, $local);
    }
}

function serve_bytes(string $local, string $ext, string $bytes): void {
    store($local, $bytes);
    image_headers($ext, strlen($bytes));
    echo $bytes;
    exit;
}

/// First frame of $bytes → WebP still, ≤STILL_WIDTH wide. GD first (reads
/// GIF frame 1 natively), Imagick as fallback (also handles animated WebP
/// input). Null when neither can — the caller degrades to the animated sm.
function make_still(string $bytes, bool $isGif): ?string {
    if ($isGif && function_exists('imagecreatefromstring') && function_exists('imagewebp')) {
        $im = @imagecreatefromstring($bytes);
        if ($im !== false) {
            @imagepalettetotruecolor($im);
            $w = imagesx($im);
            if ($w > STILL_WIDTH) {
                $scaled = @imagescale($im, STILL_WIDTH);
                if ($scaled !== false) {
                    imagedestroy($im);
                    $im = $scaled;
                }
            }
            ob_start();
            $ok = @imagewebp($im, null, 80);
            $out = ob_get_clean();
            imagedestroy($im);
            if ($ok && is_string($out) && $out !== '') return $out;
        }
    }
    if (class_exists('Imagick')) {
        try {
            $im = new Imagick();
            $im->readImageBlob($bytes);
            $im->setIteratorIndex(0);
            $frame = $im->getImage();
            if ($frame->getImageWidth() > STILL_WIDTH) {
                $frame->scaleImage(STILL_WIDTH, 0);
            }
            $frame->setImageFormat('webp');
            $frame->setImageCompressionQuality(80);
            $out = $frame->getImageBlob();
            $im->clear();
            if (is_string($out) && $out !== '') return $out;
        } catch (Throwable $e) {
            // fall through to the degraded path
        }
    }
    return null;
}

$f = (string)($_GET['f'] ?? '');
if (!preg_match('/^([A-Za-z0-9_-]{1,100})\.(still|sm)\.(webp|gif)$/', $f, $m)) deny(404);
$id = $m[1];
$variant = $m[2];
$reqExt = $m[3];

// The id must be one search.php has handed out — refuse everything else.
$pdo = new PDO('sqlite:' . DB_FILE);
$pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
$pdo->exec('PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;');
$stmt = $pdo->prepare('SELECT sm_ext, src_json FROM items WHERE id = ?');
$stmt->execute([$id]);
$row = $stmt->fetch(PDO::FETCH_ASSOC);
if (!$row) deny(404);
$smExt = (string)$row['sm_ext'];
$file = json_decode((string)$row['src_json'], true);
if (!is_array($file)) deny(404);

// The ext is fixed by the registry (stills are always webp; sm is whatever
// search.php recorded) — a URL asking for anything else was not handed out.
if ($variant === 'still' ? ($reqExt !== 'webp') : ($reqExt !== $smExt)) deny(404);

$local = MEDIA_DIR . "/$id.$variant.$reqExt";
if (is_file($local)) {
    // Normally Apache serves warm files before PHP is reached — this covers
    // a race with a parallel cold fetch and direct fetch.php hits.
    image_headers($reqExt, (int)filesize($local));
    readfile($local);
    exit;
}
if (!is_dir(MEDIA_DIR)) @mkdir(MEDIA_DIR, 0755, true);

if ($variant === 'sm') {
    $url = upstream_url($file, $smExt);
    if ($url === null) deny(404);
    $bytes = fetch_first([$url]);
    if ($bytes === null) deny(404);
    serve_bytes($local, $smExt, $bytes);
}

// still: prefer a GIF source (GD decodes frame 1 natively), fall back to
// the WebP source under Imagick.
$gifUrl = upstream_url($file, 'gif');
$webpUrl = upstream_url($file, 'webp');
$bytes = null;
$isGif = false;
if ($gifUrl !== null) {
    $bytes = fetch_first([$gifUrl]);
    $isGif = $bytes !== null;
}
if ($bytes === null && $webpUrl !== null) {
    $bytes = fetch_first([$webpUrl]);
}
if ($bytes === null) deny(404);
$still = make_still($bytes, $isGif);
if ($still !== null) {
    serve_bytes($local, 'webp', $still);
}
// Degraded path (no GD-webp, no Imagick): the animated small WebP stands in
// for the still — wrong motion, right pixels, never a broken image. Only
// possible when a WebP source exists (the MIME must match the .webp URL).
if ($webpUrl !== null) {
    $anim = $isGif ? fetch_first([$webpUrl]) : $bytes;
    if ($anim !== null) serve_bytes($local, 'webp', $anim);
}
deny(404);
