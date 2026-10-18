#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/native-gate.sh
slate_native_gate pane-titles-native
if [[ "${SLATE_VM_PREBUILT:-0}" != 1 ]]; then
slate_native_swiftc -swift-version 5 -parse-as-library -g -emit-library -emit-module \
  -module-name SlateTermCore Sources/SlateTermCore/*.swift \
  -emit-module-path "$gate/SlateTermCore.swiftmodule" -o "$gate/libSlateTermCore.dylib"
slate_native_swiftc -swift-version 5 -default-isolation MainActor -parse-as-library -g \
  -I "$gate" -L "$gate" -lSlateTermCore -Xlinker -rpath -Xlinker "$gate" \
  Native/LiteralTextCells.swift Native/PaneDragging.swift Native/PaneContainer.swift Native/PresenceOverlay.swift Native/WelcomeView.swift Tests/PaneTitles/PaneTitles.swift \
  -o "$gate/pane-titles"
fi
slate_native_ready "$gate/pane-titles"
python3 - "$gate/pane-titles" "$PWD/artifacts" <<'PY'
import subprocess
import sys
try:
    sys.exit(subprocess.run(sys.argv[1:], timeout=30).returncode)
except subprocess.TimeoutExpired:
    print('FAIL pane titles native gate: deadline exceeded', file=sys.stderr)
    sys.exit(1)
PY
