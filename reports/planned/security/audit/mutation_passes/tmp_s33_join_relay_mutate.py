"""Session 33 relay mutation pass (HOL-SEC-121, the catch-up end mark): break each rule
of `handle_topic_catchup`'s mark, run the live tests (one build), expect a named check to
FAIL, restore byte for byte. Runs on the relay box (Linux):
    python3 tmp_s33_join_relay_mutate.py <relay-uws/test directory>
"""
import os
import subprocess
import sys

HERE = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), 'relay-uws', 'test')
WS = os.path.join(HERE, '..', 'src', 'ws_handler.cpp')
MARK = '        send_json(ws, {{"type", "topic_catchup_done"}, {"room", room}, {"channel", channel}});\n'

MUTATIONS = [
    # The baseline: a relay from before the mark (the RED of the live checks).
    ('no mark at all',
     'if (end != j.end() && end->is_boolean() && end->get<bool>()) {', 'if (false) {',
     'a catch-up that asks for its end gets the mark'),
    ('marked though not asked',
     'if (end != j.end() && end->is_boolean() && end->get<bool>()) {', 'if (true) {',
     'a catch-up that does not ask gets the replay and no mark'),
    ('marked ahead of the replay',
     '    if (it != state.topic_buffers.end()) {\n        // Age filter',
     '    if (j.contains("end")) {\n    ' + MARK + '    }\n    if (it != state.topic_buffers.end()) {\n        // Age filter',
     'behind every frame of the replay'),
    ('an empty ring is never marked',
     '    if (it != state.topic_buffers.end()) {\n        // Age filter',
     '    if (it == state.topic_buffers.end()) return;\n    {\n        // Age filter',
     'a ring the relay never kept is marked too'),
    ('any end asks for the mark',
     'end->is_boolean() && end->get<bool>()', '!end->is_null()',
     'an end that is not true asks for nothing'),
]


def main():
    src = open(WS, encoding='utf-8', newline='').read()
    for name, old, new, check in MUTATIONS:
        assert src.count(old) == 1, (name, src.count(old))
        open(WS, 'w', encoding='utf-8', newline='').write(src.replace(old, new))
        try:
            env = dict(os.environ, RELAY_LIVE_VARIANTS='on')
            p = subprocess.run(['bash', 'run_live.sh'], cwd=HERE, env=env, capture_output=True, text=True)
            out = p.stdout + p.stderr
        finally:
            open(WS, 'w', encoding='utf-8', newline='').write(src)
        if 'BUILD FAIL' in out:
            verdict = 'BROKEN'
        elif f'FAIL {check}' in out:
            verdict = 'KILLED'
        else:
            verdict = 'SURVIVED'
        print(f'{verdict:9} {name} ({check})', flush=True)


main()
