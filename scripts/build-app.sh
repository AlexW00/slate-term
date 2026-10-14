#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p artifacts
[[ -d .build/bootstrap/ghostty/macos/GhosttyKit.xcframework ]] || {
  echo 'Run bash scripts/build-ghostty.sh first.' >&2; exit 1;
}
swift build --product slate-term --jobs 4 > artifacts/cli-build.log 2>&1
cli="$(swift build --show-bin-path)/slate-term"
xcodebuild -project slate-term.xcodeproj -scheme SlateTermApp -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath .derived -clonedSourcePackagesDirPath .build/xcode-packages \
  CODE_SIGNING_ALLOWED=NO build > artifacts/app-build.log 2>&1 || { tail -70 artifacts/app-build.log; exit 1; }
# The package CLI also has a slate-term scheme; never mistake its successful build for the app.
grep -Fq "Target 'slate-term' in project 'slate-term'" artifacts/app-build.log
app="$PWD/.derived/Build/Products/Debug/Slate Terminal.app"
mkdir -p "$app/Contents/Helpers"
cp "$cli" "$app/Contents/Helpers/slate-term"
# Development-only local signature. No publishing, notarization, or developer-account changes.
codesign --force --sign - "$app/Contents/Helpers/slate-term"
codesign --force --sign - "$app"
echo "$app"
