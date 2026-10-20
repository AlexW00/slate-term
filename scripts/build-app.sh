#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p artifacts
[[ -d .build/bootstrap/ghostty/macos/GhosttyKit.xcframework ]] || {
  echo 'Run bash scripts/build-ghostty.sh first.' >&2; exit 1;
}
xcodebuild -project slate-term.xcodeproj -scheme SlateTermApp -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath .derived -clonedSourcePackagesDirPath .build/xcode-packages \
  CODE_SIGNING_ALLOWED=NO build > artifacts/app-build.log 2>&1 || { tail -70 artifacts/app-build.log; exit 1; }
# The package CLI also has a slate-term scheme; never mistake its successful build for the app.
grep -Fq "Target 'slate-term' in project 'slate-term'" artifacts/app-build.log
app="$PWD/.derived/Build/Products/Debug/Slate Terminal.app"
# Development-only local signature; the compiled Debug bootstrap permits verified ad-hoc runtime code.
python3 scripts/package-runtime.py sign --app "$app" --identity -
echo "$app"
