"""Plays systemd's file descriptor store across one relay restart, for hs_restart in
test_relay_live.cpp: on SIGTERM the first relay hands its snapshot memfd to the notify
socket here, and the second gets it back as LISTEN_FDS, exactly as under the real unit.
Prints pass or FAIL the way run_live.sh does.

    python3 -I fdstore_restart.py <relay> <client> <live dir> [lo-hi ports]
"""
import os
import random
import signal
import socket
import subprocess
import sys
import tempfile
import time

SANITIZER_MARKS = ("AddressSanitizer", "LeakSanitizer", "runtime error:")


def fail(why, work=None):
    print(f"FAIL test_relay_restart ({why})")
    if work:
        for name in ("client.log", "relay1.log", "relay2.log"):
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
    env["NOTIFY_SOCKET"] = notify_path

    def start(log_name, stored=None):
        log_path = os.path.join(work, log_name)
        for _ in range(5):
            port = random.randint(lo, hi)
            args = [relay, "--port", str(port), "--domain", "relay.live.test",
                    "--cert-file", os.path.join(live, "cert.pem"), "--key-file", os.path.join(live, "key.pem"),
                    "--keys-file", os.path.join(work, "no-keys.json"),
                    "--reports-file", os.path.join(work, log_name + ".reports.json")]
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
        with open(os.path.join(work, "client.log"), "w") as log:
            c = subprocess.Popen([client, str(port1), "relay.live.test", "off"], env=client_env,
                                 stdout=log, stderr=subprocess.STDOUT)
        deadline = time.time() + 60
        while not os.path.exists(os.path.join(work, "ready")):
            if c.poll() is not None or time.time() > deadline:
                fail("the client never reached the restart", work)
            time.sleep(0.05)

        p1.send_signal(signal.SIGTERM)
        stored = None
        deadline = time.time() + 15
        while time.time() < deadline:
            try:
                msg, fds, _, _ = socket.recv_fds(notify, 4096, 4)
            except socket.timeout:
                if p1.poll() is not None:
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
        rc1 = p1.wait(timeout=10)
        if stored is None:
            fail("the first relay stored no snapshot", work)

        p2, port2 = start("relay2.log", stored)
        relays.append(p2)
        os.close(stored)
        with open(os.path.join(work, "port2.tmp"), "w") as f:
            f.write(str(port2))
        os.rename(os.path.join(work, "port2.tmp"), os.path.join(work, "port2"))
        client_rc = c.wait(timeout=60)
        p2.send_signal(signal.SIGTERM)
        rc2 = p2.wait(timeout=10)
    except subprocess.TimeoutExpired:
        fail("hung", work)
    finally:
        for p in relays + ([c] if c else []):
            if p.poll() is None:
                p.kill()
                p.wait()

    logs = {}
    for name in ("client.log", "relay1.log", "relay2.log"):
        with open(os.path.join(work, name), encoding="utf-8", errors="replace") as f:
            logs[name] = f.read()
    if "[snapshot] restored" not in logs["relay2.log"]:
        fail("the second relay restored nothing", work)
    if any(m in logs["relay1.log"] + logs["relay2.log"] for m in SANITIZER_MARKS):
        fail("a sanitizer fired", work)
    if client_rc != 0 or rc1 != 0 or rc2 != 0:
        fail(f"client {client_rc}, relays {rc1} and {rc2}", work)
    checks = sum(1 for l in logs["client.log"].splitlines() if l.startswith("  ok"))
    print(f"pass test_relay_restart ({checks} checks)")


if __name__ == "__main__":
    main()
