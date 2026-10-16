#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/native-gate.sh
slate_native_gate event-hub
if [[ "${SLATE_VM_PREBUILT:-0}" != 1 ]]; then
# Each invocation owns its scratch products; never touch package/app or another gate's builds.
slate_native_swiftc -swift-version 5 -parse-as-library -g -emit-library -emit-module \
  -module-name SlateTermCore Sources/SlateTermCore/*.swift \
  -emit-module-path "$gate/SlateTermCore.swiftmodule" -o "$gate/libSlateTermCore.dylib"
# Match the native application's language/isolation mode without compiling or launching the app.
slate_native_swiftc -swift-version 5 -default-isolation MainActor -parse-as-library -g \
  -I "$gate" -L "$gate" -lSlateTermCore -Xlinker -rpath -Xlinker "$gate" \
  Native/EventHub.swift Tests/EventHub/EventHubLifecycle.swift \
  -o "$gate/event-hub-lifecycle"
fi
slate_native_ready "$gate/event-hub-lifecycle"
python3 - "$gate/event-hub-lifecycle" <<'PY'
import subprocess
import sys
try:
    result = subprocess.run([sys.argv[1]], timeout=20)
    sys.exit(result.returncode)
except subprocess.TimeoutExpired:
    print('FAIL event hub lifecycle: deadline exceeded', file=sys.stderr)
    sys.exit(1)
PY
