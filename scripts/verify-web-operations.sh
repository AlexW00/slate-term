#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/native-gate.sh
slate_native_gate web-operations
if [[ "${SLATE_VM_PREBUILT:-0}" != 1 ]]; then
slate_native_swiftc -swift-version 5 -parse-as-library -g -emit-library -emit-module \
  -module-name SlateTermCore Sources/SlateTermCore/*.swift \
  -emit-module-path "$gate/SlateTermCore.swiftmodule" -o "$gate/libSlateTermCore.dylib"
slate_native_swiftc -swift-version 5 -default-isolation MainActor -parse-as-library -g \
  -I "$gate" -L "$gate" -lSlateTermCore -Xlinker -rpath -Xlinker "$gate" \
  Native/BrowserAutomation.swift Native/WebPaneAutomation.swift Tests/WebOperations/WebOperations.swift \
  -o "$gate/web-operations"
fi
slate_native_ready "$gate/web-operations"
python3 - "$gate/web-operations" <<'PY'
import subprocess
import sys
try:
    sys.exit(subprocess.run([sys.argv[1]], timeout=20).returncode)
except subprocess.TimeoutExpired:
    print('FAIL web operations: deadline exceeded', file=sys.stderr)
    sys.exit(1)
PY
