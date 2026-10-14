#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/plugin-process-gate
swiftc -swift-version 6 -parse-as-library -g \
  Native/PluginProcess.swift Tests/PluginProcess/ProcessLifecycle.swift \
  -o .build/plugin-process-gate/process-lifecycle
# Only this standalone harness and its explicitly owned children are launched.
python3 - <<'PY'
import subprocess
import sys
try:
    result = subprocess.run(['.build/plugin-process-gate/process-lifecycle'], timeout=40)
    sys.exit(result.returncode)
except subprocess.TimeoutExpired:
    print('FAIL plugin process lifecycle: deadline exceeded', file=sys.stderr)
    sys.exit(1)
PY
