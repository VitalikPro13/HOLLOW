"""Plays systemd's file descriptor store across relay restarts, for hs_restart in
test_relay_live.cpp: on SIGTERM a relay hands its snapshot memfd to the notify socket
here, and the next gets it back as LISTEN_FDS, exactly as under the real unit. The client
asks for each restart by writing `ready` (then `ready2`, `ready3`, ...); while no relay
runs, a `denylist.next<n>` it left is renamed onto the denylist file and a
`denylist.drop<n>` removes that file, as an operator might between two starts. Prints
pass or FAIL the way run_live.sh does.

    python3 -I fdstore_restart.py <relay> <client> <live dir> [lo-hi ports]
"""
import json
import os
import random
import signal
import socket
import subprocess
import sys
import tempfile
import time

SANITIZER_MARKS = ("AddressSanitizer", "LeakSanitizer", "runtime error:")
# test_relay_live.cpp RESTART_REPORT_TARGET
REPORT_TARGET = "12D3KooWRestartReportTarget1111111111111111111111"


def fail(why, work=None):
    print(f"FAIL test_relay_restart ({why})")
    if work:
        names = ["client.log"] + sorted(n for n in os.listdir(work) if n.startswith("relay") and n.endswith(".log"))
        for name in names:
            path = os.path.join(work, name)
            if os.path.exists(path):
                with open(path, encoding="utf-8", errors="replace") as f:
                    lines = [l for l in f.read().splitlines() if not l.startswith("  ok")]
                print(f"--- {name}")
                print("\n".join(lines[-30:]))
    sys.exit(1)


