#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/native-gate.sh
slate_native_gate text-checking
if [[ "${SLATE_VM_PREBUILT:-0}" != 1 ]]; then
slate_native_swiftc -swift-version 5 -default-isolation MainActor -parse-as-library -g \
  Native/LiteralTextCells.swift Tests/TextChecking/TextChecking.swift \
  -o "$gate/text-checking"
fi
slate_native_ready "$gate/text-checking"
python3 - "$gate/text-checking" <<'PY'
import subprocess
import sys
try:
    sys.exit(subprocess.run([sys.argv[1]], timeout=15).returncode)
except subprocess.TimeoutExpired:
    print('FAIL text checking gate: deadline exceeded', file=sys.stderr)
    sys.exit(1)
PY
