"""HOL-SEC-116 mutation pass: one mutant per rule, each must fail a named test.

Usage: python tmp_s31_dartfile_mutate.py [M1 M5 ...]   (no ids = every mutant)
"""
import hashlib
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent
INTAKE = ROOT / 'lib/src/core/services/rtc_stream_intake.dart'
SERVICE = ROOT / 'lib/src/core/services/webrtc_service.dart'

MUTANTS = [
    ('M1 ceiling', INTAKE, 'if (totalSize > limit) {', 'if (false) {',
     'a stream declaring past the send limit is refused before it opens'),
    ('M2 first frame past its size', INTAKE, 'if (firstPayload > totalSize) {', 'if (false) {',
     'a first frame carrying more than its declared size is refused'),
    ('M3 continuation sender', INTAKE,
     'if (stream == null || stream.sender != sender) return RtcChunk.drop;',
     'if (stream == null) return RtcChunk.drop;',
     'a continuation from another connection never touches the stream'),
    ('M4 live holder', INTAKE, 'held.sender != sender &&', 'false &&',
     "another connection's first frame cannot replace a live stream"),
    ('M5 lane in the sender key', SERVICE,
     "_streamSender(String peerId, _Lane lane) =>\r\n      lane == _Lane.share ? '$peerId#share' : peerId;",
     "_streamSender(String peerId, _Lane lane) =>\r\n      peerId;",
     'continuations are judged before a byte is written'),
    ('M6 overflow', INTAKE,
     'if (received > stream.totalSize) return RtcChunk.overflow;',
     'if (received > stream.totalSize) return RtcChunk.complete;',
     'bytes past the declared size fail the stream'),
    ('M7 per-sender cap', INTAKE,
     'while (kept.values.where((s) => s.sender == sender).length >=',
     'while (false && kept.values.where((s) => s.sender == sender).length >=',
     'a sender keeps at most its share and pays with its own stalest'),
    ('M8 total cap', INTAKE, 'while (kept.length >= kMaxRtcStreams) {', 'while (false) {',
     'past the total the heaviest sender pays, never a light one'),
    ('M8b newcomer pays instead of the heaviest', INTAKE,
     'final victim = stalestOf(heaviest);', 'final victim = stalestOf(sender);',
     'past the total the heaviest sender pays, never a light one'),
    ('M9 send slots', INTAKE, 'if (_busy < max) {', 'if (true) {',
     'one connection sends at most its share at once'),
    ('M10 service ignores a refusal', SERVICE, 'if (open.refusal != null) {', 'if (false) {',
     'a first frame is judged before its temp file opens'),
    ('M11 service writes a dropped continuation', SERVICE,
     'if (verdict == RtcChunk.drop) {', 'if (verdict == RtcChunk.drop && false) {',
     'continuations are judged before a byte is written'),
    ('M12 service evictions skipped', SERVICE, '_discardTransfer(stale);', '',
     'a first frame is judged before its temp file opens'),
    ('M13 sends take no slot', SERVICE, 'await conn.sendSlots.acquire();', '',
     'sends hold a slot of their connection'),
    ('M13b a send keeps its slot', SERVICE, '      conn.sendSlots.release();', '',
     'sends hold a slot of their connection'),
]
ONLY = sys.argv[1:]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run_tests():
    proc = subprocess.run(
        ['powershell', '-File', str(ROOT / 'scripts' / 'flutter_win.ps1'),
         'test', 'test/rtc_stream_intake_test.dart'],
        cwd=ROOT, capture_output=True, encoding='utf-8', errors='replace')
    return proc.returncode, proc.stdout + proc.stderr


def main():
    before = {p: digest(p) for p in (INTAKE, SERVICE)}
    results = []
    for name, path, old, new, expect in MUTANTS:
        if ONLY and name.split()[0] not in ONLY:
            continue
        original = path.read_bytes()
        text = original.decode('utf-8')
        if text.count(old) != 1:
            results.append((name, f'SKIPPED (pattern found {text.count(old)}x)'))
            continue
        path.write_bytes(text.replace(old, new).encode('utf-8'))
        try:
            code, out = run_tests()
        finally:
            path.write_bytes(original)
        failed = [line for line in out.splitlines() if '[E]' in line]
        named = any(expect in line for line in failed)
        verdict = 'KILLED' if code != 0 and named else 'SURVIVED'
        results.append((name, f'{verdict} (exit {code}; failing: '
                              f'{"; ".join(sorted({l.split(": ", 1)[-1] for l in failed}))})'))
        print(name, verdict, flush=True)
    restored = all(digest(p) == h for p, h in before.items())
    print('\n=== RESULTS ===')
    for name, verdict in results:
        print(f'{name}: {verdict}')
    print('sources byte for byte:', 'RESTORED' if restored else 'CHANGED')
    code, out = run_tests()
    print('restored tree:', 'GREEN' if code == 0 else 'RED\n' + out[-2000:])
    return 0


if __name__ == '__main__':
    sys.exit(main())
