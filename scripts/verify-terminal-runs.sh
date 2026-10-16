#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/native-gate.sh
slate_native_gate terminal-runs
if [[ "${SLATE_VM_PREBUILT:-0}" != 1 ]]; then
# Each invocation owns its scratch products; never touch package/app or another gate's builds.
slate_native_swiftc -swift-version 5 -parse-as-library -g -emit-library -emit-module \
  -module-name SlateTermCore Sources/SlateTermCore/*.swift \
  -emit-module-path "$gate/SlateTermCore.swiftmodule" -o "$gate/libSlateTermCore.dylib"
# Swift uses basenames as private-declaration identities; the assigned sources share one.
cp Tests/TerminalRuns/TerminalRuns.swift "$gate/TerminalRunsChecks.swift"
# Exercise the native isolation mode without compiling or launching the app.
slate_native_swiftc -swift-version 5 -default-isolation MainActor -parse-as-library -g \
  -I "$gate" -L "$gate" -lSlateTermCore -Xlinker -rpath -Xlinker "$gate" \
  Native/TerminalRuns.swift "$gate/TerminalRunsChecks.swift" \
  -o "$gate/terminal-runs"
fi
slate_native_ready "$gate/terminal-runs"
python3 - "$gate/terminal-runs" <<'PY'
import subprocess
import sys
try:
    result = subprocess.run([sys.argv[1]], timeout=20)
    sys.exit(result.returncode)
except subprocess.TimeoutExpired:
    print('FAIL terminal runs: deadline exceeded', file=sys.stderr)
    sys.exit(1)
PY
