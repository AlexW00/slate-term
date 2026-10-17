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

    # Import the exported component explicitly so Xcode registers the downloaded asset.
    mkdir -p "$metal_temp/component"
    xcodebuild -downloadComponent MetalToolchain -exportPath "$metal_temp/component"
    metal_bundles=()
    while IFS= read -r -d '' bundle; do
        metal_bundles+=("$bundle")
    done < <(find "$metal_temp/component" -name '*.exportedBundle' -type d -prune -print0)
    if [[ "${#metal_bundles[@]}" -ne 1 ]]; then
        echo "Expected one exported Metal component, found ${#metal_bundles[@]}." >&2
        exit 1
    fi
    xcodebuild -importComponent MetalToolchain -importPath "${metal_bundles[0]}"
    xcrun --kill-cache
    xcodebuild -showComponent MetalToolchain
    xcrun --no-cache --sdk macosx metal --version
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
