#!/usr/bin/env python3
"""Create corresponding source from the exact inputs of a clean release build."""

import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import posixpath
import re
import stat
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parent.parent
GHOSTTY_ROOT_DEPENDENCIES = {
    "translate_c", "libxev", "vaxis", "z2d", "zig_objc", "uucode", "zf",
    "dcimgui", "freetype", "highway", "libpng", "macos", "oniguruma", "opengl",
    "simdutf", "wuffs", "zlib", "glslang", "spirv_cross", "jetbrains_mono",
    "nerd_fonts_symbols_only", "apple_sdk", "iterm2_themes",
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def run(command, cwd=None):
    result = subprocess.run(command, cwd=cwd, capture_output=True)
    require(result.returncode == 0, "Source verification command failed: " + command[0])
    return result.stdout


def git(directory, *args):
    return run(["git", "-C", str(directory), *args])


def app_tree_sha256(app):
    digest = hashlib.sha256()
    for path in sorted(app.rglob("*"), key=lambda p: p.relative_to(app).as_posix()):
        name = path.relative_to(app).as_posix().encode()
        mode = str(stat.S_IMODE(path.lstat().st_mode)).encode()
        if path.is_symlink():
            kind, value = b"l", os.readlink(path).encode()
        elif path.is_file():
            kind, value = b"f", hashlib.sha256(path.read_bytes()).hexdigest().encode()
        else:
            require(path.is_dir(), "Unexpected special file in application")
            kind, value = b"d", b""
        digest.update(kind + b"\0" + name + b"\0" + mode + b"\0" + value + b"\n")
    return digest.hexdigest()


def verify_build(root, receipt_path, app, version=None, build_number=None):
    receipt = json.loads(receipt_path.read_text())
    require(receipt.get("source_dirty") is False, "Source archive requires a clean release build")
    require(not git(root, "status", "--porcelain", "--untracked-files=normal"),
            "Commit release changes before creating corresponding source")
    require(git(root, "rev-parse", "HEAD").decode().strip() == receipt["source_commit"],
            "Current commit does not match the compiled app")
    require(not app.is_symlink() and app.is_dir(), "Expected the original unsigned application directory")
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    require(info["CFBundleShortVersionString"] == receipt["version"] and
            str(info["CFBundleVersion"]) == str(receipt["build_number"]),
            "Application version does not match its build receipt")
    if version is not None:
        require(version == receipt["version"], "Requested version does not match the compiled app")
    if build_number is not None:
        require(str(build_number) == str(receipt["build_number"]), "Requested build number does not match the compiled app")
    require(re.fullmatch(r"\d+\.\d+\.\d+", receipt["version"]) and
            re.fullmatch(r"[1-9]\d*", str(receipt["build_number"])), "Invalid release version")
    inventory = json.loads((root / "licenses/manifest.json").read_text())
    require(receipt["ghostty_revision"] == inventory["ghostty_revision"], "Ghostty revision does not match the license inventory")
    require(app_tree_sha256(app) == receipt["app_tree_sha256"], "Application changed after the recorded build")
    return receipt


def safe_name(name):
    path = PurePosixPath(name)
    require(not path.is_absolute() and ".." not in path.parts and bool(path.parts), "Unsafe source archive path")
    require(not any(part in {".git", ".aws", ".ssh", ".DS_Store", "__pycache__"} for part in path.parts),
            "Private metadata or cache encountered in source input")
    require(path.name != ".env" and not path.name.endswith((".p12", ".p8", ".mobileprovision")),
            "Credential file encountered in source input")
    require(path.suffix not in {".o", ".a", ".dylib", ".so", ".exe", ".pyc"},
            "Compiled output encountered in source input")
    return str(path)


def safe_link(name, target):
    require(not PurePosixPath(target).is_absolute(), "Absolute source symlink is not portable")
    resolved = posixpath.normpath(posixpath.join(posixpath.dirname(name), target))
    require(resolved != ".." and not resolved.startswith("../"), "Source symlink escapes its component")


class SourceArchive:
    def __init__(self, tar, prefix):
        self.tar = tar
        self.prefix = prefix
        self.files = {}

    def add(self, name, data, mode=0o644, link=None):
        name = safe_name(name)
        require(name not in self.files, "Duplicate source archive member")
        member = tarfile.TarInfo(self.prefix + "/" + name)
        member.mtime = 0
        member.mode = mode
        member.uid = member.gid = 0
        member.uname = member.gname = ""
        if link is not None:
            member.type = tarfile.SYMTYPE
            member.linkname = link
            self.tar.addfile(member)
            self.files[name] = {"symlink": link, "mode": mode}
        else:
            member.size = len(data)
            self.tar.addfile(member, io.BytesIO(data))
            self.files[name] = {"sha256": hashlib.sha256(data).hexdigest(), "mode": mode}

    def git_tree(self, directory, prefix="", overrides=None):
        overrides = overrides or {}
        for entry in git(directory, "ls-tree", "-rz", "--full-tree", "HEAD").split(b"\0"):
            if not entry:
                continue
            metadata, raw_name = entry.split(b"\t", 1)
            mode, kind, object_id = metadata.decode().split()
            name = safe_name(raw_name.decode())
            require(kind == "blob", "Submodule source must be included explicitly")
            data = overrides.get(name)
            if data is None:
                data = git(directory, "cat-file", "blob", object_id)
            if mode == "120000":
                target = data.decode()
                safe_link(name, target)
                self.add(str(PurePosixPath(prefix) / name), b"", 0o777, target)
            else:
                self.add(str(PurePosixPath(prefix) / name), data, 0o755 if mode == "100755" else 0o644)

    def directory(self, directory, prefix):
        for path in sorted(directory.rglob("*")):
            name = safe_name(path.relative_to(directory).as_posix())
            archive_name = str(PurePosixPath(prefix) / name)
            if path.is_symlink():
                target = os.readlink(path)
                safe_link(name, target)
                self.add(archive_name, b"", 0o777, target)
            elif path.is_file():
                self.add(archive_name, path.read_bytes(), 0o755 if path.stat().st_mode & 0o111 else 0o644)
            else:
                require(path.is_dir(), "Unexpected special file in source package")


def verify_source_archive(path, receipt):
    prefix = f"Slate-Terminal-{receipt['version']}-{receipt['build_number']}-source/"
    files = {}
    manifest = None
    with tarfile.open(path, mode="r|gz") as archive:
        for member in archive:
            require(member.name.startswith(prefix), "Unexpected source archive prefix")
            name = safe_name(member.name[len(prefix):])
            require(name not in files, "Duplicate source archive member")
            if member.issym():
                safe_link(name, member.linkname)
                files[name] = {"symlink": member.linkname, "mode": member.mode}
            else:
                require(member.isfile(), "Unexpected source archive member type")
                stream = archive.extractfile(member)
                if name == "SOURCE-MANIFEST.json":
                    require(manifest is None and member.size <= 16 * 1024 * 1024,
                            "Invalid source archive manifest")
                    manifest = json.load(stream)
                    continue
                digest = hashlib.sha256()
                for block in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(block)
                files[name] = {"sha256": digest.hexdigest(), "mode": member.mode}
    require(manifest is not None, "Missing source archive manifest")
    for key in ("source_commit", "version", "build_number", "app_tree_sha256", "ghostty_revision"):
        require(manifest.get(key) == receipt[key], "Source archive does not match build receipt: " + key)
    require(manifest.get("files") == files, "Source archive files do not match its manifest")
    return manifest


def dependencies(path):
    if not path.exists():
        return {}
    result = {}
    for name, body in re.findall(r"\.([A-Za-z0-9_]+)\s*=\s*\.\{([^{}]*)\}", path.read_text()):
        fields = dict(re.findall(r'\.(url|hash|path)\s*=\s*"([^"]+)"', body))
        if "url" in fields or "path" in fields:
            require(name not in result, "Duplicate Zig dependency declaration")
            require("path" in fields or "hash" in fields, "Unpinned Zig dependency")
            result[name] = fields
    return result


def source_packages(ghostty):
    root_dependencies = dependencies(ghostty / "build.zig.zon")
    require(GHOSTTY_ROOT_DEPENDENCIES <= set(root_dependencies), "Ghostty macOS dependency graph changed")
    pending = [(ghostty, name, root_dependencies[name]) for name in sorted(GHOSTTY_ROOT_DEPENDENCIES)]
    visited_local = set()
    packages = {}
    while pending:
        parent, name, entry = pending.pop()
        if "path" in entry:
            directory = (parent / entry["path"]).resolve()
            require(directory.is_relative_to(ghostty.resolve()), "Local Zig dependency escapes Ghostty source")
            if directory in visited_local:
                continue
            visited_local.add(directory)
        else:
            package_hash = entry["hash"]
            require(re.fullmatch(r"[A-Za-z0-9_.-]+", package_hash), "Invalid Zig package hash")
            if package_hash in packages:
                continue
            directory = ghostty / "zig-pkg" / package_hash
            require(directory.is_dir() and not directory.is_symlink(), "Missing pinned Zig source package: " + name)
            packages[package_hash] = {"name": name, "url": entry["url"]}
        for child, child_entry in dependencies(directory / "build.zig.zon").items():
            # Ghostty supplies its own Unicode module and disables zf's TUI.
            if (name, child) in {("vaxis", "uucode"), ("zf", "vaxis")}:
                continue
            pending.append((directory, child, child_entry))
    return dict(sorted(packages.items()))


def verify_git_source(directory, revision):
    require(git(directory, "rev-parse", "HEAD").decode().strip() == revision, "Dependency source revision mismatch")
    require(not git(directory, "status", "--porcelain", "--untracked-files=no"), "Dependency source has tracked changes")


def shell_pin(root, variable):
    text = (root / "scripts/build-ghostty.sh").read_text()
    match = re.search(r"^" + variable + r"=([A-Za-z0-9.]+)$", text, re.MULTILINE)
    require(match is not None, "Missing bootstrap pin: " + variable)
    return match.group(1)


def verified_ghostty(root, receipt):
    ghostty = root / ".build/bootstrap/ghostty"
    require(git(ghostty, "rev-parse", "HEAD").decode().strip() == receipt["ghostty_revision"], "Ghostty source revision mismatch")
    require(not git(ghostty, "diff", "--cached", "--name-only"), "Ghostty has staged source changes")
    changes = git(ghostty, "diff", "--name-only").decode().splitlines()
    require(changes == ["src/build/SharedDeps.zig"], "Ghostty must contain only the approved libintl patch")
    data = (ghostty / "src/build/SharedDeps.zig").read_bytes()
    require(hashlib.sha256(data).hexdigest() == shell_pin(root, "patched_sha"), "Ghostty patch content mismatch")
    patch = (root / "patches/ghostty-optional-libintl.patch").read_bytes()
    require(hashlib.sha256(patch).hexdigest() == shell_pin(root, "patch_sha"), "Ghostty patch checksum mismatch")
    return ghostty, {"src/build/SharedDeps.zig": data}


PREPARE_REBUILD = r'''#!/usr/bin/env python3
"""Verify the source archive, then select its local Swift and Ghostty sources."""
import hashlib
import json
import os
from pathlib import Path
import re
root = Path(__file__).resolve().parent
manifest = json.loads((root / "SOURCE-MANIFEST.json").read_text())
for name, entry in manifest["files"].items():
    path = root / name
    if "symlink" in entry:
        assert path.is_symlink() and os.readlink(path) == entry["symlink"], name
    else:
        assert hashlib.sha256(path.read_bytes()).hexdigest() == entry["sha256"], name
package = root / "Package.swift"
text = package.read_text()
for pin in manifest["swift_packages"]:
    pattern = r'\.package\(url: "' + re.escape(pin["url"]) + r'", exact: "[^"]+"\)'
    text, count = re.subn(pattern, '.package(path: "vendor/swift/' + pin["identity"] + '")', text)
    assert count == 1, pin["identity"]
package.write_text(text)
link = root / ".build/bootstrap/ghostty"
link.parent.mkdir(parents=True, exist_ok=True)
link.symlink_to("../../vendor/ghostty", target_is_directory=True)
print("Verified sources and selected local dependencies. Follow REBUILD.md next.")
'''


def rebuild_instructions(receipt, zig_version):
    return f'''# Rebuilding this source release

This archive contains the clean Slate source commit `{receipt['source_commit']}`, patched Ghostty, all selected Zig package sources, the resolved Swift package sources, and relevant Zig runtime library sources. `SOURCE-MANIFEST.json` records source hashes and revisions. No signing credentials, private Git metadata, or compiled caches are included.

Use an Apple Silicon Mac with the same Xcode/macOS SDK generation as the release (currently SDK 27 or later). Install Zig {zig_version}; the exact download URL and checksum are pinned in `scripts/build-ghostty.sh`. Xcode, Apple SDKs, and the Zig compiler are build tools, not included binaries. Compiler runtime source used by Zig is included under `vendor/zig-runtime-source`.

From a fresh extraction run `python3 prepare-rebuild.py`. It checks archived file hashes, then changes only `Package.swift` to use the bundled local Swift sources and connects `.build/bootstrap/ghostty` to the bundled Ghostty source. Keep an untouched extraction if you want the original release files for comparison. This preparation step is intentionally run once per extraction.

The bundled Ghostty `zig-pkg/` directory is Zig 0.16's source-package location. Leave these hash-named directories together: they include the C libraries, build-time translation dependencies, fonts, and themes. Zig can use them without fetching the corresponding package archives. Set `ZIG` below to the absolute path of the installed Zig executable:

```sh
ZIG=/absolute/path/to/zig
root="$PWD"
export ZIG_GLOBAL_CACHE_DIR="$root/.build/rebuild-zig-cache"
cd .build/bootstrap/ghostty
"$ZIG" build -j4 -Doptimize=ReleaseFast -Demit-xcframework=true -Demit-macos-app=false -Dxcframework-target=native -Di18n=false -Dsentry=false -Dversion-string=1.3.2-dev
cd "$root"
xcodebuild -project slate-term.xcodeproj -scheme SlateTermApp -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath .derived-rebuild ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO MARKETING_VERSION={receipt['version']} CURRENT_PROJECT_VERSION={receipt['build_number']} build
```

The unsigned application is `.derived-rebuild/Build/Products/Release/Slate Terminal.app`. Xcode's build phase includes the two CLI helpers and Ghostty resources. The local Swift references avoid remote package resolution. This route deliberately bypasses the release scripts' Git/clean-build receipts because source archives contain no private Git repository metadata. It reproduces the source inputs and build behavior; signing, timestamps, absolute debug paths, and the explicit Ghostty version label prevent a promise of identical binary bytes.

Before redistributing your build, copy `licenses/`, `THIRD_PARTY_NOTICES.md`, `COPYING.md`, and `LICENSE` into the app's `Contents/Resources/ThirdPartyLicenses/` (name the project license `PROJECT-LICENSE.txt`), retain source access, and sign your own build if desired. Modified builds remain subject to their applicable licenses. See `COPYING.md` and `THIRD_PARTY_NOTICES.md`.
'''.encode()


def create_source(root, output, receipt, swift_sources):
    inventory = json.loads((root / "licenses/manifest.json").read_text())
    ghostty, overrides = verified_ghostty(root, receipt)
    packages = source_packages(ghostty)
    zig_version = inventory["zig_version"]
    zig_directory = root / (".tools/zig-aarch64-macos-" + zig_version)
    zig = zig_directory / "zig"
    require(run([str(zig), "version"]).decode().strip() == zig_version, "Unexpected Zig version")
    pins = json.loads((root / "Package.resolved").read_text())["pins"]
    for pin in pins:
        verify_git_source(swift_sources / pin["identity"], pin["state"]["revision"])
    output.mkdir(parents=True, exist_ok=True)
    name = f"Slate-Terminal-{receipt['version']}-{receipt['build_number']}-source"
    destination = output / (name + ".tar.gz")
    require(not destination.exists(), "Source archive already exists")
    manifest = {"schema": 1, "source_commit": receipt["source_commit"], "version": receipt["version"],
                "build_number": receipt["build_number"], "app_tree_sha256": receipt["app_tree_sha256"],
                "ghostty_revision": receipt["ghostty_revision"], "zig_version": zig_version,
                "zig_packages": packages,
                "swift_packages": [{"identity": pin["identity"], "revision": pin["state"]["revision"],
                                    "url": pin["location"]} for pin in pins]}
    temporary = destination.with_suffix(".tmp")
    require(not temporary.exists(), "Temporary source archive already exists")
    try:
        with temporary.open("xb") as raw, gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode="w|", format=tarfile.PAX_FORMAT) as tar:
                archive = SourceArchive(tar, name)
                archive.git_tree(root)
                archive.git_tree(ghostty, "vendor/ghostty", overrides)
                for pin in pins:
                    archive.git_tree(swift_sources / pin["identity"], "vendor/swift/" + pin["identity"])
                for package_hash in packages:
                    with tempfile.TemporaryDirectory(prefix="slate-source-verify-") as scratch:
                        scratch = Path(scratch)
                        (scratch / "build.zig").touch()
                        (scratch / "cache/tmp").mkdir(parents=True)
                        # Zig can skip its redundant compressed cache after verifying sources.
                        (scratch / "cache/p").touch()
                        actual = run([str(zig), "fetch", "--global-cache-dir", str(scratch / "cache"),
                                      str(ghostty / "zig-pkg" / package_hash)], cwd=scratch).decode().strip()
                        require(actual == package_hash, "Zig source package content mismatch: " + packages[package_hash]["name"])
                        verified = scratch / "zig-pkg" / package_hash
                        require(verified.is_dir(), "Zig did not produce a verified source directory")
                        archive.directory(verified, "vendor/ghostty/zig-pkg/" + package_hash)
                for relative in ("lib/std", "lib/compiler_rt", "lib/libcxx", "lib/libcxxabi", "lib/libunwind"):
                    directory = zig_directory / relative
                    require(directory.is_dir(), "Missing Zig runtime source directory")
                    archive.directory(directory, "vendor/zig-runtime-source/" + relative)
                for relative in ("LICENSE", "lib/compiler_rt.zig", "lib/ubsan_rt.zig"):
                    archive.add("vendor/zig-runtime-source/" + relative, (zig_directory / relative).read_bytes())
                archive.add("prepare-rebuild.py", PREPARE_REBUILD.encode(), 0o755)
                archive.add("REBUILD.md", rebuild_instructions(receipt, zig_version))
                manifest["files"] = dict(archive.files)
                archive.add("SOURCE-MANIFEST.json", (json.dumps(manifest, sort_keys=True, indent=2) + "\n").encode())
        require(not git(root, "status", "--porcelain", "--untracked-files=normal") and
                git(root, "rev-parse", "HEAD").decode().strip() == receipt["source_commit"],
                "Project source changed while the archive was generated")
        temporary.rename(destination)
    finally:
        if temporary.exists():
            temporary.unlink()
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "artifacts/release/assets")
    parser.add_argument("--version")
    parser.add_argument("--build-number")
    parser.add_argument("--build-receipt", type=Path)
    parser.add_argument("--app", type=Path)
    parser.add_argument("--source-archive", type=Path, help="Also validate source archive contents and build association")
    parser.add_argument("--swift-sources", type=Path, default=ROOT / ".build/xcode-packages/checkouts")
    parser.add_argument("--verify-build", action="store_true", help="Validate the original unsigned build without writing an archive")
    args = parser.parse_args()
    receipt_path = args.build_receipt or args.output.parent / "build-source.json"
    app = args.app or args.output.parent / "Slate Terminal.app"
    receipt = verify_build(ROOT, receipt_path, app, args.version, args.build_number)
    if args.source_archive:
        verify_source_archive(args.source_archive, receipt)
    if args.verify_build:
        print("Clean release build verified")
        return
    require(args.version is not None and args.build_number is not None, "Supply --version and --build-number for a source archive")
    destination = create_source(ROOT, args.output, receipt, args.swift_sources)
    print(str(destination))
    print(hashlib.sha256(destination.read_bytes()).hexdigest() + "  " + destination.name)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, tarfile.TarError) as error:
        print("Source release failed: " + str(error), file=sys.stderr)
        sys.exit(1)
