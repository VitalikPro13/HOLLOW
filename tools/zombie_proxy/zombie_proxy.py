#!/usr/bin/env python3
"""A TCP proxy that can turn a live connection into a silent dead path.

It forwards bytes untouched (TLS passes through) and, on command, freezes
connections both ways without closing them: it stops reading and writing, sends
no FIN and no RST, so both peers see a path that simply went quiet, the way a
phone that lost its network or a laptop that slept looks to the other end. It
can then thaw them (everything held moves on, in order) or drop them with a
reset. The resumable-sessions tests (RESUMABLE_SESSIONS_PLAN.md section 6) use
it to put a dead path between a real client and a real relay without touching
the host's network.

Standard library only, Python 3.8 or newer: it runs as-is on Windows, the Mac
mini and the Linux VM.

    python zombie_proxy.py serve --control 127.0.0.1:18549 \\
        --route b=127.0.0.1:18522=127.0.0.1:18501:tls --ready-file ready.json
    python zombie_proxy.py ctl --control 127.0.0.1:18549 freeze route:b

A route is NAME=LISTEN_HOST:PORT=UPSTREAM_HOST:PORT, with a trailing `:tls` when
the proxy should speak TLS to the upstream itself (no certificate check) while
its clients speak plain TCP. That mode exists for the end-to-end test only,
whose client cannot trust a throwaway certificate; every other route passes the
bytes through exactly as they came. Port 0 picks a free port; the ready file
then names the ports actually bound.

Control commands, one line in and one JSON line out:

    list                        every connection: id, route, state, bytes moved
    freeze all|route:NAME|ID    stop moving bytes; a frozen route also holds every
                                connection opened while it is frozen (accepted,
                                read nothing, no upstream yet)
    thaw all|route:NAME|ID      move bytes again; held connections reach upstream
    drop all|route:NAME|ID      reset both ends (RST, never FIN); a dropped route
                                takes new connections normally again
    stats                       totals per route
    quit                        stop the proxy

What a freeze cannot hide: bytes the operating system already accepted before the
command (a socket's own buffers) still arrive, and while frozen each side's
kernel keeps acknowledging what fits in the proxy's receive buffer before the
window closes. The application on either end sees no data, no FIN and no RST.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import socket
import ssl
import struct
import sys
import time

READ_PAUSED_LIMIT = 4 * 1024 * 1024


def _parse_hostport(text):
    host, sep, port = text.rpartition(':')
    if not sep or not host:
        raise ValueError(f'expected HOST:PORT, got {text!r}')
    return host.strip('[]'), int(port)


def parse_route(text):
    """NAME=LISTEN_HOST:PORT=UPSTREAM_HOST:PORT[:tls] as a dict."""
    name, sep, rest = text.partition('=')
    listen, sep2, upstream = rest.partition('=')
    if not sep or not sep2 or not name:
        raise ValueError(f'a route is NAME=LISTEN=UPSTREAM, got {text!r}')
    tls = False
    if upstream.endswith(':tls'):
        tls = True
        upstream = upstream[:-len(':tls')]
    lhost, lport = _parse_hostport(listen)
    uhost, uport = _parse_hostport(upstream)
    return {'name': name, 'listen': (lhost, lport), 'upstream': (uhost, uport), 'tls': tls}


def _reset_on_close(transport):
    """Makes the next close of `transport` a reset rather than a FIN."""
    if transport is None:
        return
    sock = transport.get_extra_info('socket')
    if sock is None:
        return
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack('ii', 1, 0))
    except OSError:
        pass


class Route:
    def __init__(self, spec):
        self.name = spec['name']
        self.listen = spec['listen']
        self.upstream = spec['upstream']
        self.tls = spec['tls']
        self.frozen = False
        self.server = None
        self.bound_port = None
        self.opened = 0
        self.bytes_up = 0
        self.bytes_down = 0


class Side(asyncio.Protocol):
    """One socket of a proxied connection; `client` says which one."""

    def __init__(self, conn, client):
        self.conn = conn
        self.client = client
        self.transport = None

    def connection_made(self, transport):
        self.transport = transport
        if self.client:
            self.conn.client_made(self)
        else:
            self.conn.upstream_made(self)

    def data_received(self, data):
        self.conn.data_from(self.client, data)

    def eof_received(self):
        self.conn.eof_from(self.client)
        return True

    def connection_lost(self, exc):
        self.conn.lost(self.client, exc)


class Conn:
    """A client connection and its upstream twin."""

    def __init__(self, proxy, route, conn_id):
        self.proxy = proxy
        self.route = route
        self.id = conn_id
        self.client = None
        self.upstream = None
        self.frozen = route.frozen
        self.connecting = False
        self.closed = False
        self.opened_at = time.time()
        self.bytes_up = 0
        self.bytes_down = 0
        # Bytes and ends held while frozen or before the upstream exists.
        self.to_upstream = bytearray()
        self.to_client = bytearray()
        self.eof_to_upstream = False
        self.eof_to_client = False
        self.client_gone = False
        self.upstream_gone = False

    @property
    def state(self):
        if self.closed:
            return 'closed'
        if self.upstream is None:
            return 'held' if self.frozen else 'connecting'
        return 'frozen' if self.frozen else 'live'

    def describe(self):
        return {
            'id': self.id,
            'route': self.route.name,
            'state': self.state,
            'bytes_up': self.bytes_up,
            'bytes_down': self.bytes_down,
            'age_s': round(time.time() - self.opened_at, 3),
        }

    def client_made(self, side):
        self.client = side
        self.proxy.log(f'open {self.id} route={self.route.name} frozen={self.frozen}')
        if self.frozen:
            side.transport.pause_reading()
        else:
            self._connect_upstream()

    def _connect_upstream(self):
        if self.connecting or self.upstream is not None or self.closed:
            return
        self.connecting = True
        asyncio.ensure_future(self._dial())

    async def _dial(self):
        loop = asyncio.get_running_loop()
        host, port = self.route.upstream
        kwargs = {}
        if self.route.tls:
            context = ssl.create_default_context()
            context.check_hostname = False
            context.verify_mode = ssl.CERT_NONE
            kwargs = {'ssl': context, 'server_hostname': host}
        try:
            await loop.create_connection(lambda: Side(self, False), host, port, **kwargs)
        except OSError as exc:
            self.proxy.log(f'upstream {self.id} failed: {exc}')
            self.connecting = False
            self._close_both(reset=True)

    def upstream_made(self, side):
        self.upstream = side
        self.connecting = False
        if self.closed:
            _reset_on_close(side.transport)
            side.transport.abort()
            return
        if self.frozen:
            side.transport.pause_reading()
        else:
            self._flush()

    def data_from(self, client, data):
        if client:
            self.bytes_up += len(data)
            self.route.bytes_up += len(data)
            self.to_upstream += data
        else:
            self.bytes_down += len(data)
            self.route.bytes_down += len(data)
            self.to_client += data
        if not self.frozen:
            self._flush()
        elif len(self.to_upstream) + len(self.to_client) > READ_PAUSED_LIMIT:
            self._pause()

    def eof_from(self, client):
        if client:
            self.eof_to_upstream = True
        else:
            self.eof_to_client = True
        if not self.frozen:
            self._flush()

    def lost(self, client, exc):
        if client:
            self.client_gone = True
        else:
            self.upstream_gone = True
        if self.closed:
            return
        if not self.frozen:
            self._flush()

    def _flush(self):
        """Moves everything held, then mirrors a closed or half-closed end."""
        if self.closed:
            return
        up = self.upstream.transport if self.upstream else None
        down = self.client.transport if self.client else None
        if up is not None and self.to_upstream and not self.upstream_gone:
            up.write(bytes(self.to_upstream))
            self.to_upstream.clear()
        if down is not None and self.to_client and not self.client_gone:
            down.write(bytes(self.to_client))
            self.to_client.clear()
        if self.eof_to_upstream and up is not None and not self.upstream_gone and up.can_write_eof():
            up.write_eof()
            self.eof_to_upstream = False
        if self.eof_to_client and down is not None and not self.client_gone and down.can_write_eof():
            down.write_eof()
            self.eof_to_client = False
        if self.client_gone or self.upstream_gone:
            self._close_both(reset=False)

    def _pause(self):
        for side in (self.client, self.upstream):
            if side is not None and side.transport is not None:
                try:
                    side.transport.pause_reading()
                except (RuntimeError, AttributeError):
                    pass

    def _resume(self):
        for side in (self.client, self.upstream):
            if side is not None and side.transport is not None:
                try:
                    side.transport.resume_reading()
                except (RuntimeError, AttributeError):
                    pass

    def freeze(self):
        if self.closed or self.frozen:
            return
        self.frozen = True
        self._pause()
        self.proxy.log(f'freeze {self.id}')

    def thaw(self):
        if self.closed or not self.frozen:
            return
        self.frozen = False
        self.proxy.log(f'thaw {self.id}')
        if self.upstream is None:
            # Held since it was accepted: it reaches the upstream only now.
            if self.client is not None:
                self.client.transport.resume_reading()
            self._connect_upstream()
            return
        self._flush()
        self._resume()

    def drop(self):
        if self.closed:
            return
        self.proxy.log(f'drop {self.id}')
        self._close_both(reset=True)

    def _close_both(self, reset):
        if self.closed:
            return
        self.closed = True
        for side in (self.client, self.upstream):
            if side is None or side.transport is None:
                continue
            if reset:
                _reset_on_close(side.transport)
                side.transport.abort()
            else:
                side.transport.close()
        self.proxy.forget(self)


class Proxy:
    def __init__(self, routes, verbose=False, log_file=None):
        self.routes = {r['name']: Route(r) for r in routes}
        self.conns = {}
        self.next_id = 1
        self.verbose = verbose
        self.log_file = log_file
        self.stopped = None

    def log(self, line):
        stamp = time.strftime('%H:%M:%S') + f'.{int(time.time() * 1000) % 1000:03d}'
        text = f'{stamp} {line}'
        if self.verbose:
            print(text, file=sys.stderr, flush=True)
        if self.log_file:
            with open(self.log_file, 'a', encoding='utf-8') as handle:
                handle.write(text + '\n')

    def forget(self, conn):
        self.conns.pop(conn.id, None)

    def accept(self, route):
        conn = Conn(self, route, self.next_id)
        self.next_id += 1
        route.opened += 1
        self.conns[conn.id] = conn
        return Side(conn, True)

    async def start(self, control):
        loop = asyncio.get_running_loop()
        for route in self.routes.values():
            host, port = route.listen
            route.server = await loop.create_server(
                lambda route=route: self.accept(route), host, port)
            route.bound_port = route.server.sockets[0].getsockname()[1]
        chost, cport = control
        self.control_server = await asyncio.start_server(self._control_client, chost, cport)
        self.control_port = self.control_server.sockets[0].getsockname()[1]
        self.stopped = loop.create_future()

    def ports(self):
        return {
            'control': self.control_port,
            'routes': {name: r.bound_port for name, r in self.routes.items()},
        }

    def _select(self, target):
        """The connections a target names, and the routes whose policy it sets."""
        if target == 'all':
            routes = list(self.routes.values())
            return [c for c in self.conns.values()], routes
        if target.startswith('route:'):
            name = target[len('route:'):]
            if name not in self.routes:
                raise ValueError(f'no route {name!r}')
            route = self.routes[name]
            return [c for c in self.conns.values() if c.route is route], [route]
        try:
            conn_id = int(target)
        except ValueError:
            raise ValueError(f'a target is all, route:NAME or a connection id, got {target!r}')
        conn = self.conns.get(conn_id)
        if conn is None:
            raise ValueError(f'no connection {conn_id}')
        return [conn], []

    def command(self, line):
        words = line.split()
        if not words:
            raise ValueError('empty command')
        verb, args = words[0].lower(), words[1:]
        if verb == 'list':
            return {'connections': [c.describe() for c in sorted(self.conns.values(), key=lambda c: c.id)]}
        if verb == 'stats':
            return {'routes': {
                name: {
                    'port': r.bound_port, 'frozen': r.frozen, 'opened': r.opened,
                    'open': sum(1 for c in self.conns.values() if c.route is r),
                    'bytes_up': r.bytes_up, 'bytes_down': r.bytes_down,
                } for name, r in self.routes.items()}}
        if verb == 'quit':
            if not self.stopped.done():
                self.stopped.set_result(True)
            return {'quit': True}
        if verb in ('freeze', 'thaw', 'drop'):
            if len(args) != 1:
                raise ValueError(f'{verb} takes one target')
            conns, routes = self._select(args[0])
            for route in routes:
                route.frozen = verb == 'freeze'
            for conn in conns:
                getattr(conn, verb)()
            self.log(f'{verb} {args[0]}: {len(conns)} connection(s)')
            return {verb: args[0], 'connections': [c.id for c in conns]}
        raise ValueError(f'unknown command {verb!r}')

    async def _control_client(self, reader, writer):
        try:
            while True:
                line = await reader.readline()
                if not line:
                    break
                try:
                    answer = {'ok': True, **self.command(line.decode('utf-8', 'replace').strip())}
                except ValueError as exc:
                    answer = {'ok': False, 'error': str(exc)}
                writer.write((json.dumps(answer) + '\n').encode())
                await writer.drain()
        except (ConnectionError, OSError):
            pass
        finally:
            writer.close()

    async def stop(self):
        for conn in list(self.conns.values()):
            conn.drop()
        for route in self.routes.values():
            route.server.close()
        self.control_server.close()


async def _serve(args):
    proxy = Proxy([parse_route(r) for r in args.route], verbose=args.verbose, log_file=args.log)
    await proxy.start(_parse_hostport(args.control))
    ports = proxy.ports()
    if args.ready_file:
        with open(args.ready_file, 'w', encoding='utf-8') as handle:
            json.dump(ports, handle)
    proxy.log(f'listening {json.dumps(ports)}')
    await proxy.stopped
    await proxy.stop()


def control(address, line, timeout=10.0):
    """Sends one control command; returns the parsed answer."""
    host, port = _parse_hostport(address)
    with socket.create_connection((host, port), timeout=timeout) as sock:
        sock.sendall((line.strip() + '\n').encode())
        buffer = b''
        while not buffer.endswith(b'\n'):
            chunk = sock.recv(65536)
            if not chunk:
                break
            buffer += chunk
    return json.loads(buffer.decode('utf-8'))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    sub = parser.add_subparsers(dest='cmd', required=True)
    serve = sub.add_parser('serve', help='run the proxy')
    serve.add_argument('--route', action='append', required=True,
                       help='NAME=LISTEN_HOST:PORT=UPSTREAM_HOST:PORT[:tls], repeatable')
    serve.add_argument('--control', required=True, help='HOST:PORT for control commands')
    serve.add_argument('--ready-file', help='write the bound ports here once listening')
    serve.add_argument('--log', help='append connection events to this file')
    serve.add_argument('--verbose', action='store_true', help='connection events to stderr')
    ctl = sub.add_parser('ctl', help='send one control command')
    ctl.add_argument('--control', required=True)
    ctl.add_argument('words', nargs='+')
    args = parser.parse_args(argv)

    if args.cmd == 'ctl':
        answer = control(args.control, ' '.join(args.words))
        print(json.dumps(answer))
        return 0 if answer.get('ok') else 1

    if sys.platform == 'win32':
        # The selector loop closes a socket without a shutdown first; the proactor
        # loop's shutdown would send a FIN ahead of the reset a drop promises.
        asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())
    asyncio.run(_serve(args))
    return 0


if __name__ == '__main__':
    sys.exit(main())
