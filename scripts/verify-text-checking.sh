#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/text-checking-gate
swiftc -swift-version 5 -default-isolation MainActor -parse-as-library -g \
  Native/LiteralTextCells.swift Tests/TextChecking/TextChecking.swift \
  -o .build/text-checking-gate/text-checking
python3 - <<'PY'
import subprocess
import sys
try:
    sys.exit(subprocess.run(['.build/text-checking-gate/text-checking'], timeout=15).returncode)
except subprocess.TimeoutExpired:
    print('FAIL text checking gate: deadline exceeded', file=sys.stderr)
    sys.exit(1)
PY
