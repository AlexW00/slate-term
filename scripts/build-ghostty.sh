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
git -C "$source_dir" diff --quiet -- . ':!src/build/SharedDeps.zig' ':!src/termio/Exec.zig' ':!include/ghostty.h' ':!src/apprt/embedded.zig' ':!src/Surface.zig' ':!src/termio/Options.zig' ':!src/termio/Termio.zig' || {
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
# Disposal remains bounded even when startup or ownership inspection fails.
shutdown_patch_sha=bb25ccd279dd824bdfb1bd87f2a2cda221a86fb1a7dee79a1c2f75f22855b533
shutdown_original_sha=9dd5d3854330e589a5a67255531e92738f5f48b1b7dd0be4d39ef2b13fbfab95
shutdown_patched_sha=e3f6cbb941902833881e1f4ebf6be1dd42a2418f8d5b65cb408be24a1b8b11ab
shutdown_patch_file="$root/patches/ghostty-bounded-shutdown.patch"
[[ "$(shasum -a 256 "$shutdown_patch_file" | cut -d ' ' -f1)" = "$shutdown_patch_sha" ]] || {
  echo 'Ghostty shutdown patch checksum mismatch.' >&2; exit 1;
}
shutdown_source_sha="$(shasum -a 256 "$source_dir/src/termio/Exec.zig" | cut -d ' ' -f1)"
case "$shutdown_source_sha" in
  "$shutdown_original_sha")
    git -C "$source_dir" apply --check "$shutdown_patch_file"
    git -C "$source_dir" apply "$shutdown_patch_file" ;;
  "$shutdown_patched_sha") ;;
  *) echo 'Ghostty shutdown target differs from both approved versions.' >&2; exit 1 ;;
esac
[[ "$(shasum -a 256 "$source_dir/src/termio/Exec.zig" | cut -d ' ' -f1)" = "$shutdown_patched_sha" ]]
# Restore display text before the shell starts, without treating it as input.
output_patch_sha=03bdf7d636385e52fefab023831c16008e80f3330d59081ff56d2a8e1ad59916
output_header_original_sha=78232aec570e266b1ccacaa69b0536c9b7757f4cf747ad26b9d7fb2d378848dd
output_header_patched_sha=c774f20ecd34ddaa3f5a35ac71e03f3d11b403fb2943fe4b8e054c4a80bdc4cd
output_embedded_original_sha=45b318567bf891a413224cc70b9a4b4d6ac303abb4e9ff02c788dc1043905e84
output_embedded_patched_sha=4ed28bcfca9be2fc2caa21ca32d02d381d7a90077d65744bc2778043011a96fd
output_surface_original_sha=c284b50d1d1eebfc07ea3a17b5f77df9d46243184493a64cd7c37e317d925e3e
output_surface_patched_sha=24063fb6b84ada78f04a234bd904cf7698928a2bba925ea16bdf0347ef36ff89
output_options_original_sha=c7104b29c0cf1a68da18d88f6241cda4f5330a0066754e47358a85acfdaadeab
output_options_patched_sha=df402bba35cf632bc88cea0c3f27cf679a3e3d15702147acff4e39cc9d7f6ddc
output_termio_original_sha=d80ea8fdecd3da3a9eeefec9a87b92edfc0f2f6db92d23953a7e2003976ffbc7
output_termio_patched_sha=db66cd8425e4e6c30f2d07eeb0062edad0d6f808985ba7a5392b284a4424146e
output_patch_file="$root/patches/ghostty-restored-output.patch"
[[ "$(shasum -a 256 "$output_patch_file" | cut -d ' ' -f1)" = "$output_patch_sha" ]] || {
  echo 'Ghostty restored-output patch checksum mismatch.' >&2; exit 1;
}
output_original=true
output_patched=true
for output_target in header embedded surface options termio; do
  case "$output_target" in
    header) output_path=include/ghostty.h ;;
    embedded) output_path=src/apprt/embedded.zig ;;
    surface) output_path=src/Surface.zig ;;
    options) output_path=src/termio/Options.zig ;;
    termio) output_path=src/termio/Termio.zig ;;
  esac
  output_original_pin="output_${output_target}_original_sha"
  output_patched_pin="output_${output_target}_patched_sha"
  output_source_sha="$(shasum -a 256 "$source_dir/$output_path" | cut -d ' ' -f1)"
  [[ "$output_source_sha" = "${!output_original_pin}" ]] || output_original=false
  [[ "$output_source_sha" = "${!output_patched_pin}" ]] || output_patched=false
done
if [[ "$output_original" = true ]]; then
  git -C "$source_dir" apply --check "$output_patch_file"
  git -C "$source_dir" apply "$output_patch_file"
elif [[ "$output_patched" != true ]]; then
  echo 'Ghostty restored-output targets differ from the approved versions.' >&2; exit 1;
fi
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
inputs = [Path('scripts/build-ghostty.sh'), Path('patches/ghostty-optional-libintl.patch'), Path('patches/ghostty-bounded-shutdown.patch'), Path('patches/ghostty-restored-output.patch')]
for directory in ('.build/bootstrap/ghostty/macos/GhosttyKit.xcframework', '.build/bootstrap/ghostty/zig-out/share'):
    inputs.extend(p for p in sorted(Path(directory).rglob('*')) if p.is_file())
receipt = Path('.build/bootstrap/ghostty-build.sha256')
receipt.write_text(''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p}\n' for p in inputs))
PY_RECEIPT
