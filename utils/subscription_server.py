#!/usr/bin/env python3
"""Minimal token-authenticated, read-only subscription endpoint."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit
import base64
import hmac
import os
import socket
import threading

TOKEN = os.environ.get("SUB_TOKEN", "")
PORT = int(os.environ.get("SUB_PORT", "8765"))
BIND = os.environ.get("SUB_BIND", "127.0.0.1")
SOURCE = Path("/etc/sing-box/export/links.txt")

class Handler(BaseHTTPRequestHandler):
    server_version = "Subscription"
    sys_version = ""
    protocol_version = "HTTP/1.0"

    def do_GET(self):
        expected = "/sub/" + TOKEN
        if not TOKEN or not hmac.compare_digest(urlsplit(self.path).path, expected):
            self.send_error(404)
            return
        try:
            raw = SOURCE.read_bytes()
        except OSError:
            self.send_error(503, "Subscription not generated yet")
            return
        payload = base64.b64encode(raw)
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Security-Policy", "default-src 'none'")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(payload)
    def do_HEAD(self):
        self.send_error(405)
    def log_message(self, fmt, *args):
        # Never log token-bearing request paths.
        return

class SafeThreadingHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 32
    max_concurrent_requests = 32

    def __init__(self, *args, **kwargs):
        self._request_slots = threading.BoundedSemaphore(self.max_concurrent_requests)
        super().__init__(*args, **kwargs)

    def process_request(self, request, client_address):
        # Bound worker creation; the listen backlog alone does not cap threads.
        if not self._request_slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except Exception:
            self._request_slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self._request_slots.release()

    def get_request(self):
        request, client_address = super().get_request()
        request.settimeout(10)
        return request, client_address


if __name__ == "__main__":
    if len(TOKEN) < 32:
        raise SystemExit("SUB_TOKEN must contain at least 32 characters")
    if not 1 <= PORT <= 65535:
        raise SystemExit("SUB_PORT must be between 1 and 65535")
    try:
        socket.inet_pton(socket.AF_INET, BIND)
    except OSError:
        try:
            socket.inet_pton(socket.AF_INET6, BIND)
        except OSError:
            raise SystemExit("SUB_BIND must be a valid IPv4 or IPv6 address")
    SafeThreadingHTTPServer((BIND, PORT), Handler).serve_forever()
