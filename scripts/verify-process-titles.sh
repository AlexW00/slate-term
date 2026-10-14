#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
gate="$root/.build/process-titles-gate"
mkdir -p "$gate"
# Standalone core module: no app build, package resolution, or GUI required.
swiftc -swift-version 5 -parse-as-library -g -emit-library -emit-module \
  -module-name SlateTermCore Sources/SlateTermCore/*.swift \
  -emit-module-path "$gate/SlateTermCore.swiftmodule" -o "$gate/libSlateTermCore.dylib"
swiftc -swift-version 5 -default-isolation MainActor -parse-as-library -g \
  -I "$gate" -L "$gate" -lSlateTermCore -Xlinker -rpath -Xlinker "$gate" \
  Native/TerminalProcessTitles.swift Tests/TerminalProcessTitles/ProcessTitles.swift \
  -o "$gate/process-titles"
# Only this harness and its private PTY children are launched; hard deadline on hangs.
python3 - <<'PY'
import subprocess
import sys
try:
    result = subprocess.run(['.build/process-titles-gate/process-titles'], timeout=30)
    sys.exit(result.returncode)
except subprocess.TimeoutExpired:
    print('FAIL process titles: deadline exceeded', file=sys.stderr)
    sys.exit(1)
PY
