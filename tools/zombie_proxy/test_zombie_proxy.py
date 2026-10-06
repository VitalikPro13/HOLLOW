#!/usr/bin/env python3
"""Tests for zombie_proxy.py: the proxy runs as its own process, exactly as the
fleet and the end-to-end test start it, between a test client and a recording
upstream.

    python tools/zombie_proxy/test_zombie_proxy.py -v
"""

from __future__ import annotations

import json
import os
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import zombie_proxy  # noqa: E402

QUIET = 1.5


def wait_until(predicate, timeout=10.0, step=0.05):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(step)
    return predicate()


class Upstream:
    """An upstream that records what each connection sent and how it ended
    ('open', 'eof' or 'reset'), and sends on demand."""

    def __init__(self, tls_context=None):
        self.tls_context = tls_context
        self.listener = socket.socket()
        self.listener.bind(('127.0.0.1', 0))
        self.listener.listen(16)
        self.port = self.listener.getsockname()[1]
        self.conns = []
        self.lock = threading.Lock()
        self.closed = False
        threading.Thread(target=self._accept, daemon=True).start()

    def _accept(self):
        while not self.closed:
            try:
                sock, _ = self.listener.accept()
            except OSError:
                return
            if self.tls_context is not None:
                try:
                    sock = self.tls_context.wrap_socket(sock, server_side=True)
                except (OSError, ssl.SSLError):
                    continue
            record = {'sock': sock, 'data': bytearray(), 'end': 'open'}
            with self.lock:
                self.conns.append(record)
            threading.Thread(target=self._read, args=(record,), daemon=True).start()

    def _read(self, record):
        sock = record['sock']
        while True:
            try:
                chunk = sock.recv(65536)
            except ConnectionResetError:
                record['end'] = 'reset'
                return
            except (OSError, ssl.SSLError) as exc:
                record['end'] = 'reset' if 'reset' in str(exc).lower() else f'error {exc}'
                return
            if not chunk:
                record['end'] = 'eof'
                return
            with self.lock:
                record['data'] += chunk

    def conn(self, index):
        with self.lock:
            return self.conns[index]

    def count(self):
        with self.lock:
            return len(self.conns)

    def received(self, index):
        with self.lock:
            return bytes(self.conns[index]['data'])

    def close(self):
        self.closed = True
        self.listener.close()
        with self.lock:
            for record in self.conns:
                try:
                    record['sock'].close()
                except OSError:
                    pass


def recv_exactly(sock, size, timeout=10.0):
    sock.settimeout(timeout)
    out = bytearray()
    while len(out) < size:
        chunk = sock.recv(size - len(out))
        if not chunk:
            raise AssertionError(f'EOF after {len(out)} of {size} bytes')
        out += chunk
    return bytes(out)


