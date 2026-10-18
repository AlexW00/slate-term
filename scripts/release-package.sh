#!/bin/bash
# Signing uses installed identities and a notarytool keychain profile.
set -euo pipefail
set +x
root="$(cd "$(dirname "$0")/.." && pwd)"
app="$root/artifacts/release/Slate Terminal.app"
output="$root/artifacts/release/assets"
unsigned=0
usage() {
  cat <<'USAGE'
Usage: release-package.sh [--app PATH] [--output DIR] [--unsigned]
Signed releases require SLATE_SIGNING_IDENTITY and SLATE_NOTARY_PROFILE.
Optional: SLATE_SIGNING_KEYCHAIN and SLATE_NOTARY_KEYCHAIN.
--unsigned creates distinctly named local smoke-test assets without notarization.
USAGE
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app|--output)
      [[ $# -ge 2 && -n "$2" ]] || { usage >&2; exit 2; }
      case "$1" in --app) app="$2" ;; --output) output="$2" ;; esac
      shift 2 ;;
    --unsigned) unsigned=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ "$(uname -s)" = Darwin ]] || { echo 'Packaging requires macOS.' >&2; exit 1; }
[[ -d "$app" && ! -L "$app" ]] || { echo 'The input must be an app bundle directory.' >&2; exit 1; }
app="$(cd "$app" && pwd)"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$build_number" =~ ^[1-9][0-9]*$ ]] || {
  echo 'The app must have a release version and numeric build number.' >&2; exit 1;
}
name="Slate-Terminal-$version-$build_number-arm64"
if [[ "$unsigned" = 1 ]]; then
  name="$name-unsigned"
else
  [[ "${SLATE_SIGNING_IDENTITY:-}" = 'Developer ID Application: '* || "${SLATE_SIGNING_IDENTITY:-}" =~ ^[A-Fa-f0-9]{40}$ ]] || {
    echo 'SLATE_SIGNING_IDENTITY must name a Developer ID Application identity or its SHA-1 fingerprint.' >&2; exit 1;
  }
  python3 - <<'PY_IDENTITY'
import os
import re
import subprocess
identity = os.environ['SLATE_SIGNING_IDENTITY']
if re.fullmatch(r'[A-Fa-f0-9]{40}', identity):
    args = ['security', 'find-identity', '-v', '-p', 'codesigning']
    if os.environ.get('SLATE_SIGNING_KEYCHAIN'):
        args.append(os.environ['SLATE_SIGNING_KEYCHAIN'])
    result = subprocess.run(args, capture_output=True, text=True)
    pattern = r'\b' + re.escape(identity) + r'\s+"Developer ID Application: '
    if result.returncode or not re.search(pattern, result.stdout, re.IGNORECASE):
        raise SystemExit('The signing fingerprint is not an available Developer ID Application identity.')
PY_IDENTITY
  python3 "$root/scripts/release-updates.py" validate-config --app "$app"
  python3 "$root/scripts/collect-release-licenses.py" --verify-app "$app"
  [[ -n "${SLATE_NOTARY_PROFILE:-}" ]] || { echo 'Set SLATE_NOTARY_PROFILE to an existing notarytool keychain profile.' >&2; exit 1; }
fi
mkdir -p "$output"
output="$(cd "$output" && pwd)"
source_asset="Slate-Terminal-$version-$build_number-source.tar.gz"
if [[ "$unsigned" = 0 && ! -f "$output/$source_asset" ]]; then
  echo 'Create the matching source archive with release-source.py before signing.' >&2; exit 1;
fi
if [[ "$unsigned" = 0 ]]; then
  python3 "$root/scripts/release-source.py" --verify-build \
    --build-receipt "$(dirname "$app")/build-source.json" --app "$app" \
    --source-archive "$output/$source_asset"
fi
for asset in "$name.zip" "$name.dmg" SHA256SUMS; do
  [[ ! -e "$output/$asset" ]] || { echo 'Release assets already exist; choose a fresh output directory.' >&2; exit 1; }
done
stage="$(mktemp -d "$output/.package.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
bundle="$stage/Slate Terminal.app"
ditto "$app" "$bundle"
# Sign executable files first, nested bundles next, and the outer app last.
python3 - "$bundle" "$unsigned" <<'PY'
import os
from pathlib import Path
import plistlib
import subprocess
import sys
app = Path(sys.argv[1])
unsigned = sys.argv[2] == '1'
sparkle = app / 'Contents/Frameworks/Sparkle.framework'
for relative in ('Versions/B/Autoupdate', 'Versions/B/Updater.app/Contents/MacOS/Updater',
                 'Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer',
                 'Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader'):
    if not os.access(sparkle / relative, os.X_OK):
        raise SystemExit('Missing executable Sparkle component: ' + relative)
