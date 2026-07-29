<?php
// Hollow — GIF media LRU sweeper. MANDATORY cron, not optional: FFZ is
// ~110 curated emotes at ~50 KB, but the GIF long-tail is unbounded at
// 50–300 KB each, so ./m/ grows forever without this.
//
// Run hourly from the Hostinger cron panel:
//   php /home/<account>/public_html/hollow/gifs/sweep.php
//
// CLI-only (and .htaccess-denied) — there is nothing here for a browser.
//
// What it does:
//   1. Deletes stray atomic-write temps older than an hour.
//   2. If ./m/ exceeds MEDIA_CAP_BYTES, deletes files oldest-first by
//      max(atime, mtime) until 10% under the cap. Where the filesystem
//      updates atime (relatime) this approximates LRU; where it doesn't,
//      it degrades to FIFO — acceptable, because evicting a popular file
//      costs exactly one cheap re-fetch on its next request.
//   3. Prunes expired db rows: rate-valve entries (minutes-lived by
//      design), stale single-flight locks, query rows long past every TTL,
//      and registry rows unreferenced for 45 days (their media, if still
//      warm, keeps being served by Apache until the LRU takes it).

declare(strict_types=1);

if (PHP_SAPI !== 'cli') {
    http_response_code(404);
    exit;
}

const MEDIA_DIR       = __DIR__ . '/m';
const DB_FILE         = __DIR__ . '/gifs.db';
const MEDIA_CAP_BYTES = 4 * 1024 * 1024 * 1024;   // hard cap 4 GB
const QUERY_MAX_AGE   = 30 * 24 * 3600;           // ≫ every serving TTL
const ITEM_MAX_AGE    = 45 * 24 * 3600;

// ── 1 + 2: media dir ────────────────────────────────────────────────────────
$entries = [];
$total = 0;
if (is_dir(MEDIA_DIR)) {
    foreach (scandir(MEDIA_DIR) ?: [] as $name) {
        $path = MEDIA_DIR . '/' . $name;
        if (!is_file($path)) continue;
        if (strpos($name, '.tmp.') !== false) {
            if ((filemtime($path) ?: 0) < time() - 3600) @unlink($path);
            continue;
        }
        $size = filesize($path) ?: 0;
        $entries[] = [
            'path' => $path,
            'size' => $size,
            'used' => max((int)(fileatime($path) ?: 0), (int)(filemtime($path) ?: 0)),
        ];
        $total += $size;
    }
}
$deleted = 0;
$freed = 0;
if ($total > MEDIA_CAP_BYTES) {
    usort($entries, fn($a, $b) => $a['used'] <=> $b['used']);
    $target = (int)(MEDIA_CAP_BYTES * 0.9); // hysteresis: don't sweep every run
    foreach ($entries as $e) {
        if ($total - $freed <= $target) break;
        if (@unlink($e['path'])) {
            $freed += $e['size'];
            $deleted++;
        }
    }
}

// ── 3: db pruning ───────────────────────────────────────────────────────────
$now = time();
$pdo = new PDO('sqlite:' . DB_FILE);
$pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
$pdo->exec('PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;');
foreach ([
    ['ratelimit', 'window_start', 3600],
    ['inflight',  'started_at',   60],
    ['queries',   'fetched_at',   QUERY_MAX_AGE],
    ['items',     'fetched_at',   ITEM_MAX_AGE],
] as [$table, $col, $age]) {
    // Tables predate nothing here (search.php creates them), but a sweep on
    // a fresh install must not error out before the first search.
    try {
        $pdo->prepare("DELETE FROM $table WHERE $col < ?")->execute([$now - $age]);
    } catch (PDOException $e) {
        // table not created yet — nothing to prune
    }
}
$pdo->exec('PRAGMA wal_checkpoint(TRUNCATE)');

// Cron output is emailed/ignored by Hostinger, never served — this is the
// one place a summary line is fine (byte counts only, nothing about users).
echo sprintf(
    "gifs sweep: %d files, %.1f MB total; deleted %d (%.1f MB)\n",
    count($entries), $total / 1048576, $deleted, $freed / 1048576
);
