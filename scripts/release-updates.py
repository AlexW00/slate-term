#!/usr/bin/env python3
"""Prepare signed Sparkle assets locally; never publish a release or update a feed."""
import argparse
import base64
import binascii
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
VERSION = "2.10.0"
TOOLS_SHA256 = "c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c"
TOOLS_URL = f"https://github.com/sparkle-project/Sparkle/releases/download/{VERSION}/Sparkle-{VERSION}.tar.xz"
NS = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


class UpdateError(ValueError):
    """A static diagnostic that is safe to display without credential material."""


def require(condition, message):
    if not condition:
        raise UpdateError(message)


def decode_key(value, lengths):
    try:
        data = base64.b64decode(value, validate=True)
    except (ValueError, binascii.Error):
        raise UpdateError("Invalid update key encoding") from None
    require(len(data) in lengths, "Invalid update key length")
    return data


def validate_public_configuration(public_key, feed, repository=None):
    decode_key(public_key, (32,))
    require(re.fullmatch(r"https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/releases/latest/download/appcast\.xml", feed),
            "Update feed must be the stable GitHub latest-release appcast URL")
    if repository:
        require(feed == f"https://github.com/{repository}/releases/latest/download/appcast.xml",
                "Update feed does not match the release repository")

def validate_configuration(info, repository=None):
    validate_public_configuration(info.get("SUPublicEDKey", ""), info.get("SUFeedURL", ""), repository)
    require(info.get("SURequireSignedFeed") is True, "Signed update feeds must be required")
    require(info.get("SUVerifyUpdateBeforeExtraction") is True, "Updates must be verified before extraction")
    require(type(info.get("SUSignedFeedFailureExpirationInterval")) in (int, float) and
            info["SUSignedFeedFailureExpirationInterval"] == 0, "Feed signature validation must not expire")


def validate_notes(path):
    require(path.is_file() and not path.is_symlink(), "Provide a regular reviewed release notes file")
    require(0 < path.stat().st_size <= 256 * 1_024, "Release notes exceed native update size limit")
    try:
        content = path.read_bytes().decode("utf-8")
    except UnicodeDecodeError:
        raise UpdateError("Release notes must be UTF-8 text") from None
    require(content.strip() and "\x00" not in content, "Provide nonempty reviewed release notes text")


def bootstrap_tools(destination):
    require(not destination.exists(), "Sparkle tools destination already exists; use a fresh directory")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=destination.parent) as temporary:
        temporary = Path(temporary)
        archive = temporary / "sparkle.tar.xz"
        with urllib.request.urlopen(TOOLS_URL, timeout=60) as response, archive.open("wb") as output:
            shutil.copyfileobj(response, output)
        require(hashlib.sha256(archive.read_bytes()).hexdigest() == TOOLS_SHA256, "Sparkle tool archive checksum mismatch")
        extracted = temporary / "extracted"
        extracted.mkdir()
        with tarfile.open(archive) as source:
            for member in source:
                target = extracted / member.name
                require(target.resolve().is_relative_to(extracted.resolve()), "Unsafe Sparkle archive path")
                require(member.isfile() or member.isdir() or member.issym(), "Unsupported Sparkle archive member")
                if member.issym():
                    require((target.parent / member.linkname).resolve().is_relative_to(extracted.resolve()),
                            "Unsafe Sparkle archive link")
                source.extract(member, extracted)
        for name in ("generate_appcast", "sign_update"):
            require((extracted / "bin" / name).is_file(), "Sparkle release is missing required tools")
        # Bind the whole extracted distribution, including libraries loaded by the tools.
        hashes = {str(p.relative_to(extracted)): hashlib.sha256(p.read_bytes()).hexdigest()
                  for p in extracted.rglob("*") if p.is_file() and not p.is_symlink()}
        (extracted / "slate-tool-receipt.json").write_text(json.dumps({"archive_sha256": TOOLS_SHA256, "files": hashes}))
        extracted.rename(destination)


def verify_tools(directory):
    receipt = json.loads((directory / "slate-tool-receipt.json").read_text())
    require(receipt.get("archive_sha256") == TOOLS_SHA256, "Unexpected Sparkle tool distribution")
    actual = {str(p.relative_to(directory)): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in directory.rglob("*") if p.is_file() and not p.is_symlink() and p.name != "slate-tool-receipt.json"}
    require(actual == receipt.get("files"), "Sparkle tools changed after download")


def run_tool(tools, name, arguments, secret, cwd):
    # Sparkle can print malformed key material in an error. Never forward its output.
    environment = {k: v for k, v in os.environ.items()
                   if not k.startswith(("SLATE_", "SPARKLE_", "OP_", "DYLD_"))}
    result = subprocess.run([str(tools / "bin" / name), "--ed-key-file", "-", *arguments],
                            input=secret + "\n", capture_output=True, text=True,
                            env=environment, cwd=cwd, timeout=300)
    require(result.returncode == 0, "Sparkle " + name + " failed; tool output withheld to protect signing inputs")
    return result.stdout


