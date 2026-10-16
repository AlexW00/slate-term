#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/native-gate.sh
slate_native_gate welcome-native
if [[ "${SLATE_VM_PREBUILT:-0}" != 1 ]]; then
slate_native_swiftc -swift-version 5 -parse-as-library -g -emit-library -emit-module \
  -module-name SlateTermCore Sources/SlateTermCore/*.swift \
  -emit-module-path "$gate/SlateTermCore.swiftmodule" -o "$gate/libSlateTermCore.dylib"
slate_native_swiftc -swift-version 5 -default-isolation MainActor -parse-as-library -g \
  -I "$gate" -L "$gate" -lSlateTermCore -Xlinker -rpath -Xlinker "$gate" \
  Native/LiteralTextCells.swift Native/PaneDragging.swift Native/WelcomeView.swift Native/PaneContainer.swift Tests/Welcome/Welcome.swift \
  -o "$gate/welcome"
fi
slate_native_ready "$gate/welcome"
python3 - "$gate/welcome" "$PWD/artifacts/welcome-native" <<'PY'
import subprocess
import sys
sys.exit(subprocess.run(sys.argv[1:], timeout=30).returncode)
PY
