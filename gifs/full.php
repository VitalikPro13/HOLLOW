<?php
// Hollow — GIF send-time source. Called ONCE per pick: the app downloads
// the best-quality variant through here, re-encodes it into a ≤480px
// content-addressed animated WebP (re-encoding at authoring IS the
// sanitization step), and from then on the bytes replicate purely
// P2P/E2EE — message receivers never touch this endpoint.
//
// Deliberately NOT cached on disk (pick traffic is a tiny fraction of grid
// traffic and the files are the big ones); a 1h shared-cache header lets
// the CDN absorb repeat picks of a trending GIF. The id must be one
// search.php has handed out, and the upstream URL comes from OUR registry,
// never from the request — this must never become an open proxy.

declare(strict_types=1);

ini_set('display_errors', '0');

const DB_FILE   = __DIR__ . '/gifs.db';
const MAX_BYTES = 25_000_000;
// Best-quality-first: the app scales DOWN to ≤480px, so hand it the richest
// source available.
const SLOT_ORDER = ['hd', 'md', 'sm', 'xs'];

const MIME = ['gif' => 'image/gif', 'webp' => 'image/webp'];

function deny(int $code): void {
    http_response_code($code);
    header('Cache-Control: public, max-age=120');
    exit;
}

function curl_fetch(string $url, ?int &$status = null): ?string {
    $ch = curl_init($url);
    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT        => 30,
        CURLOPT_FOLLOWLOCATION => true,
        CURLOPT_MAXREDIRS      => 3,
        CURLOPT_USERAGENT      => 'Hollow-gif-cache/1.0 (+https://hollow.anonlisten.com)',
    ]);
    $body = curl_exec($ch);
    $status = (int)curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
    curl_close($ch);
    return $body === false ? null : $body;
}

// Optional `~` = the sticker id namespace (see search.php). The registry
// lookup below is what authorizes the fetch either way.
$id = (string)($_GET['id'] ?? '');
if (!preg_match('/^~?[A-Za-z0-9_-]{1,100}$/', $id)) deny(404);

$pdo = new PDO('sqlite:' . DB_FILE);
$pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
$pdo->exec('PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;');
$stmt = $pdo->prepare('SELECT src_json FROM items WHERE id = ?');
$stmt->execute([$id]);
$src = $stmt->fetchColumn();
if ($src === false) deny(404);
$file = json_decode((string)$src, true);
if (!is_array($file)) deny(404);

// WebP preferred (smaller for identical quality; the app decodes both).
foreach (SLOT_ORDER as $slot) {
    foreach (['webp', 'gif'] as $fmt) {
        $v = $file[$slot][$fmt] ?? null;
        if (!is_array($v) || !is_string($v['url'] ?? null) || $v['url'] === '') continue;
        $bytes = curl_fetch($v['url'], $status);
        if ($bytes === null || $status !== 200
            || strlen($bytes) === 0 || strlen($bytes) > MAX_BYTES) {
            continue; // oversize/failed — walk down to a smaller variant
        }
        header('Content-Type: ' . MIME[$fmt]);
        header('Content-Length: ' . strlen($bytes));
        header('Cache-Control: public, max-age=3600');
        header('X-Content-Type-Options: nosniff');
        echo $bytes;
        exit;
    }
}
deny(404);
