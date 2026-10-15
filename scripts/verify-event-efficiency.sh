#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# The native fixture creates an unattached surface and private stores, never windows.
swift build --product slate-term --jobs 4
bin="$(swift build --show-bin-path)"
framework="$PWD/.build/bootstrap/ghostty/macos/GhosttyKit.xcframework/macos-arm64"
test -f "$framework/libghostty-internal.a"
gate="$(mktemp -d "${TMPDIR:-/tmp}/slate-event-efficiency.XXXXXX")"
trap 'rm -rf "$gate"' EXIT
swiftc -swift-version 5 -default-isolation MainActor -parse-as-library -g \
  -I "$bin" -L "$bin" -lSlateTermSettings -I "$framework/Headers" \
  Native/Terminal/*.swift Native/ApplicationSettings.swift \
  Native/PluginInstance.swift Native/PluginProcess.swift Native/PluginListener.swift Native/PluginControlConnection.swift \
  Tests/EventHub/EventEfficiency.swift "$framework/libghostty-internal.a" \
  -framework AppKit -framework WebKit -framework Metal -framework MetalKit -framework QuartzCore \
  -framework CoreText -framework CoreGraphics -framework Carbon -framework IOKit -lc++ -lz \
  -o "$gate/event-efficiency"
export GHOSTTY_RESOURCES_DIR="$PWD/.build/bootstrap/ghostty/zig-out/share/ghostty"
mkdir -p "$gate/ghostty/themes"
cp "$GHOSTTY_RESOURCES_DIR/themes/Builtin Light" "$GHOSTTY_RESOURCES_DIR/themes/Builtin Dark" "$gate/ghostty/themes/"
python3 - "$gate/event-efficiency" <<'PY'
import subprocess
import sys
try:
    sys.exit(subprocess.run(sys.argv[1:], timeout=30).returncode)
except subprocess.TimeoutExpired:
    print('FAIL event efficiency: deadline exceeded', file=sys.stderr)
    sys.exit(1)
PY
node Tests/EventHub/ThemeRefresh.cjs
