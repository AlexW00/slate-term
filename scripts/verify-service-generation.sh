#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/native-gate.sh
slate_native_gate service-generation
if [[ "${SLATE_VM_PREBUILT:-0}" != 1 ]]; then
cli="$(slate_native_cli)"
test -x "$cli" || { echo 'Build the CLI before running service-generation verification' >&2; exit 1; }
slate_native_swiftc -swift-version 5 -parse-as-library -g -emit-library -emit-module \
  -module-name SlateTermCore Sources/SlateTermCore/*.swift \
  -emit-module-path "$gate/SlateTermCore.swiftmodule" -o "$gate/libSlateTermCore.dylib"
slate_native_swiftc -swift-version 5 -parse-as-library -g -emit-library -emit-module \
  -I "$gate" -L "$gate" -lSlateTermCore -Xlinker -rpath -Xlinker "$gate" \
  -module-name SlateTermIPC Sources/SlateTermIPC/*.swift \
  -emit-module-path "$gate/SlateTermIPC.swiftmodule" -o "$gate/libSlateTermIPC.dylib"
slate_native_swiftc -swift-version 5 -default-isolation MainActor -parse-as-library -g \
  -I "$gate" -L "$gate" -lSlateTermCore -lSlateTermIPC -Xlinker -rpath -Xlinker "$gate" \
  Native/WorkspaceOperationContext.swift Native/OperationControl.swift Native/AutomationCaller.swift Native/PluginControlConnection.swift \
  Native/PluginProcess.swift Native/PluginCommands.swift Native/BackgroundServiceGeneration.swift Native/BackgroundServices.swift Tests/ServiceGeneration/*.swift \
  -o "$gate/service-generation"
fi
slate_native_ready "$gate/service-generation"
export SLATE_TEST_PYTHON="$(command -v python3)"
cli="$(slate_native_cli)"
test -x "$cli" || { echo "Missing packaged CLI: $cli" >&2; exit 1; }
python3 - "$gate/service-generation" "$cli" <<'PY'
import subprocess
import sys
try:
    sys.exit(subprocess.run(sys.argv[1:], timeout=30).returncode)
except subprocess.TimeoutExpired:
    print('FAIL service generation: deadline exceeded', file=sys.stderr)
    sys.exit(1)
PY
