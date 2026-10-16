#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/native-gate.sh
slate_native_gate pane-movement-native
if [[ "${SLATE_VM_PREBUILT:-0}" != 1 ]]; then
slate_native_swiftc -swift-version 5 -parse-as-library -g -emit-library -emit-module \
  -module-name SlateTermCore Sources/SlateTermCore/*.swift \
  -emit-module-path "$gate/SlateTermCore.swiftmodule" -o "$gate/libSlateTermCore.dylib"
slate_native_swiftc -swift-version 5 -default-isolation MainActor -parse-as-library -g \
  -I "$gate" -L "$gate" -lSlateTermCore -Xlinker -rpath -Xlinker "$gate" \
  Native/PaneDragging.swift Native/PaneMoveGeometry.swift Tests/PaneMovement/PaneMovement.swift \
  -o "$gate/pane-movement"
fi
slate_native_ready "$gate/pane-movement"
python3 - "$gate/pane-movement" <<'PY'
import subprocess
import sys
try:
    sys.exit(subprocess.run([sys.argv[1]], timeout=30).returncode)
except subprocess.TimeoutExpired:
    print('FAIL pane movement native helpers: deadline exceeded', file=sys.stderr)
    sys.exit(1)
PY
