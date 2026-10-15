#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
cli="$PWD/.build/out/Products/Debug/slate-term"
test -x "$cli" || { echo 'Build the CLI before running service-command verification' >&2; exit 1; }
gate="$(mktemp -d "${TMPDIR:-/tmp}/slate-service-commands.XXXXXX")"
trap 'rm -rf "$gate"' EXIT
swiftc -swift-version 5 -parse-as-library -g -emit-library -emit-module \
  -module-name SlateTermCore Sources/SlateTermCore/*.swift \
  -emit-module-path "$gate/SlateTermCore.swiftmodule" -o "$gate/libSlateTermCore.dylib"
swiftc -swift-version 5 -default-isolation MainActor -parse-as-library -g \
  -I "$gate" -L "$gate" -lSlateTermCore -Xlinker -rpath -Xlinker "$gate" \
  Native/WorkspaceOperationContext.swift Native/OperationControl.swift Native/PluginControlConnection.swift \
  Native/EventControl.swift Native/EventHub.swift \
  Native/PluginProcess.swift Native/PluginCommands.swift Tests/ServiceCommands/ServiceCommands.swift \
  -o "$gate/service-commands"
python3 - "$gate/service-commands" "$cli" <<'PY'
import subprocess
import sys
try:
    sys.exit(subprocess.run(sys.argv[1:], timeout=30).returncode)
except subprocess.TimeoutExpired:
    print('FAIL service commands: deadline exceeded', file=sys.stderr)
    sys.exit(1)
PY
