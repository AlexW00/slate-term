#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
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
[[ -z "$(git -C "$source_dir" status --porcelain --untracked-files=no)" ]] || {
  echo 'Ghostty sources are modified; refusing an unpinned build.' >&2; exit 1;
}
cd "$source_dir"
"$zig_dir/zig" build -j4 -Doptimize=ReleaseFast -Demit-xcframework=true -Demit-macos-app=false -Dxcframework-target=native
