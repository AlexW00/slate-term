#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/native-gate.sh
SLATE_NATIVE_KEEP_FAILURE=1
slate_native_gate browser-data
if [[ "${SLATE_VM_PREBUILT:-0}" != 1 ]]; then
bin="$(swift build --show-bin-path)"
slate_native_swiftc -swift-version 5 -default-isolation MainActor -parse-as-library -g \
  -I "$bin" "$bin/SlateTermCore.o" "$bin/SlateTermSettings.o" "$bin/TOMLDecoder.o" \
  Native/BrowserData.swift Tests/BrowserData/BrowserDataChecks.swift -o "$gate/browser-data"
fi
slate_native_ready "$gate/browser-data"
python3 - "$gate/browser-data" "$gate/state" <<'PY'
import subprocess
import sys
sys.exit(subprocess.run(sys.argv[1:], timeout=45).returncode)
PY
