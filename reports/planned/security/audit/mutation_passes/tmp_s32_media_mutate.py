"""Session 32 follow-up b mutation pass: the voice room teardown.

One mutant per guard; each must fail a named test in
test/vc_leave_teardown_test.dart. Prints KILLED / SURVIVED / BROKEN per mutant.

Usage: python tmp_s32_media_mutate.py [M1 M5 ...]   (no ids = every mutant)
"""
import hashlib
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent
VC = ROOT / 'lib/src/core/providers/voice_channel_provider.dart'
TEST = 'test/vc_leave_teardown_test.dart'

T_RACE = 'our own left event landing mid-leave still closes the mesh once'
T_TWICE = 'a repeated forced leave runs one teardown'
T_NEXT = 'each call gets its own teardown'
T_THROW = 'a cleanup step that throws still closes the rest and the mesh'
T_WATCH = 'a watch ending mid-teardown does not abort the share cleanup'
T_FWD = 'a forwarder ingest leg that fails to close strands no other leg'
T_CAM = 'a camera self-view that fails to dispose skips no later phase'

SHARE_GUARDED = """      try {
        await service.close();
      } catch (e) {
        debugPrint('[HOLLOW-VC] screen share close failed: $e');
      }"""

MUTANTS = [
    ('M1 single flight', VC,
     '    if (running != null) return running;',
     '    if (running != null && false) return running;',
     [T_RACE, T_TWICE]),
    ('M2 in-flight never released', VC,
     'if (identical(_teardownInFlight, done.future)) _teardownInFlight = null;',
     'if (false) _teardownInFlight = null;',
     [T_NEXT]),
    ('M3 watches read after the left event', VC,
     '    for (final origin in watched) {',
     '    for (final origin in state.watchingScreenShares) {',
     [T_RACE, T_TWICE]),
    ('M4 a failing phase skips the rest', VC,
     "      debugPrint('[HOLLOW-VC] call teardown ($name) failed: $e');",
     '      rethrow;',
     [T_CAM]),
    ('M5 share maps iterated live', VC,
     """    _outgoingScreenShares.clear();
    _incomingScreenShares.clear();
    for (final service in shares) {
""" + SHARE_GUARDED + """
    }""",
     """    for (final service in _incomingScreenShares.values) {
""" + SHARE_GUARDED + """
    }
    _outgoingScreenShares.clear();
    _incomingScreenShares.clear();""",
     [T_WATCH]),
    ('M6 one share close failure strands the rest', VC,
     SHARE_GUARDED,
     '      await service.close();',
     [T_THROW]),
    ('M7 one ingest leg failure strands the rest', VC,
     """      try {
        await svc.close();
      } catch (e) {
        debugPrint('[HOLLOW-VC] ingest leg to ${branch.forwarderId} '
            'failed to close: $e');
      }""",
     '      await svc.close();',
     [T_FWD]),
    ('M8 mesh never closed', VC,
     '      await mesh?.closeAll();',
     '      mesh?.toString();',
     [T_RACE, T_TWICE, T_NEXT, T_THROW, T_WATCH, T_FWD, T_CAM]),
    ('M9 forced leave tears nothing down', VC,
     """    if (_service != null) {
      // Our own leave is already tearing down and this joins it.""",
     """    if (false) {
      // Our own leave is already tearing down and this joins it.""",
     [T_TWICE, T_NEXT]),
]
ONLY = sys.argv[1:]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run_tests():
    proc = subprocess.run(
        ['powershell', '-NoProfile', '-File',
         str(ROOT / 'scripts' / 'flutter_win.ps1'), 'test', TEST],
        cwd=ROOT, capture_output=True, encoding='utf-8', errors='replace')
    return proc.returncode, proc.stdout + proc.stderr


def main():
    before = digest(VC)
    results = []
    for name, path, old, new, expect in MUTANTS:
        if ONLY and name.split()[0] not in ONLY:
            continue
        original = path.read_bytes()
        text = original.decode('utf-8')
        if '\r\n' in text:
            old, new = old.replace('\n', '\r\n'), new.replace('\n', '\r\n')
        if text.count(old) != 1:
            results.append((name, f'SKIPPED (pattern found {text.count(old)}x)'))
            continue
        path.write_bytes(text.replace(old, new).encode('utf-8'))
        try:
            code, out = run_tests()
        finally:
            path.write_bytes(original)
        failed = [line for line in out.splitlines() if '[E]' in line]
        if code != 0 and not failed:
            verdict = 'BROKEN'
            detail = out[-600:].replace('\n', ' | ')
        else:
            named = [t for t in expect if any(t in line for line in failed)]
            verdict = 'KILLED' if code != 0 and named else 'SURVIVED'
            detail = '; '.join(sorted({l.split(': ', 1)[-1].replace(' [E]', '')
                                      for l in failed}))
        results.append((name, f'{verdict} (exit {code}; failing: {detail})'))
        print(name, verdict, flush=True)
    restored = digest(VC) == before
    print('\n=== RESULTS ===')
    for name, verdict in results:
        print(f'{name}: {verdict}')
    print('sources byte for byte:', 'RESTORED' if restored else 'CHANGED')
    code, out = run_tests()
    print('restored tree:', 'GREEN' if code == 0 else 'RED\n' + out[-2000:])
    return 0


if __name__ == '__main__':
    sys.exit(main())
