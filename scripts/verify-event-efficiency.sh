#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/native-gate.sh
slate_native_gate event-efficiency
if [[ "${SLATE_VM_PREBUILT:-0}" != 1 ]]; then
# The native fixture creates an unattached surface and private stores, never windows.
swift build --product slate-term --jobs 4
bin="$(swift build --show-bin-path)"
framework="$PWD/.build/bootstrap/ghostty/macos/GhosttyKit.xcframework/macos-arm64"
test -f "$framework/libghostty-internal.a"
slate_native_swiftc -swift-version 5 -default-isolation MainActor -parse-as-library -g \
  -I "$bin" -L "$bin" -lSlateTermSettings -I "$framework/Headers" \
  Native/Terminal/*.swift Native/TerminalProcessShutdown.swift Native/ApplicationSettings.swift Native/RuntimeBundle.swift Native/ApplicationLaunchContext.swift \
  Native/PluginInstance.swift Native/PluginProcess.swift Native/PluginListener.swift Native/PluginControlConnection.swift \
  Tests/EventHub/EventEfficiency.swift "$framework/libghostty-internal.a" \
  -framework AppKit -framework WebKit -framework Metal -framework MetalKit -framework QuartzCore \
  -framework CoreText -framework CoreGraphics -framework Carbon -framework IOKit -lc++ -lz \
  -o "$gate/event-efficiency"
fi
slate_native_ready "$gate/event-efficiency"
export GHOSTTY_RESOURCES_DIR="$PWD/.build/bootstrap/ghostty/zig-out/share/ghostty"
# This fixture deliberately corrupts/restores a palette to exercise its cache.
# Keep its resource directory private rather than modifying packaged/shared inputs.
fixture="$(mktemp -d /tmp/slate-event-efficiency.XXXXXXXX)"
trap 'rm -rf "$fixture"' EXIT
cp "$gate/event-efficiency" "$fixture/"
for library in "$gate"/*.dylib; do
  if [[ -f "$library" ]]; then cp "$library" "$fixture/"; fi
done
mkdir -p "$fixture/ghostty/themes"
cp "$GHOSTTY_RESOURCES_DIR/themes/Builtin Light" "$GHOSTTY_RESOURCES_DIR/themes/Builtin Dark" "$fixture/ghostty/themes/"
python3 - "$fixture/event-efficiency" <<'PY'
import subprocess
import sys
try:
    sys.exit(subprocess.run(sys.argv[1:], timeout=30).returncode)
except subprocess.TimeoutExpired:
    print('FAIL event efficiency: deadline exceeded', file=sys.stderr)
    sys.exit(1)
PY
node Tests/EventHub/ThemeRefresh.cjs
