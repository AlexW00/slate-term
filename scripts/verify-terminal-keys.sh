#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Each run owns its compiler products; no package, app, or shared gate builds.
gate="$(mktemp -d "${TMPDIR:-/tmp}/slate-terminal-keys.XXXXXX")"
trap 'rm -rf "$gate"' EXIT
swiftc -swift-version 6 -default-isolation MainActor -parse-as-library -g \
  -module-cache-path "$gate/module-cache" \
  Native/Terminal/TerminalKey.swift Tests/TerminalKeys/TerminalKeys.swift \
  -framework Carbon -o "$gate/terminal-keys"
python3 - "$gate/terminal-keys" <<'PY'
import subprocess
import sys
try:
    result = subprocess.run([sys.argv[1]], timeout=20)
    sys.exit(result.returncode)
except subprocess.TimeoutExpired:
    print('FAIL terminal keys: deadline exceeded', file=sys.stderr)
    sys.exit(1)
PY
