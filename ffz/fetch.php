<?php
// Hollow — FFZ emote media, read-through cache. Warm files in ./emotes/
// are served directly by Apache (see .htaccess) with no PHP in the path;
// this script runs only on a MISS: it validates the name against ffz.db
// (only ids search.php has handed out are fetchable — this must never
// become an open proxy), pulls the image from the FFZ CDN once, stores it
// atomically, and streams it with immutable caching.
//
// Animated emotes: the CDN's GIF variant is preferred (the app re-encodes
// GIF → animated WebP at import); when only WebP exists we store/serve
// that and record the ext so search.php hands out .webp URLs from then on.

declare(strict_types=1);

ini_set('display_errors', '0');

const EMOTES_DIR = __DIR__ . '/emotes';
const DB_FILE    = __DIR__ . '/ffz.db';
const MAX_BYTES  = 4_000_000;

const MIME = ['png' => 'image/png', 'gif' => 'image/gif', 'webp' => 'image/webp'];

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

function serve_file(string $path, string $ext): void {
    image_headers($ext, (int)filesize($path));
    readfile($path);
    exit;
}

function curl_fetch(string $url, ?int &$status = null): ?string {
    $ch = curl_init($url);
    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT        => 15,
        CURLOPT_FOLLOWLOCATION => true,
        CURLOPT_MAXREDIRS      => 3,
        CURLOPT_USERAGENT      => 'Hollow-emote-cache/1.0 (+https://hollow.anonlisten.com)',
    ]);
    $body = curl_exec($ch);
    $status = (int)curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
    curl_close($ch);
    return $body === false ? null : $body;
}

$f = (string)($_GET['f'] ?? '');
if (!preg_match('/^([0-9]{1,12})\.(png|gif|webp)$/', $f, $m)) deny(404);
$id = (int)$m[1];
$reqExt = $m[2];

// The id must be one search.php has returned — refuse everything else.
$pdo = new PDO('sqlite:' . DB_FILE);
$pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
$pdo->exec('PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;');
$stmt = $pdo->prepare('SELECT animated, ext FROM emotes WHERE id = ?');
$stmt->execute([$id]);
$row = $stmt->fetch(PDO::FETCH_ASSOC);
if (!$row) deny(404);
$animated = (int)$row['animated'] === 1;
$dbExt = (string)$row['ext'];

// Anything already on disk for this id wins (the recorded ext may differ
// from the requested one — an animated GIF may have fallen back to WebP).
$candidates = array_values(array_unique(array_merge(
    [$reqExt, $dbExt],
    $animated ? ['gif', 'webp'] : ['png'],
)));
foreach ($candidates as $ext) {
    if (!isset(MIME[$ext])) continue;
    $local = EMOTES_DIR . "/$id.$ext";
    if (is_file($local)) serve_file($local, $ext);
}

// Cold — pull from the FFZ CDN (stills: size 2 PNG; animated: GIF variant
// first, default animated format (WebP) as fallback).
if (!is_dir(EMOTES_DIR)) @mkdir(EMOTES_DIR, 0755, true);
$chain = $animated
    ? ["https://cdn.frankerfacez.com/emote/$id/animated/2.gif" => 'gif',
       "https://cdn.frankerfacez.com/emote/$id/animated/2"     => 'webp']
    : ["https://cdn.frankerfacez.com/emote/$id/2" => 'png'];
if ($animated && $dbExt === 'webp') {
    // A previous fetch already learned the GIF variant is absent.
    $chain = array_reverse($chain, true);
}
foreach ($chain as $url => $ext) {
    $img = curl_fetch($url, $status);
    if ($img === null || $status !== 200 || strlen($img) === 0 || strlen($img) > MAX_BYTES) {
        continue;
    }
    $local = EMOTES_DIR . "/$id.$ext";
    // Atomic write (tmp + rename) — a parallel request never reads a
    // partial file; a lost race just overwrites with identical bytes.
    $tmp = $local . '.tmp.' . getmypid();
    if (@file_put_contents($tmp, $img, LOCK_EX) !== false) {
        @rename($tmp, $local);
    }
    if ($ext !== $dbExt) {
        $pdo->prepare('UPDATE emotes SET ext = ? WHERE id = ?')->execute([$ext, $id]);
    }
    image_headers($ext, strlen($img));
    echo $img;
    exit;
}
deny(404);