def inspect_appcast(path, archive, notes, repository, version, build):
    require(0 < archive.stat().st_size <= 512 * 1_024 * 1_024, "Archive exceeds native update size limit")
    require(0 < notes.stat().st_size <= 256 * 1_024, "Release notes exceed native update size limit")
    tree = ET.fromstring(path.read_bytes())
    items = tree.findall("./channel/item")
    require(len(items) == 1, "Expected exactly one update in this release appcast")
    item = items[0]
    require(item.findtext(NS + "version") == build and item.findtext(NS + "shortVersionString") == version,
            "Appcast version does not match the release")
    require(item.findtext(NS + "minimumSystemVersion") == "27.0", "Unexpected minimum macOS version")
    require(item.find(NS + "channel") is None, "Stable releases must use the default update channel")
    prefix = f"https://github.com/{repository}/releases/download/v{version}/"
    enclosure = item.find("enclosure")
    require(enclosure is not None and enclosure.get("url") == prefix + archive.name,
            "Appcast archive must use this release's immutable asset URL")
    require(enclosure.get("length") == str(archive.stat().st_size), "Appcast archive size mismatch")
    signature = enclosure.get(NS + "edSignature", "")
    decode_key(signature, (64,))
    release_notes = item.find(NS + "releaseNotesLink")
    require(release_notes is not None and release_notes.text == prefix + notes.name,
            "Appcast must include this release's signed notes")
    note_signature = release_notes.get(NS + "edSignature", "")
    decode_key(note_signature, (64,))
    require(release_notes.get(NS + "length") == str(notes.stat().st_size), "Release notes size mismatch")
    return signature, note_signature


def prepare(args):
    require(re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repository), "Invalid release repository")
    with (args.app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    validate_configuration(info, args.repository)
    version, build = info["CFBundleShortVersionString"], str(info["CFBundleVersion"])
    require(re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version) and re.fullmatch(r"[1-9][0-9]*", build), "Invalid release version")
    name = f"Slate-Terminal-{version}-{build}-arm64"
    archive = args.assets / (name + ".zip")
    require(archive.is_file() and not archive.is_symlink(), "Missing signed update archive")
    validate_notes(args.notes)
    require(not (args.assets / "appcast.xml").exists() and not (args.assets / (name + ".md")).exists(), "Update assets already exist")
    verify_tools(args.tools)
    secret = os.environ.get("SLATE_SPARKLE_PRIVATE_KEY", "").strip()
    require(secret, "Provision SLATE_SPARKLE_PRIVATE_KEY explicitly; Keychain fallback is disabled")
    decode_key(secret, (32, 96))
    with tempfile.TemporaryDirectory(prefix="slate-update-") as temporary:
        temporary = Path(temporary)
        shutil.copyfile(archive, temporary / archive.name)
        notes = temporary / (name + ".md")
        shutil.copyfile(args.notes, notes)
        prefix = f"https://github.com/{args.repository}/releases/download/v{version}/"
        run_tool(args.tools, "generate_appcast", ["--disable-signing-warning", "--download-url-prefix", prefix, "--release-notes-url-prefix", prefix,
                 "--maximum-deltas", "0", "--maximum-versions", "1", "-o", str(temporary / "appcast.xml"), str(temporary)], secret, temporary)
        require(notes.read_bytes() == args.notes.read_bytes(), "Signed release notes differ from reviewed notes")
        feed = temporary / "appcast.xml"
        signatures = inspect_appcast(feed, archive, notes, args.repository, version, build)
        run_tool(args.tools, "sign_update", ["--verify", str(feed)], secret, temporary)
        for path, signature in zip((archive, notes), signatures):
            run_tool(args.tools, "sign_update", ["--verify", str(path), signature], secret, temporary)
        # generate_appcast checks the signing public key against SUPublicEDKey in the archive.
        shutil.copyfile(notes, args.assets / notes.name)
        shutil.copyfile(feed, args.assets / feed.name)
    print("Prepared signed update assets for a draft release; nothing was published")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    bootstrap = commands.add_parser("bootstrap-tools")
    bootstrap.add_argument("--output", type=Path, required=True)
    validate = commands.add_parser("validate-config")
    validate.add_argument("--app", type=Path, required=True)
    public = commands.add_parser("validate-public-config")
    public.add_argument("--repository", required=True)
    notes = commands.add_parser("validate-notes")
    notes.add_argument("--notes", type=Path, required=True)
    prepare_parser = commands.add_parser("prepare")
    prepare_parser.add_argument("--tools", type=Path, required=True)
    prepare_parser.add_argument("--app", type=Path, required=True)
    prepare_parser.add_argument("--assets", type=Path, required=True)
    prepare_parser.add_argument("--notes", type=Path, required=True)
    prepare_parser.add_argument("--repository", required=True)
    args = parser.parse_args()
    if args.command == "bootstrap-tools":
        bootstrap_tools(args.output.resolve())
    elif args.command == "validate-public-config":
        validate_public_configuration(os.environ.get("SPARKLE_PUBLIC_ED_KEY", ""),
                                      os.environ.get("SPARKLE_FEED_URL", ""), args.repository)
    elif args.command == "validate-notes":
        validate_notes(args.notes)
    elif args.command == "validate-config":
        with (args.app / "Contents/Info.plist").open("rb") as stream:
            validate_configuration(plistlib.load(stream))
    else:
        args.tools, args.app, args.assets, args.notes = (p.resolve() for p in (args.tools, args.app, args.assets, args.notes))
        prepare(args)


if __name__ == "__main__":
    try:
        main()
    except UpdateError as error:
        print("Update preparation failed: " + str(error), file=sys.stderr)
        sys.exit(1)
    except (OSError, ValueError, KeyError, ET.ParseError, subprocess.SubprocessError, tarfile.TarError):
        # Exception messages from signing helpers or IO may contain secret inputs.
        print("Update preparation failed. Check explicit configuration, reviewed notes, pinned tools, and signing inputs; no assets were published.", file=sys.stderr)
        sys.exit(1)
