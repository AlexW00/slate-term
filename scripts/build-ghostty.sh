#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
# Both toolchains need several gigabytes for intermediate build products.
free_kib="$(df -Pk "$root" | awk 'NR == 2 {print $4}')"
[[ "$free_kib" =~ ^[0-9]+$ && "$free_kib" -ge 5242880 ]] || {
  echo 'At least 5 GiB of free disk space is required for a release build.' >&2; exit 1;
}
# Full macOS surface API, not the VT-only library. Deliberate upgrades only.
revision=554ea65867ffe34bb3e51e09bd016e154a1f9d7a
zig_version=0.16.0
case "$(uname -m)" in
  arm64) zig_arch=aarch64; zig_sha=b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489 ;;
  *) echo 'This bootstrap currently verifies Apple Silicon only.' >&2; exit 1 ;;
esac
mkdir -p .tools .build/bootstrap
zig_dir="$PWD/.tools/zig-$zig_arch-macos-$zig_version"
if [[ ! -x "$zig_dir/zig" ]]; then
  archive="$PWD/.tools/zig-$zig_version.tar.xz"
  curl --fail --location --max-time 300 "https://ziglang.org/download/$zig_version/zig-$zig_arch-macos-$zig_version.tar.xz" -o "$archive"
  echo "$zig_sha  $archive" | shasum -a 256 -c -
  tar -xf "$archive" -C .tools
fi
[[ "$("$zig_dir/zig" version)" == "$zig_version" ]]
source_dir="$PWD/.build/bootstrap/ghostty"
if [[ ! -d "$source_dir/.git" ]]; then
  git init "$source_dir"
  git -C "$source_dir" remote add origin https://github.com/ghostty-org/ghostty.git
  git -C "$source_dir" fetch --depth 1 origin "$revision"
  git -C "$source_dir" checkout --detach FETCH_HEAD
fi
[[ "$(git -C "$source_dir" rev-parse HEAD)" == "$revision" ]] || {
  echo 'Ghostty checkout does not match the pin; refusing to build.' >&2; exit 1;
}
patch_file="$root/patches/ghostty-optional-libintl.patch"
patch_sha=8ebfeee08d13faed22f057d538d08fcf914f28b7d35054faa2fcc905a6aed517
original_sha=257fa7f4782dea68190d214b885d9fe9e5398e3585de7d223805e7239e643d03
patched_sha=ecbbf61a3a432ffb457e8f07e5c79913d6b121f9c5e8ac63950ce6449dba1fb9
[[ "$(shasum -a 256 "$patch_file" | cut -d ' ' -f1)" = "$patch_sha" ]] || {
  echo 'Ghostty patch checksum mismatch.' >&2; exit 1;
}
git -C "$source_dir" diff --cached --quiet || { echo 'Ghostty has staged changes.' >&2; exit 1; }
git -C "$source_dir" diff --quiet -- . ':!src/build/SharedDeps.zig' || {
  echo 'Ghostty sources differ from the pin outside the approved patch.' >&2; exit 1;
}
source_sha="$(shasum -a 256 "$source_dir/src/build/SharedDeps.zig" | cut -d ' ' -f1)"
case "$source_sha" in
  "$original_sha")
    git -C "$source_dir" apply --check "$patch_file"
    git -C "$source_dir" apply "$patch_file" ;;
  "$patched_sha") ;; # Reusing this checkout is safe after exact content verification.
  *) echo 'Ghostty patch target differs from both approved versions.' >&2; exit 1 ;;
esac
[[ "$(shasum -a 256 "$source_dir/src/build/SharedDeps.zig" | cut -d ' ' -f1)" = "$patched_sha" ]]
# Compiler caches belong to this checkout, including linked worktrees.
export ZIG_GLOBAL_CACHE_DIR="$root/.build/release-zig-cache"
export ZIG_LOCAL_CACHE_DIR="$source_dir/.zig-cache"
# Slate supplies its own UI and does not enable upstream localization or telemetry.
cd "$source_dir"
"$zig_dir/zig" build -j4 -Doptimize=ReleaseFast -Demit-xcframework=true -Demit-macos-app=false \
  -Dxcframework-target=native -Di18n=false -Dsentry=false
cd "$root"
library=.build/bootstrap/ghostty/macos/GhosttyKit.xcframework/macos-arm64/libghostty-internal.a
symbols="$(mktemp "$root/.build/bootstrap/ghostty-symbols.XXXXXX")"
trap 'rm -f "$symbols"' EXIT
nm -g "$library" > "$symbols"
if grep -Eq '(^|[[:space:]])_(libintl_|sentry_|gettext$|dgettext$|dcgettext$|ngettext$|dngettext$|dcngettext$|textdomain$|bindtextdomain$)' "$symbols"; then
  echo 'Unexpected gettext or telemetry symbols in the Ghostty library.' >&2; exit 1;
fi
# Cached frameworks must match both build inputs and their complete output tree.
python3 - <<'PY_RECEIPT'
import hashlib
from pathlib import Path
inputs = [Path('scripts/build-ghostty.sh'), Path('patches/ghostty-optional-libintl.patch')]
for directory in ('.build/bootstrap/ghostty/macos/GhosttyKit.xcframework', '.build/bootstrap/ghostty/zig-out/share'):
    inputs.extend(p for p in sorted(Path(directory).rglob('*')) if p.is_file())
receipt = Path('.build/bootstrap/ghostty-build.sha256')
receipt.write_text(''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p}\n' for p in inputs))
PY_RECEIPT
