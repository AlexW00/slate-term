#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/text-checking-gate
if [[ "${SLATE_VM_PREBUILT:-0}" != 1 ]]; then
swiftc -swift-version 5 -default-isolation MainActor -parse-as-library -g \
  Native/LiteralTextCells.swift Tests/TextChecking/TextChecking.swift \
  -o .build/text-checking-gate/text-checking
fi
[[ -x .build/text-checking-gate/text-checking ]] || { echo 'Missing prebuilt text-checking gate' >&2; exit 1; }
[[ "${SLATE_VM_BUILD_ONLY:-0}" != 1 ]] || exit 0
python3 - <<'PY'
import subprocess
import sys
try:
    sys.exit(subprocess.run(['.build/text-checking-gate/text-checking'], timeout=15).returncode)
except subprocess.TimeoutExpired:
    print('FAIL text checking gate: deadline exceeded', file=sys.stderr)
    sys.exit(1)
PY
