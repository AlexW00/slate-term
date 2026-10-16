#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
framework="$root/.build/bootstrap/ghostty/macos/GhosttyKit.xcframework/macos-arm64"
if [[ "${SLATE_VM_PREBUILT:-0}" != 1 ]]; then
if [[ ! -f "$framework/libghostty-internal.a" ]]; then
  echo 'Missing pinned GhosttyKit. Run: bash scripts/build-ghostty.sh' >&2
  exit 1
fi
mkdir -p .build/terminal-gate artifacts
swiftc -swift-version 6 -parse-as-library -g \
  -I "$framework/Headers" \
  Native/Terminal/*.swift Tests/TerminalLifecycle/TerminalLifecycle.swift \
  "$framework/libghostty-internal.a" \
  -framework AppKit -framework Metal -framework MetalKit -framework QuartzCore \
  -framework CoreText -framework CoreGraphics -framework Carbon -framework IOKit \
  -lc++ -lz -o .build/terminal-gate/terminal-lifecycle
fi
[[ -x .build/terminal-gate/terminal-lifecycle ]] || { echo 'Missing prebuilt terminal gate' >&2; exit 1; }
[[ "${SLATE_VM_BUILD_ONLY:-0}" != 1 ]] || exit 0
# libghostty resolves terminfo and injected shell scripts relative to this directory.
export GHOSTTY_RESOURCES_DIR="$root/.build/bootstrap/ghostty/zig-out/share/ghostty"
[[ -d "$GHOSTTY_RESOURCES_DIR" ]] || { echo 'Ghostty runtime resources missing' >&2; exit 1; }
export SLATE_TERM_TEST_SCREENSHOT="$root/artifacts/terminal-lifecycle.png"
# Hard watchdog, owned subprocess only; a hung AppKit loop is a test failure.
python3 - <<'PY' 2>&1 | tee artifacts/terminal-lifecycle.log
import subprocess
import sys
try:
    result = subprocess.run(['.build/terminal-gate/terminal-lifecycle'], timeout=90)
    sys.exit(result.returncode)
except subprocess.TimeoutExpired:
    print('FAIL terminal lifecycle: process deadline exceeded', file=sys.stderr)
    sys.exit(1)
PY