def main():
    relay, client, live = sys.argv[1], sys.argv[2], sys.argv[3]
    ports = sys.argv[4] if len(sys.argv) > 4 and sys.argv[4] else "20000-32000"
    lo, hi = (int(x) for x in ports.split("-"))
    work = tempfile.mkdtemp(prefix="restart.", dir=live)
    notify_path = os.path.join(work, "notify")
    notify = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    notify.bind(notify_path)
    notify.settimeout(0.2)
    env = {k: v for k, v in os.environ.items()
           if not k.startswith("LISTEN_") and k not in ("NOTIFY_SOCKET", "HOLLOW_PUSH_TOKEN")}
    env["TURN_SECRET"] = "live-test"
    # Wakes go to a loopback port of this run's own, which the client holds: never 3001,
    # where a real push sidecar may listen.
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        push_port = s.getsockname()[1]
    env["HOLLOW_PUSH_PORT"] = str(push_port)
    env["NOTIFY_SOCKET"] = notify_path
    denylist = os.path.join(work, "denylist.json")
    with open(denylist, "w") as f:
        f.write('{"version":1,"servers":[],"identities":[],"networks":[]}\n')

    def start(log_name, stored=None):
        log_path = os.path.join(work, log_name)
        for _ in range(5):
            port = random.randint(lo, hi)
            args = [relay, "--port", str(port), "--domain", "relay.live.test",
                    "--cert-file", os.path.join(live, "cert.pem"), "--key-file", os.path.join(live, "key.pem"),
                    "--keys-file", os.path.join(work, "no-keys.json"),
                    "--reports-file", os.path.join(work, "reports.json"),
                    "--denylist-file", denylist]
            child_env = dict(env)
            pass_fds = ()
            if stored is not None:
                child_env["LISTEN_FDS"] = "1"
                child_env["LISTEN_FDNAMES"] = "snapshot"
                # The stored fd goes to 3 and LISTEN_PID names the relay itself: the shell
                # sets both, then becomes the relay.
                args = ["/bin/sh", "-c", 'exec 3<&%d; LISTEN_PID=$$; export LISTEN_PID; exec "$0" "$@"' % stored] + args
                pass_fds = (stored,)
            with open(log_path, "w") as log:
                p = subprocess.Popen(args, env=child_env, stdout=log, stderr=subprocess.STDOUT, pass_fds=pass_fds)
            for _ in range(100):
                with open(log_path, encoding="utf-8", errors="replace") as f:
                    if "Listening on port" in f.read():
                        return p, port
                if p.poll() is not None:
                    break
                time.sleep(0.1)
            p.kill()
            p.wait()
        fail(f"{log_name} never listened", work)

    relays = []
    c = None
    try:
        p1, port1 = start("relay1.log")
        relays.append(p1)
        client_env = dict(os.environ)
        client_env["RELAY_LIVE_RESTART"] = work
        client_env["RELAY_LIVE_PUSH_PORT"] = str(push_port)
        with open(os.path.join(work, "client.log"), "w") as log:
            c = subprocess.Popen([client, str(port1), "relay.live.test"], env=client_env,
                                 stdout=log, stderr=subprocess.STDOUT)
        rcs = []
        current = p1
        n = 1
        while True:
            ready = os.path.join(work, "ready" if n == 1 else f"ready{n}")
            deadline = time.time() + 60
            while not os.path.exists(ready):
                if c.poll() is not None:
                    break
                if time.time() > deadline:
                    fail("the client never reached the restart", work)
                time.sleep(0.05)
            if not os.path.exists(ready):
                break
            current.send_signal(signal.SIGTERM)
            stored = None
            deadline = time.time() + 15
            while time.time() < deadline:
                try:
                    msg, fds, _, _ = socket.recv_fds(notify, 4096, 4)
                except socket.timeout:
                    if current.poll() is not None:
                        break
                    continue
                if b"FDSTORE=1" in msg and fds:
                    if stored is not None:
                        os.close(stored)
                    stored, rest = fds[0], fds[1:]
                else:
                    rest = fds
                for f in rest:
                    os.close(f)
            rcs.append(current.wait(timeout=10))
            if stored is None:
                fail(f"relay {n} stored no snapshot", work)
            # What the operator changed while no relay ran.
            moved = os.path.join(work, f"denylist.next{n}")
            if os.path.exists(moved):
                os.rename(moved, denylist)
            if os.path.exists(os.path.join(work, f"denylist.drop{n}")) and os.path.exists(denylist):
                os.unlink(denylist)
            n += 1
            current, port = start(f"relay{n}.log", stored)
            relays.append(current)
            os.close(stored)
            with open(os.path.join(work, f"port{n}.tmp"), "w") as f:
                f.write(str(port))
            os.rename(os.path.join(work, f"port{n}.tmp"), os.path.join(work, f"port{n}"))
        client_rc = c.wait(timeout=60)
        current.send_signal(signal.SIGTERM)
        rcs.append(current.wait(timeout=10))
    except subprocess.TimeoutExpired:
        fail("hung", work)
    finally:
        for p in relays + ([c] if c else []):
            if p.poll() is None:
                p.kill()
                p.wait()

    logs = {}
    relay_logs = [f"relay{i}.log" for i in range(1, len(rcs) + 1)]
    for name in ["client.log"] + relay_logs:
        with open(os.path.join(work, name), encoding="utf-8", errors="replace") as f:
            logs[name] = f.read()
    for name in relay_logs[1:]:
        if "[snapshot] restored" not in logs[name]:
            fail(f"{name} restored nothing", work)
    if any(m in "".join(logs[n] for n in relay_logs) for m in SANITIZER_MARKS):
        fail("a sanitizer fired", work)
    if client_rc != 0 or any(rc != 0 for rc in rcs):
        fail(f"client {client_rc}, relays {rcs}", work)
    # The denylist across the restarts (hs_restart's deny phases): the second relay reads the
    # file the operator changed while none ran; the third finds it unreadable and the fourth
    # finds none, and both keep the list the previous process held, saying so loudly.
    if len(relay_logs) >= 4:
        for name in relay_logs[1:4]:
            if "[deny] loaded: 1 servers, 1 identities, 0 networks" not in logs[name]:
                fail(f"{name} did not keep the denylist", work)
        for name in relay_logs[2:4]:
            if "keeping the list the previous process held" not in logs[name]:
                fail(f"{name} kept the previous list without saying so", work)
    for name in relay_logs:
        for line in logs[name].splitlines():
            if line.startswith("[deny]") and ("12D3KooW" in line or any(
                    len(w) >= 32 and all(ch in "0123456789abcdef" for ch in w) for w in line.replace(",", " ").split())):
                fail(f"{name} names a denylist entry", work)
    # The report key rides the snapshot and never a file, so the repeat after the restart
    # was deduped against the fingerprint the first relay saved.
    if os.path.exists(os.path.join(work, "reports.json.key")):
        fail("a report key reached the disk", work)
    with open(os.path.join(work, "reports.json"), encoding="utf-8") as f:
        counts = json.load(f).get("counts", {})
    if counts.get(REPORT_TARGET, {}).get("spam") != 1:
        fail(f"the report counted {counts.get(REPORT_TARGET, {}).get('spam')} times across the restart", work)
    checks = sum(1 for l in logs["client.log"].splitlines() if l.startswith("  ok"))
    print(f"pass test_relay_restart ({checks} checks)")


if __name__ == "__main__":
    main()
