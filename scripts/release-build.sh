#!/bin/bash
# Build without credentials; release-package.sh signs the finished bundle.
set -euo pipefail
set +x
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
version=
build_number=
output="$root/artifacts/release"
usage() {
  echo 'Usage: release-build.sh --version X.Y.Z --build-number N [--output DIR]'
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version|--build-number|--output)
      [[ $# -ge 2 && -n "$2" ]] || { usage >&2; exit 2; }
      case "$1" in
        --version) version="$2" ;;
        --build-number) build_number="$2" ;;
        --output) output="$2" ;;
      esac
      shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$build_number" =~ ^[1-9][0-9]*$ ]] || {
  echo 'Supply a three-component version and positive numeric build number.' >&2; exit 2;
}
[[ "$(uname -s)" = Darwin && "$(uname -m)" = arm64 ]] || {
  echo 'Release builds require an Apple Silicon Mac.' >&2; exit 1;
}
# Both toolchains need several gigabytes for intermediate build products.
free_kib="$(df -Pk "$root" | awk 'NR == 2 {print $4}')"
[[ "$free_kib" =~ ^[0-9]+$ && "$free_kib" -ge 5242880 ]] || {
  echo 'At least 5 GiB of free disk space is required for a release build.' >&2; exit 1;
}
sdk="$(xcrun --sdk macosx --show-sdk-version)"
[[ "${sdk%%.*}" -ge 27 ]] || { echo 'The app requires Xcode with macOS SDK 27 or later.' >&2; exit 1; }
[[ -d .build/bootstrap/ghostty/macos/GhosttyKit.xcframework ]] || {
  echo 'Run bash scripts/build-ghostty.sh first.' >&2; exit 1;
}
[[ -f .build/bootstrap/ghostty-build.sha256 ]] && shasum -a 256 -c .build/bootstrap/ghostty-build.sha256 > /dev/null || {
  echo 'Ghostty build receipt is missing or stale; rerun scripts/build-ghostty.sh.' >&2; exit 1;
}
mkdir -p "$output"
output="$(cd "$output" && pwd)"
app="$output/Slate Terminal.app"
[[ ! -e "$app" ]] || { echo 'Output app already exists; choose a fresh output directory.' >&2; exit 1; }
source_commit="$(git rev-parse HEAD)"
source_dirty=false
if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then source_dirty=true; fi
# Each checkout owns its build directories, including linked worktrees.
xcodebuild -project slate-term.xcodeproj -scheme SlateTermApp -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$root/.derived-release" \
  -clonedSourcePackagesDirPath "$root/.build/xcode-packages" \
  -onlyUsePackageVersionsFromResolvedFile \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  ENABLE_HARDENED_RUNTIME=YES MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build_number" \
  build > "$output/build.log" 2>&1 || {
    echo "Release build failed; inspect $output/build.log" >&2; exit 1;
  }
built="$root/.derived-release/Build/Products/Release/Slate Terminal.app"
for tool in slate-term slate-layout-launcher; do
  [[ -x "$built/Contents/Helpers/$tool" ]] || { echo "Missing embedded helper: $tool" >&2; exit 1; }
  codesign --verify --strict "$built/Contents/Helpers/$tool"
done
# A loader failure here would break every installed CLI command.
env -u DYLD_FRAMEWORK_PATH -u DYLD_LIBRARY_PATH "$built/Contents/Helpers/slate-term" --help > /dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$built/Contents/Info.plist")" = "$version" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$built/Contents/Info.plist")" = "$build_number" ]]
[[ "$(lipo -archs "$built/Contents/MacOS/Slate Terminal")" = arm64 ]]
if [[ "$source_dirty" = false ]] && { [[ "$(git rev-parse HEAD)" != "$source_commit" ]] || [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; }; then
  echo 'Source changed during the build; rebuild before preparing release assets.' >&2; exit 1;
fi
ditto "$built" "$app"
python3 scripts/collect-release-licenses.py --app "$app"
python3 - "$app" "$output/build-source.json" "$source_commit" "$source_dirty" "$version" "$build_number" <<'PY_RECEIPT'
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
app = Path(sys.argv[1])
digest = hashlib.sha256()
for path in sorted(app.rglob('*'), key=lambda p: p.relative_to(app).as_posix()):
    name = path.relative_to(app).as_posix().encode()
    mode = str(stat.S_IMODE(path.lstat().st_mode)).encode()
    if path.is_symlink():
        kind, value = b'l', os.readlink(path).encode()
    elif path.is_file():
        kind, value = b'f', hashlib.sha256(path.read_bytes()).hexdigest().encode()
    else:
        kind, value = b'd', b''
    digest.update(kind + b'\0' + name + b'\0' + mode + b'\0' + value + b'\n')
receipt = {
    'source_commit': sys.argv[3], 'source_dirty': sys.argv[4] == 'true',
    'version': sys.argv[5], 'build_number': sys.argv[6],
    'ghostty_revision': subprocess.check_output(['git', '-C', '.build/bootstrap/ghostty', 'rev-parse', 'HEAD'], text=True).strip(),
    'app_tree_sha256': digest.hexdigest(),
}
Path(sys.argv[2]).write_text(json.dumps(receipt, indent=2) + '\n')
PY_RECEIPT
printf 'Built %s\n' "$app"
