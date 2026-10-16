#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/native-gate.sh
slate_native_gate plugin-process
if [[ "${SLATE_VM_PREBUILT:-0}" != 1 ]]; then
slate_native_swiftc -swift-version 6 -parse-as-library -g \
  Native/PluginProcess.swift Tests/PluginProcess/ProcessLifecycle.swift \
  -o "$gate/process-lifecycle"
# Only this standalone harness and its explicitly owned children are launched.
fi
slate_native_ready "$gate/process-lifecycle"
python3 - "$gate/process-lifecycle" <<'PY'
import subprocess
import sys
try:
    result = subprocess.run([sys.argv[1]], timeout=40)
    sys.exit(result.returncode)
except subprocess.TimeoutExpired:
    print('FAIL plugin process lifecycle: deadline exceeded', file=sys.stderr)
    sys.exit(1)
PY
