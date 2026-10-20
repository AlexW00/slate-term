#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/native-gate.sh
slate_native_gate terminal
if [[ "${SLATE_VM_PREBUILT:-0}" != 1 ]]; then
root="$PWD"
swift build --product slate-term --jobs 4
bin="$(swift build --show-bin-path)"
framework="$root/.build/bootstrap/ghostty/macos/GhosttyKit.xcframework/macos-arm64"
[[ -f "$framework/libghostty-internal.a" ]] || { echo "Missing pinned GhosttyKit; run scripts/build-ghostty.sh" >&2; exit 1; }
slate_native_swiftc -swift-version 6 -parse-as-library -g \
  -I "$framework/Headers" -I "$bin" -L "$bin" -lSlateTermSettings \
  Native/Terminal/*.swift Native/TerminalProcessShutdown.swift Tests/TerminalLifecycle/TerminalLifecycle.swift \
  "$framework/libghostty-internal.a" \
  -framework AppKit -framework Metal -framework MetalKit -framework QuartzCore \
  -framework CoreText -framework CoreGraphics -framework Carbon -framework IOKit \
  -lc++ -lz -o "$gate/terminal-lifecycle"
fi
slate_native_ready "$gate/terminal-lifecycle"
root="$PWD"
export GHOSTTY_RESOURCES_DIR="$root/.build/bootstrap/ghostty/zig-out/share/ghostty"
[[ -d "$GHOSTTY_RESOURCES_DIR" ]] || { echo "Ghostty runtime resources missing" >&2; exit 1; }
export SLATE_TERM_TEST_SCREENSHOT="$root/artifacts/terminal-lifecycle.png"
# Hard watchdog; a hung AppKit loop is a test failure.
python3 - "$gate/terminal-lifecycle" <<'PY' 2>&1 | tee artifacts/terminal-lifecycle.log
import subprocess
import sys
try:
    result = subprocess.run([sys.argv[1]], timeout=90)
    sys.exit(result.returncode)
except subprocess.TimeoutExpired:
    print('FAIL terminal lifecycle: process deadline exceeded', file=sys.stderr)
    sys.exit(1)
PY
