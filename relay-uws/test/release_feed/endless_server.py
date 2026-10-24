#!/usr/bin/env python3
"""A host that answers every GET with an endless chunked body and no Content-Length."""
import http.server
import sys


class Endless(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        chunk = b"A" * 65536
        frame = b"%x\r\n" % len(chunk) + chunk + b"\r\n"
        try:
            while True:
                self.wfile.write(frame)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *args):
        pass


http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Endless).serve_forever()
