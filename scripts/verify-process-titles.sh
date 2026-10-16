#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/native-gate.sh
slate_native_gate process-titles
if [[ "${SLATE_VM_PREBUILT:-0}" != 1 ]]; then
# Standalone core module: no app build, package resolution, or GUI required.
slate_native_swiftc -swift-version 5 -parse-as-library -g -emit-library -emit-module \
  -module-name SlateTermCore Sources/SlateTermCore/*.swift \
  -emit-module-path "$gate/SlateTermCore.swiftmodule" -o "$gate/libSlateTermCore.dylib"
slate_native_swiftc -swift-version 5 -default-isolation MainActor -parse-as-library -g \
  -I "$gate" -L "$gate" -lSlateTermCore -Xlinker -rpath -Xlinker "$gate" \
  Native/TerminalProcessTitles.swift Tests/TerminalProcessTitles/ProcessTitles.swift \
  -o "$gate/process-titles"
# Only this harness and its private PTY children are launched; hard deadline on hangs.
fi
slate_native_ready "$gate/process-titles"
python3 - "$gate/process-titles" <<'PY'
import subprocess
import sys
try:
    result = subprocess.run([sys.argv[1]], timeout=30)
    sys.exit(result.returncode)
except subprocess.TimeoutExpired:
    print('FAIL process titles: deadline exceeded', file=sys.stderr)
    sys.exit(1)
PY
