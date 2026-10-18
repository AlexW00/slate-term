#!/usr/bin/env python3
"""Validate the pinned notice inventory and copy it into a release app offline."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import sys
import tempfile


ROOT = Path(__file__).resolve().parent.parent
LICENSES = ROOT / "licenses"
BUNDLE_DIRECTORY = Path("Contents/Resources/ThirdPartyLicenses")


def digest(data):
    return hashlib.sha256(data).hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def pinned_revisions(path):
    resolved = json.loads(path.read_text())
    return {pin["identity"]: pin["state"]["revision"] for pin in resolved["pins"]}


def validate_inventory():
    manifest_bytes = (LICENSES / "manifest.json").read_bytes()
    manifest = json.loads(manifest_bytes)
    require(manifest["schema"] == 1, "Unsupported license manifest schema")
    for resolved, pin_key in (
        (ROOT / "Package.resolved", "swift_pins"),
        (ROOT / "slate-term.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved", "xcode_swift_pins"),
    ):
        require(pinned_revisions(resolved) == manifest[pin_key],
                "Swift dependencies changed; review and refresh licenses/manifest.json")

    bootstrap = (ROOT / "scripts/build-ghostty.sh").read_text()
    for variable, expected in (("revision", manifest["ghostty_revision"]),
                               ("zig_version", manifest["zig_version"])):
        match = re.search(r"^" + variable + r"=[\"']?([^\s\"']+)", bootstrap, re.MULTILINE)
        require(match is not None and match.group(1) == expected,
                "Ghostty or Zig pin changed; review and refresh the license inventory")
    for feature in manifest["ghostty_disabled_features"]:
        require("-D" + feature + "=false" in bootstrap,
                "License inventory expects Ghostty " + feature + " to remain disabled")

    files = {}
    required_components = {"ghostty", "swift-argument-parser", "TOMLDecoder", "z2d",
                           "freetype", "nerd_fonts_symbols_only", "jetbrains_mono", "Sparkle"}
    require(required_components <= set(manifest["components"]), "Missing required license components")
    for component, entries in manifest["components"].items():
        require(bool(entries), "Empty license component: " + component)
        for entry in entries:
            relative = Path(entry["file"])
            require(not relative.is_absolute() and ".." not in relative.parts,
                    "Unsafe license path")
            require(entry["file"] not in files, "Duplicate license path")
            source = LICENSES / relative
            require(source.resolve().is_relative_to(LICENSES.resolve()) and not source.is_symlink(),
                    "License paths must stay inside the inventory")
            data = source.read_bytes()
            require(digest(data) == entry["sha256"], "License checksum mismatch: " + entry["file"])
            files[entry["file"]] = data

    actual = {str(path.relative_to(LICENSES)) for path in LICENSES.rglob("*") if path.is_file()}
    require(actual == set(files) | {"manifest.json"}, "Unrecorded or missing files in licenses/")
    files["manifest.json"] = manifest_bytes
    files["THIRD_PARTY_NOTICES.md"] = (ROOT / "THIRD_PARTY_NOTICES.md").read_bytes()
    files["PROJECT-LICENSE.txt"] = (ROOT / "LICENSE").read_bytes()
    files["COPYING.md"] = (ROOT / "COPYING.md").read_bytes()
    return files, len(manifest["components"])


def bundle_destination(app):
    app = app.resolve()
    require((app / "Contents/Info.plist").is_file(), "Expected a macOS application bundle")
    destination = app / BUNDLE_DIRECTORY
    require(destination.resolve().is_relative_to(app), "License destination must stay inside the app")
    require(not destination.is_symlink(), "License destination must not be a symbolic link")
    return destination


def verify_bundle(destination, files):
    require(destination.is_dir(), "App is missing its bundled license inventory")
    actual = {str(path.relative_to(destination)) for path in destination.rglob("*") if path.is_file()}
    require(actual == set(files), "App license inventory has missing or unexpected files")
    for relative, expected in files.items():
        path = destination / relative
        require(not path.is_symlink() and path.resolve().is_relative_to(destination.resolve()),
                "App license files must not escape the inventory")
        require(path.read_bytes() == expected, "App license mismatch: " + relative)


def install_bundle(destination, files):
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix=".ThirdPartyLicenses-", dir=destination.parent))
    try:
        for relative, data in sorted(files.items()):
            path = temporary / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        if destination.exists():
            require(destination.is_dir() and (destination / "manifest.json").is_file(),
                    "Refusing to replace an unrecognized license directory")
            shutil.rmtree(destination)
        temporary.rename(destination)
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)
    verify_bundle(destination, files)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group()
    action.add_argument("--check", action="store_true", help="Check the committed inventory (default)")
    action.add_argument("--app", type=Path, help="Install notices before signing this app")
    action.add_argument("--verify-app", type=Path, help="Verify all notices without changing this app")
    args = parser.parse_args()
    files, components = validate_inventory()
    if args.app:
        install_bundle(bundle_destination(args.app), files)
    elif args.verify_app:
        verify_bundle(bundle_destination(args.verify_app), files)
    print(f"License inventory verified: {components} components, {len(files)} bundled files")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError) as error:
        print("License inventory failed: " + str(error), file=sys.stderr)
        sys.exit(1)
