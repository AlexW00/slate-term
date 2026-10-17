#!/bin/bash
# Install and verify the separate Metal component on GitHub-hosted runners.
set -euo pipefail

metal_temp=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/slate-metal.XXXXXX")
trap 'rm -rf "$metal_temp"' EXIT

if ! xcrun --no-cache --sdk macosx metal --version; then
    if [[ "${GITHUB_ACTIONS:-}" != "true" ]]; then
        echo "Metal is unavailable; automatic installation is restricted to GitHub Actions." >&2
        exit 1
    fi

    xcodebuild -downloadComponent MetalToolchain
    xcrun --kill-cache
    if ! xcrun --no-cache --sdk macosx metal --version; then
        xcodebuild -showComponent MetalToolchain -json > "$metal_temp/component.json"
        cat "$metal_temp/component.json"
        metal_dmg=$(python3 - "$metal_temp/component.json" <<'PYTHON'
import json
from pathlib import Path
import sys

component = json.loads(Path(sys.argv[1]).read_text())
asset_path = component.get("assetPath")
if component.get("status") != "installed" or not isinstance(asset_path, str):
    sys.exit("Xcode did not report an installed Metal component with an asset path.")
asset = Path(asset_path)
if not asset.is_absolute():
    sys.exit("Xcode reported a relative Metal asset path.")
images = [path for path in (asset / "Restore").glob("*.dmg") if path.is_file()]
if len(images) != 1:
    sys.exit(f"Expected one disk image in the installed Metal asset, found {len(images)}.")
print(images[0])
PYTHON
)
        # Xcode can discover this volume when automatic cryptex mounting fails.
        # Keep it mounted for later build steps; the disposable runner owns cleanup.
        if ! hdiutil attach -readonly -nobrowse "$metal_dmg"; then
            xcodebuild -showComponent MetalToolchain -json || true
            hdiutil info || true
            exit 1
        fi
        xcrun --kill-cache
        if ! xcrun --no-cache --sdk macosx metal --version; then
            xcodebuild -showComponent MetalToolchain -json || true
            hdiutil info || true
            exit 1
        fi
    fi
fi

cat > "$metal_temp/smoke.metal" <<'METAL'
#include <metal_stdlib>
using namespace metal;
kernel void slate_metal_smoke(device uint *output [[buffer(0)]],
                             uint index [[thread_position_in_grid]]) {
    output[index] = index;
}
METAL
xcrun --no-cache --sdk macosx metal -c "$metal_temp/smoke.metal" -o "$metal_temp/smoke.air"
test -s "$metal_temp/smoke.air"
echo "Metal compiler and shader compilation verified."
