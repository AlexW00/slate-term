#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/native-gate.sh
slate_native_gate plugin-listener
if [[ "${SLATE_VM_PREBUILT:-0}" != 1 ]]; then
  slate_native_swiftc -swift-version 6 -parse-as-library \
    Native/PluginProcess.swift Native/PluginListener.swift Tests/PluginListener/Listener.swift \
    -o "$gate/plugin-listener"
fi
slate_native_ready "$gate/plugin-listener"
export SLATE_TEST_PYTHON="$(command -v python3)"
python3 - "$gate/plugin-listener" <<'PY'
import subprocess
import sys
try:
    sys.exit(subprocess.run([sys.argv[1]], timeout=40).returncode)
except subprocess.TimeoutExpired:
    print('FAIL plugin listener: deadline exceeded', file=sys.stderr)
    sys.exit(1)
PY
