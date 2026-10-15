#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
gate="$(mktemp -d "${TMPDIR:-/tmp}/slate-dividers.XXXXXX")"
trap 'rm -rf "$gate"' EXIT
swiftc -swift-version 5 -parse-as-library -g -emit-library -emit-module \
  -module-name SlateTermCore Sources/SlateTermCore/*.swift \
  -emit-module-path "$gate/SlateTermCore.swiftmodule" -o "$gate/libSlateTermCore.dylib"
swiftc -swift-version 5 -default-isolation MainActor -parse-as-library -g \
  -I "$gate" -L "$gate" -lSlateTermCore -Xlinker -rpath -Xlinker "$gate" \
  Native/PaneDragging.swift Native/PaneContainer.swift Native/PaneMoveGeometry.swift \
  Native/WorkspaceSplitController.swift Native/NativeLayoutObservation.swift \
  Tests/Dividers/Dividers.swift -o "$gate/dividers"
python3 - "$gate/dividers" <<'PY'
import subprocess
import sys
try:
    sys.exit(subprocess.run([sys.argv[1]], timeout=30).returncode)
except subprocess.TimeoutExpired:
    print('FAIL owned divider fixture: deadline exceeded', file=sys.stderr)
    sys.exit(1)
PY
