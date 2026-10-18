#!/bin/bash
# Focused native gate: two owned tabs, no shells, user state or clipboard access.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/native-gate.sh
slate_native_gate tab-overview
if [[ "${SLATE_VM_PREBUILT:-0}" != 1 ]]; then
{
  git rev-parse HEAD
  sw_vers
  xcrun swiftc --version
  shasum -a 256 Native/WorkspaceWindow.swift Tests/TabOverview/TabOverview.swift scripts/verify-tab-overview.sh
} > "$gate/build-manifest.txt"
# WorkspaceWindow.swift imports SlateTermCore, so build that module first.
slate_native_swiftc -swift-version 5 -parse-as-library -g -emit-library -emit-module \
  -module-name SlateTermCore Sources/SlateTermCore/*.swift \
  -emit-module-path "$gate/SlateTermCore.swiftmodule" -o "$gate/libSlateTermCore.dylib"
slate_native_swiftc -swift-version 5 -default-isolation MainActor -parse-as-library -g \
  -I "$gate" -L "$gate" -lSlateTermCore -Xlinker -rpath -Xlinker "$gate" \
  Native/WorkspaceWindow.swift Tests/TabOverview/TabOverview.swift \
  -o "$gate/tab-overview"
shasum -a 256 "$gate/tab-overview" >> "$gate/build-manifest.txt"
fi
slate_native_ready "$gate/tab-overview"
output="$PWD/artifacts/tab-overview"
mkdir -p "$output"
cp "$gate/build-manifest.txt" "$output/build-manifest.txt"
python3 - "$gate/tab-overview" <<'PY'
import subprocess
import sys
try:
    sys.exit(subprocess.run([sys.argv[1]], timeout=25).returncode)
except subprocess.TimeoutExpired:
    print('FAIL tab overview gate: deadline exceeded', file=sys.stderr)
    sys.exit(1)
PY
