#!/bin/bash
# Investigation only. Opens two owned native tabs briefly; no app/API changes.
set -euo pipefail
cd "$(dirname "$0")/.."
output="${1:-$PWD/artifacts/background-snapshot-probe}"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
gate="$(mktemp -d "${TMPDIR:-/tmp}/slate-background-snapshot.XXXXXX")"
trap 'rm -rf "$gate"' EXIT
{
  git rev-parse HEAD
  sw_vers
  xcrun swiftc --version
  shasum -a 256 Native/WebPaneAutomation.swift Native/BrowserAutomation.swift Tests/BackgroundSnapshotProbe/BackgroundSnapshotProbe.swift
} > "$output/build-manifest.txt"
swiftc -swift-version 5 -parse-as-library -g -emit-library -emit-module \
  -module-name SlateTermCore Sources/SlateTermCore/*.swift \
  -emit-module-path "$gate/SlateTermCore.swiftmodule" -o "$gate/libSlateTermCore.dylib"
swiftc -swift-version 5 -default-isolation MainActor -parse-as-library -g \
  -I "$gate" -L "$gate" -lSlateTermCore -Xlinker -rpath -Xlinker "$gate" \
  Native/BrowserAutomation.swift Native/WebPaneAutomation.swift Tests/BackgroundSnapshotProbe/BackgroundSnapshotProbe.swift \
  -o "$gate/background-snapshot-probe"
python3 - "$gate/background-snapshot-probe" "$output" <<'PY'
import subprocess
import sys
try:
    result = subprocess.run(sys.argv[1:], timeout=90)
    sys.exit(result.returncode)
except subprocess.TimeoutExpired:
    print('FAIL background snapshot probe: 90-second runtime limit', file=sys.stderr)
    sys.exit(1)
PY
