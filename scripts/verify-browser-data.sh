#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bin="$(swift build --show-bin-path)"
gate="$(mktemp -d "${TMPDIR:-/tmp}/slate-browser-data.XXXXXX")"
trap 'status=$?; if [[ "$status" == 0 ]]; then rm -rf "$gate"; else echo "Preserved fixture ownership metadata: $gate" >&2; fi' EXIT
swiftc -swift-version 5 -default-isolation MainActor -parse-as-library -g \
  -I "$bin" "$bin/SlateTermCore.o" "$bin/SlateTermSettings.o" "$bin/TOMLDecoder.o" \
  Native/BrowserData.swift Tests/BrowserData/BrowserDataChecks.swift -o "$gate/browser-data"
python3 - "$gate/browser-data" "$gate/state" <<'PY'
import subprocess
import sys
sys.exit(subprocess.run(sys.argv[1:], timeout=45).returncode)
PY