with (sparkle / 'Resources/Info.plist').open('rb') as stream:
    if plistlib.load(stream).get('CFBundleShortVersionString') != '2.10.0':
        raise SystemExit('The embedded Sparkle version does not match the release pin.')
for tool in ('slate-term', 'slate-layout-launcher'):
    if not os.access(app / 'Contents' / 'Helpers' / tool, os.X_OK):
        raise SystemExit(f'Missing executable helper: {tool}')
files = [p for p in app.rglob('*') if p.is_file() and not p.is_symlink()]
machos = [p for p in files if 'Mach-O' in subprocess.check_output(['file', '-b', str(p)], text=True)]
if not machos:
    raise SystemExit('No executable code in the app.')
for path in machos:
    architectures = set(subprocess.check_output(['lipo', '-archs', str(path)], text=True).split())
    allowed = ({'arm64'}, {'arm64', 'x86_64'}) if path.is_relative_to(sparkle) else ({'arm64'},)
    if architectures not in allowed:
        raise SystemExit(f'Expected Apple Silicon code: {path.relative_to(app)}')
if not unsigned:
    command = ['codesign', '--force', '--sign', os.environ['SLATE_SIGNING_IDENTITY'], '--timestamp', '--options', 'runtime']
    if os.environ.get('SLATE_SIGNING_KEYCHAIN'):
        command += ['--keychain', os.environ['SLATE_SIGNING_KEYCHAIN']]
    bundles = [p for p in app.rglob('*') if p.is_dir() and not p.is_symlink() and p.suffix in ('.framework', '.app', '.xpc', '.appex')]
    for path in sorted(machos, key=lambda p: len(p.parts), reverse=True) + sorted(bundles, key=lambda p: len(p.parts), reverse=True) + [app]:
        # Sparkle requires Downloader's own entitlements to survive manual signing.
        downloader = sparkle / 'Versions/B/XPCServices/Downloader.xpc'
        preserve = ['--preserve-metadata=entitlements'] if path == downloader or path.is_relative_to(downloader) else []
        subprocess.run(command + preserve + [str(path)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', '--verbose=2', str(app)], check=True)
PY
notarize() {
  local asset="$1" receipt="$2"
  local args=(--keychain-profile "$SLATE_NOTARY_PROFILE")
  if [[ -n "${SLATE_NOTARY_KEYCHAIN:-}" ]]; then args+=(--keychain "$SLATE_NOTARY_KEYCHAIN"); fi
  xcrun notarytool submit "$asset" "${args[@]}" --wait --timeout 30m --output-format json > "$receipt"
  python3 - "$receipt" <<'PY'
import json
import sys
with open(sys.argv[1]) as f:
    result = json.load(f)
if result.get('status') != 'Accepted':
    raise SystemExit('Notarization was not accepted. Inspect the local submission receipt.')
PY
}
if [[ "$unsigned" = 0 ]]; then
  ditto -c -k --sequesterRsrc --keepParent "$bundle" "$stage/notarization.zip"
  notarize "$stage/notarization.zip" "$output/app-notarization.json"
  xcrun stapler staple "$bundle"
  xcrun stapler validate "$bundle"
  spctl --assess --type execute --verbose=2 "$bundle"
fi
# The final ZIP includes the stapled app ticket.
ditto -c -k --sequesterRsrc --keepParent "$bundle" "$stage/$name.zip"
mkdir "$stage/dmg"
ditto "$bundle" "$stage/dmg/Slate Terminal.app"
ln -s /Applications "$stage/dmg/Applications"
hdiutil create -quiet -volname 'Slate Terminal' -srcfolder "$stage/dmg" -format UDZO "$stage/$name.dmg"
if [[ "$unsigned" = 0 ]]; then
  sign_args=(--force --sign "$SLATE_SIGNING_IDENTITY" --timestamp)
  if [[ -n "${SLATE_SIGNING_KEYCHAIN:-}" ]]; then sign_args+=(--keychain "$SLATE_SIGNING_KEYCHAIN"); fi
  codesign "${sign_args[@]}" "$stage/$name.dmg"
  notarize "$stage/$name.dmg" "$output/dmg-notarization.json"
  xcrun stapler staple "$stage/$name.dmg"
  xcrun stapler validate "$stage/$name.dmg"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$stage/$name.dmg"
fi
mv "$stage/$name.zip" "$stage/$name.dmg" "$output/"
checksum_assets=("$name.zip" "$name.dmg")
if [[ "$unsigned" = 0 ]]; then checksum_assets+=("$source_asset"); fi
(cd "$output" && shasum -a 256 "${checksum_assets[@]}" > SHA256SUMS && shasum -a 256 -c SHA256SUMS)
printf 'Packaged assets in %s\n' "$output"
