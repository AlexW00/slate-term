#!/bin/bash
# Focused native gate: two owned tabs, no shells, user state or clipboard access.
set -euo pipefail
cd "$(dirname "$0")/.."
output="$PWD/artifacts/tab-overview"
mkdir -p "$output"
gate="$(mktemp -d "${TMPDIR:-/tmp}/slate-tab-overview-gate.XXXXXX")"
trap 'rm -rf "$gate"' EXIT
{
  git rev-parse HEAD
  sw_vers
  xcrun swiftc --version
  shasum -a 256 Native/WorkspaceWindow.swift Tests/TabOverview/TabOverview.swift scripts/verify-tab-overview.sh
} > "$output/build-manifest.txt"
swiftc -swift-version 5 -default-isolation MainActor -parse-as-library -g \
  Native/WorkspaceWindow.swift Tests/TabOverview/TabOverview.swift \
  -o "$gate/tab-overview"
shasum -a 256 "$gate/tab-overview" >> "$output/build-manifest.txt"
python3 - "$gate/tab-overview" <<'PY'
import subprocess
import sys
try:
    sys.exit(subprocess.run([sys.argv[1]], timeout=25).returncode)
except subprocess.TimeoutExpired:
    print('FAIL tab overview gate: deadline exceeded', file=sys.stderr)
    sys.exit(1)
PY
