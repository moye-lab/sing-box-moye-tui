#!/usr/bin/env python3
import base64
import importlib.util
import os
import tempfile
import threading
import urllib.error
import urllib.request
from pathlib import Path

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("sbm_subscription", root / "utils/subscription_server.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
with tempfile.TemporaryDirectory() as tmp:
    source = Path(tmp) / "links.txt"
    source.write_text("vless://example\nhysteria2://example\n")
    mod.TOKEN = "a" * 64
    mod.SOURCE = source
    server = mod.SafeThreadingHTTPServer(("127.0.0.1", 0), mod.Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    base = f"http://127.0.0.1:{server.server_port}"
    try:
        with urllib.request.urlopen(base + "/sub/" + mod.TOKEN, timeout=3) as response:
            data = response.read()
            assert response.status == 200
            assert response.headers["Cache-Control"] == "no-store"
            decoded = base64.b64decode(data).decode()
            assert decoded == source.read_text()
            assert "socks5://" not in decoded
        request = urllib.request.Request(base + "/sub/" + mod.TOKEN, method="HEAD")
        try:
            urllib.request.urlopen(request, timeout=3)
            raise AssertionError("HEAD unexpectedly accepted")
        except urllib.error.HTTPError as exc:
            assert exc.code == 405
        try:
            urllib.request.urlopen(base + "/sub/wrong", timeout=3)
            raise AssertionError("wrong token unexpectedly accepted")
        except urllib.error.HTTPError as exc:
            assert exc.code == 404
    finally:
        server.shutdown()
        server.server_close()
print("PASS: subscription endpoint auth, Base64 payload and cache policy")
