#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bin="$(swift build --show-bin-path)"
test -f "$bin/SlateTermSettings.o" || { echo 'Build the CLI before running browser-navigation verification' >&2; exit 1; }
gate="$(mktemp -d "${TMPDIR:-/tmp}/slate-browser-navigation.XXXXXX")"
trap 'rm -rf "$gate"' EXIT
swiftc -swift-version 5 -default-isolation MainActor -parse-as-library -g \
  -I "$bin" "$bin/SlateTermCore.o" "$bin/SlateTermSettings.o" "$bin/TOMLDecoder.o" \
  Native/LiteralTextCells.swift Native/BrowserAutomation.swift Native/WebPaneAutomation.swift Native/BrowserPane.swift \
  Tests/WebOperations/BrowserNavigation.swift -o "$gate/browser-navigation"
python3 - "$gate/browser-navigation" <<'PY'
import http.server
import subprocess
import sys
import threading

release = threading.Event()
started = {mode: threading.Event() for mode in ['cancel', 'supersede']}

class Fixture(http.server.BaseHTTPRequestHandler):
    def handle(self):
        try:
            super().handle()
        except (BrokenPipeError, ConnectionResetError):
            pass  # Pane closure can retire a speculative HTTP connection.

    def do_GET(self):
        if self.path.startswith('/held/'):
            started[self.path.removeprefix('/held/')].set()
            release.wait(15)  # A live navigation must be cancelled/replaced before any response.
        page = b'<!doctype html><title>Slate Browser Fixture</title><p>Local navigation fixture</p>'
        if self.path.startswith('/started/'):
            page = b'yes' if started[self.path.removeprefix('/started/')].is_set() else b'no'
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(page)))
        self.end_headers()
        self.wfile.write(page)

    def log_message(self, *_):
        pass

with http.server.ThreadingHTTPServer(('127.0.0.1', 0), Fixture) as server:
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        sys.exit(subprocess.run([sys.argv[1], f'http://127.0.0.1:{server.server_port}/'], timeout=60).returncode)
    except subprocess.TimeoutExpired:
        print('FAIL browser navigation: deadline exceeded', file=sys.stderr)
        sys.exit(1)
    finally:
        release.set()
        server.shutdown()
PY