def make_certificate(directory):
    """A throwaway self-signed certificate, or None without the openssl tool."""
    tool = shutil.which('openssl')
    if tool is None:
        return None
    key = os.path.join(directory, 'key.pem')
    cert = os.path.join(directory, 'cert.pem')
    result = subprocess.run(
        [tool, 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
         '-subj', '/CN=zombie.test', '-keyout', key, '-out', cert],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if result.returncode != 0:
        return None
    return cert, key


class ProxyTestCase(unittest.TestCase):
    routes_tls = False

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix='zombie-proxy-test-')
        self.upstream = self.make_upstream()
        self.proxy = None
        self.start_proxy()
        self.sockets = []

    def make_upstream(self):
        return Upstream()

    def start_proxy(self):
        ready = os.path.join(self.tmp, 'ready.json')
        suffix = ':tls' if self.routes_tls else ''
        self.proxy = subprocess.Popen(
            [sys.executable, os.path.join(HERE, 'zombie_proxy.py'), 'serve',
             '--control', '127.0.0.1:0', '--ready-file', ready,
             '--route', f't=127.0.0.1:0=127.0.0.1:{self.upstream.port}{suffix}',
             '--route', f'u=127.0.0.1:0=127.0.0.1:{self.upstream.port}{suffix}'],
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        self.assertTrue(wait_until(lambda: os.path.exists(ready) and os.path.getsize(ready) > 0),
                        'the proxy never wrote its ready file')
        with open(ready, encoding='utf-8') as handle:
            ports = json.load(handle)
        self.control_address = f'127.0.0.1:{ports["control"]}'
        self.route_ports = ports['routes']

    def tearDown(self):
        for sock in self.sockets:
            try:
                sock.close()
            except OSError:
                pass
        try:
            self.ctl('quit')
        except OSError:
            pass
        try:
            self.proxy.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proxy.kill()
            self.proxy.wait()
        if self.proxy.stderr is not None:
            self.proxy.stderr.close()
        self.upstream.close()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def ctl(self, line):
        answer = zombie_proxy.control(self.control_address, line)
        if line != 'quit':
            self.assertTrue(answer.get('ok'), f'{line}: {answer}')
        return answer

    def connect(self, route='t'):
        sock = socket.create_connection(('127.0.0.1', self.route_ports[route]), timeout=10)
        self.sockets.append(sock)
        return sock

    def connections(self):
        return self.ctl('list')['connections']

    def established(self, route='t'):
        """A client socket whose path is proven end to end, and its upstream index."""
        before = self.upstream.count()
        sock = self.connect(route)
        sock.sendall(b'hello')
        self.assertTrue(wait_until(lambda: self.upstream.count() > before
                                   and self.upstream.received(before) == b'hello'))
        self.upstream.conn(before)['sock'].sendall(b'world')
        self.assertEqual(recv_exactly(sock, 5), b'world')
        return sock, before

    def newest_id(self):
        return max(c['id'] for c in self.connections())


class PassThrough(ProxyTestCase):
    def test_forwards_bytes_untouched_both_ways(self):
        sock, index = self.established()
        payload = os.urandom(512 * 1024)
        sock.sendall(payload)
        self.assertTrue(wait_until(lambda: len(self.upstream.received(index)) == 5 + len(payload)))
        self.assertEqual(self.upstream.received(index), b'hello' + payload)
        back = os.urandom(512 * 1024)
        self.upstream.conn(index)['sock'].sendall(back)
        self.assertEqual(recv_exactly(sock, len(back)), back)

    def test_a_client_close_reaches_the_upstream_as_eof(self):
        sock, index = self.established()
        sock.close()
        self.assertTrue(wait_until(lambda: self.upstream.conn(index)['end'] == 'eof'))

    def test_list_names_each_connection_and_its_route(self):
        self.established('t')
        self.established('u')
        listed = self.connections()
        self.assertEqual(sorted(c['route'] for c in listed), ['t', 'u'])
        self.assertTrue(all(c['state'] == 'live' for c in listed))
        stats = self.ctl('stats')['routes']
        self.assertEqual(stats['t']['open'], 1)
        self.assertEqual(stats['u']['opened'], 1)


class Freeze(ProxyTestCase):
    def test_a_frozen_connection_moves_no_byte_either_way_and_never_closes(self):
        sock, index = self.established()
        self.ctl(f'freeze {self.newest_id()}')
        sock.sendall(b'up-while-frozen')
        self.upstream.conn(index)['sock'].sendall(b'down-while-frozen')
        time.sleep(QUIET)
        self.assertEqual(self.upstream.received(index), b'hello', 'bytes reached the upstream through a freeze')
        sock.settimeout(QUIET)
        with self.assertRaises(socket.timeout, msg='bytes reached the client through a freeze'):
            sock.recv(100)
        self.assertEqual(self.upstream.conn(index)['end'], 'open', 'the freeze closed the upstream')
        listed = self.connections()[0]
        self.assertEqual(listed['state'], 'frozen')
        # Read nothing either: the bytes wait in the kernel, so TCP pushes back.
        self.assertEqual((listed['bytes_up'], listed['bytes_down']), (5, 5),
                         'the proxy kept reading a frozen connection')

        self.ctl(f'thaw {self.newest_id()}')
        self.assertTrue(wait_until(lambda: self.upstream.received(index) == b'hello' + b'up-while-frozen'))
        self.assertEqual(recv_exactly(sock, len(b'down-while-frozen')), b'down-while-frozen')
        sock.sendall(b'after')
        self.assertTrue(wait_until(lambda: self.upstream.received(index).endswith(b'after')))

    def test_a_close_during_a_freeze_is_held_until_the_thaw(self):
        sock, index = self.established()
        conn_id = self.newest_id()
        self.ctl(f'freeze {conn_id}')
        sock.sendall(b'last words')
        sock.shutdown(socket.SHUT_WR)
        time.sleep(QUIET)
        self.assertEqual(self.upstream.conn(index)['end'], 'open')
        self.assertEqual(self.upstream.received(index), b'hello')
        self.ctl(f'thaw {conn_id}')
        self.assertTrue(wait_until(lambda: self.upstream.conn(index)['end'] == 'eof'))
        self.assertEqual(self.upstream.received(index), b'hellolast words')

    def test_freezing_one_connection_leaves_the_others_alone(self):
        frozen, frozen_index = self.established()
        frozen_id = self.newest_id()
        live, live_index = self.established()
        self.ctl(f'freeze {frozen_id}')
        live.sendall(b'still moving')
        self.assertTrue(wait_until(lambda: self.upstream.received(live_index).endswith(b'still moving')))
        frozen.sendall(b'stuck')
        time.sleep(QUIET)
        self.assertEqual(self.upstream.received(frozen_index), b'hello')

    def test_a_frozen_route_holds_new_connections_until_thawed(self):
        self.ctl('freeze route:t')
        before = self.upstream.count()
        sock = self.connect('t')
        sock.sendall(b'knock')
        time.sleep(QUIET)
        self.assertEqual(self.upstream.count(), before, 'a held connection reached the upstream')
        self.assertEqual([c['state'] for c in self.connections()], ['held'])
        other = self.connect('u')
        other.sendall(b'other route')
        self.assertTrue(wait_until(lambda: self.upstream.count() == before + 1))
        self.ctl('thaw route:t')
        self.assertTrue(wait_until(lambda: self.upstream.count() == before + 2))
        self.assertTrue(wait_until(lambda: any(
            self.upstream.received(i) == b'knock' for i in range(self.upstream.count()))))

    def test_freeze_all_covers_every_route_and_thaw_all_releases_them(self):
        a, a_index = self.established('t')
        b, b_index = self.established('u')
        self.ctl('freeze all')
        a.sendall(b'A')
        b.sendall(b'B')
        late = self.connect('u')
        late.sendall(b'late')
        time.sleep(QUIET)
        self.assertEqual(self.upstream.received(a_index), b'hello')
        self.assertEqual(self.upstream.received(b_index), b'hello')
        self.assertEqual(self.upstream.count(), 2, 'a connection opened during freeze all reached the upstream')
        self.ctl('thaw all')
        self.assertTrue(wait_until(lambda: self.upstream.received(a_index) == b'helloA'
                                   and self.upstream.received(b_index) == b'helloB'))
        self.assertTrue(wait_until(lambda: self.upstream.count() == 3 and self.upstream.received(2) == b'late'))


class Drop(ProxyTestCase):
    def test_a_drop_resets_both_ends_and_never_sends_a_fin(self):
        sock, index = self.established()
        self.ctl(f'drop {self.newest_id()}')
        sock.settimeout(5)
        with self.assertRaises(ConnectionResetError, msg='the client read a FIN, not a reset'):
            data = sock.recv(100)
            if data == b'':
                raise AssertionError('the client saw a clean EOF (FIN) instead of a reset')
        self.assertTrue(wait_until(lambda: self.upstream.conn(index)['end'] != 'open'))
        self.assertEqual(self.upstream.conn(index)['end'], 'reset')

    def test_dropping_a_frozen_route_resets_it_and_lets_new_connections_through(self):
        sock, _ = self.established()
        self.ctl('freeze route:t')
        self.ctl('drop route:t')
        sock.settimeout(5)
        with self.assertRaises(ConnectionResetError):
            if sock.recv(100) == b'':
                raise AssertionError('clean EOF instead of a reset')
        fresh, _ = self.established('t')
        self.assertEqual([c['state'] for c in self.connections()], ['live'])
        fresh.sendall(b'x')

    def test_a_held_connection_is_reset_by_a_drop(self):
        self.ctl('freeze route:t')
        before = self.upstream.count()
        sock = self.connect('t')
        self.assertTrue(wait_until(lambda: len(self.connections()) == 1))
        self.ctl('drop route:t')
        sock.settimeout(5)
        with self.assertRaises(ConnectionResetError):
            if sock.recv(100) == b'':
                raise AssertionError('clean EOF instead of a reset')
        self.assertEqual(self.upstream.count(), before)


class Control(ProxyTestCase):
    def test_bad_commands_are_refused_without_harm(self):
        for line in ('freeze', 'freeze route:nope', 'thaw 999', 'bogus', 'drop x y'):
            answer = zombie_proxy.control(self.control_address, line)
            self.assertFalse(answer['ok'], line)
        self.established()

    def test_the_ctl_command_line_prints_the_answer(self):
        self.established()
        out = subprocess.run(
            [sys.executable, os.path.join(HERE, 'zombie_proxy.py'), 'ctl',
             '--control', self.control_address, 'list'],
            capture_output=True, text=True, timeout=30)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(len(json.loads(out.stdout)['connections']), 1)


class TlsPassThrough(ProxyTestCase):
    """TLS from the client to the upstream crosses the proxy as opaque bytes."""

    def make_upstream(self):
        directory = tempfile.mkdtemp(prefix='zombie-cert-')
        self.cert_dir = directory
        pair = make_certificate(directory)
        if pair is None:
            self.skipTest('no openssl tool to make a certificate')
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(*pair)
        return Upstream(tls_context=context)

    def tearDown(self):
        super().tearDown()
        shutil.rmtree(getattr(self, 'cert_dir', ''), ignore_errors=True)

    def tls_client(self, route='t'):
        context = ssl.create_default_context()
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        raw = self.connect(route)
        sock = context.wrap_socket(raw, server_hostname='zombie.test')
        self.sockets.append(sock)
        return sock

    def test_a_tls_session_survives_a_freeze_and_thaw(self):
        sock = self.tls_client()
        sock.sendall(b'hello')
        self.assertTrue(wait_until(lambda: self.upstream.count() == 1 and self.upstream.received(0) == b'hello'))
        self.ctl(f'freeze {self.newest_id()}')
        sock.sendall(b'sealed')
        time.sleep(QUIET)
        self.assertEqual(self.upstream.received(0), b'hello')
        self.ctl(f'thaw {self.newest_id()}')
        self.assertTrue(wait_until(lambda: self.upstream.received(0) == b'hellosealed'))
        self.upstream.conn(0)['sock'].sendall(b'back')
        self.assertEqual(recv_exactly(sock, 4), b'back')


class TlsUpstream(TlsPassThrough):
    """A `:tls` route: plain clients, the proxy speaks TLS to the upstream."""

    routes_tls = True

    def test_plain_bytes_arrive_through_the_proxys_own_tls(self):
        sock, index = self.established()
        sock.sendall(b' through tls')
        self.assertTrue(wait_until(lambda: self.upstream.received(index) == b'hello through tls'))
        self.ctl(f'freeze {self.newest_id()}')
        sock.sendall(b'!')
        time.sleep(QUIET)
        self.assertEqual(self.upstream.received(index), b'hello through tls')
        self.ctl(f'thaw {self.newest_id()}')
        self.assertTrue(wait_until(lambda: self.upstream.received(index) == b'hello through tls!'))

    def test_a_tls_session_survives_a_freeze_and_thaw(self):
        self.skipTest('the client side of a :tls route is plain')


class FakeTransport:
    def __init__(self):
        self.written = bytearray()
        self.eof = False
        self.paused = False
        self.closed = False
        self.aborted = False

    def write(self, data):
        self.written += data

    def can_write_eof(self):
        return True

    def write_eof(self):
        self.eof = True

    def pause_reading(self):
        self.paused = True

    def resume_reading(self):
        self.paused = False

    def close(self):
        self.closed = True

    def abort(self):
        self.aborted = True

    def get_extra_info(self, name):
        return None


class Layers(unittest.TestCase):
    """Each of the freeze's two layers alone: reading paused, and nothing written
    while frozen even when bytes do arrive."""

    def setUp(self):
        self.proxy = zombie_proxy.Proxy([zombie_proxy.parse_route('t=127.0.0.1:0=127.0.0.1:1')])
        route = self.proxy.routes['t']
        route.frozen = True
        self.conn = zombie_proxy.Conn(self.proxy, route, 1)
        self.proxy.conns[1] = self.conn
        self.client = FakeTransport()
        self.upstream = FakeTransport()
        zombie_proxy.Side(self.conn, True).connection_made(self.client)
        zombie_proxy.Side(self.conn, False).connection_made(self.upstream)

    def test_a_frozen_connection_reads_nothing_on_either_side(self):
        self.assertTrue(self.client.paused and self.upstream.paused)
        self.conn.thaw()
        self.assertFalse(self.client.paused or self.upstream.paused)
        self.conn.freeze()
        self.assertTrue(self.client.paused and self.upstream.paused)

    def test_bytes_that_still_arrive_while_frozen_are_held_not_written(self):
        self.conn.data_from(True, b'up')
        self.conn.data_from(False, b'down')
        self.conn.eof_from(True)
        self.assertEqual((bytes(self.upstream.written), bytes(self.client.written)), (b'', b''))
        self.assertFalse(self.upstream.eof)
        self.conn.thaw()
        self.assertEqual(bytes(self.upstream.written), b'up')
        self.assertEqual(bytes(self.client.written), b'down')
        self.assertTrue(self.upstream.eof)

    def test_an_end_that_goes_away_while_frozen_is_mirrored_only_at_the_thaw(self):
        self.conn.lost(False, None)
        self.assertFalse(self.client.closed or self.client.aborted)
        self.conn.thaw()
        self.assertTrue(self.client.closed, 'the upstream that went away during the freeze was not mirrored')

    def test_a_drop_aborts_both_sides(self):
        self.conn.drop()
        self.assertTrue(self.client.aborted and self.upstream.aborted)
        self.assertNotIn(1, self.proxy.conns)


class Parsing(unittest.TestCase):
    def test_routes_parse(self):
        route = zombie_proxy.parse_route('b=127.0.0.1:18522=relay.example.com:443:tls')
        self.assertEqual(route, {'name': 'b', 'listen': ('127.0.0.1', 18522),
                                 'upstream': ('relay.example.com', 443), 'tls': True})
        self.assertFalse(zombie_proxy.parse_route('a=0.0.0.0:1=h:2')['tls'])
        for bad in ('b', 'b=1', '=1:2=3:4', 'b=h:1=h'):
            with self.assertRaises(ValueError):
                zombie_proxy.parse_route(bad)


if __name__ == '__main__':
    unittest.main()
