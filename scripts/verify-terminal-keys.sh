#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/native-gate.sh
slate_native_gate terminal-keys
if [[ "${SLATE_VM_PREBUILT:-0}" != 1 ]]; then
# Each run owns its compiler products; no package, app, or shared gate builds.
slate_native_swiftc -swift-version 6 -default-isolation MainActor -parse-as-library -g \
  -module-cache-path "$gate/module-cache" \
  Native/Terminal/TerminalKey.swift Tests/TerminalKeys/TerminalKeys.swift \
  -framework Carbon -o "$gate/terminal-keys"
fi
slate_native_ready "$gate/terminal-keys"
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
