#!/usr/bin/env python3
"""Prepare a scanned standalone public repository without rewriting the source."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import urllib.request


FILTER_COMMIT = "6f79afc8c90c592a3052e6cc53c2ca8907515bca"
FILTER_SHA256 = "67447413e273fc76809289111748870b6f6072f08b17efe94863a92d810b7d94"
FILTER_URL = f"https://raw.githubusercontent.com/newren/git-filter-repo/{FILTER_COMMIT}/git-filter-repo"
SPEC = importlib.util.spec_from_file_location("public_source_scanner", Path(__file__).with_name("security-scan.py"))
SCANNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SCANNER)


class ExportError(Exception):
    """An error safe to print without subprocess diagnostics or source contents."""


def environment():
    result = dict(os.environ)
    # Environment overrides must not redirect Git writes into the source repository.
    for name in list(result):
        if name.startswith("GIT_"):
            result.pop(name)
    result["GIT_OPTIONAL_LOCKS"] = "0"
    result["GIT_CONFIG_GLOBAL"] = os.devnull
    result["GIT_CONFIG_NOSYSTEM"] = "1"
    return result


def execute(command, *, cwd=None, input=None, timeout=300, env=None, allow_failure=False):
    try:
        result = subprocess.run(command, cwd=cwd, input=input, env=env or environment(),
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        raise ExportError("Export command could not complete; diagnostic content was suppressed.") from None
    if result.returncode and not allow_failure:
        raise ExportError("Export command failed; diagnostic content was suppressed. The output is not ready to publish.")
    return result


def git(root, *arguments, **options):
    return execute(["git", "-c", "core.hooksPath=" + os.devnull, "-c", "commit.gpgsign=false",
                    "-C", str(root), *arguments], **options).stdout


def source_root(path):
    return Path(os.fsdecode(git(path, "rev-parse", "--show-toplevel")).strip()).resolve()


def validate_output(source, output):
    if output.exists() or output.is_symlink():
        raise ExportError("The export destination already exists; choose a new directory.")
    output = output.expanduser().resolve()
    if output.exists() or output.is_symlink():
        raise ExportError("The export destination already exists; choose a new directory.")
    roots = [source]
    common = Path(os.fsdecode(git(source, "rev-parse", "--git-common-dir")).strip())
    roots.append((source / common).resolve() if not common.is_absolute() else common.resolve())
    for entry in git(source, "worktree", "list", "--porcelain", "-z").split(b"\0"):
        if entry.startswith(b"worktree "):
            roots.append(Path(os.fsdecode(entry[9:])).resolve())
    if any(output == root or root in output.parents for root in roots):
        raise ExportError("The export must be outside the source, its Git directory, and every linked worktree.")
    return output


def ignored_paths(source, paths):
    result = execute(["git", "-C", str(source), "check-ignore", "--no-index", "-z", "--stdin"],
                     input=b"\0".join(os.fsencode(path) for path in paths) + b"\0", allow_failure=True)
    if result.returncode not in (0, 1):
        raise ExportError("Could not check source ignore rules.")
    return set(os.fsdecode(path) for path in result.stdout.split(b"\0") if path)


def snapshot(source, destination=None):
    """Hash the selected source state and optionally copy it without following links."""
    head = git(source, "rev-parse", "--verify", "HEAD^{commit}").decode().strip()
    if git(source, "rev-parse", "--is-shallow-repository").strip() == b"true":
        raise ExportError("A public history export requires complete source history.")
    index_path = Path(os.fsdecode(git(source, "rev-parse", "--git-path", "index")).strip())
    if not index_path.is_absolute():
        index_path = source / index_path
    status = git(source, "status", "--porcelain=v1", "-z", "--untracked-files=all")
    names = sorted(set(os.fsdecode(p) for p in git(source, "ls-files", "-z", "--cached", "--others", "--exclude-standard").split(b"\0") if p))
    ignored = ignored_paths(source, names)
    records = []
    for name in names:
        relative = Path(name)
        if relative.is_absolute() or ".." in relative.parts:
            raise ExportError("The source contains an unsafe file path.")
        path = source / relative
        if any((source / parent).is_symlink() for parent in relative.parents if str(parent) != "."):
            raise ExportError("A tracked path traverses a symlink; inspect the source before exporting.")
        if not path.exists() and not path.is_symlink():
            continue
        if "xcuserdata" in relative.parts:
            continue
        if SCANNER.private_filename(name):
            raise ExportError("A publishable source filename may contain private credentials; remove it before exporting.")
        if name in ignored:
            continue
        metadata = path.lstat()
        if stat.S_ISLNK(metadata.st_mode):
            contents = os.fsencode(os.readlink(path))
            mode = "symlink"
        elif stat.S_ISREG(metadata.st_mode):
            contents = path.read_bytes()
            mode = "executable" if metadata.st_mode & 0o111 else "file"
        else:
            raise ExportError("Submodules, nested repositories, and special files need a separate publication audit.")
        records.append((name, mode, hashlib.sha256(contents).hexdigest()))
        if destination is not None:
            target = destination / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            if mode == "symlink":
                target.symlink_to(os.fsdecode(contents))
            else:
                target.write_bytes(contents)
                target.chmod(0o755 if mode == "executable" else 0o644)
    state = {"head": head, "index": hashlib.sha256(index_path.read_bytes()).hexdigest(),
             "status": hashlib.sha256(status).hexdigest(), "files": records}
    state["fingerprint"] = hashlib.sha256(json.dumps(state, sort_keys=True).encode()).hexdigest()
    state["dirty"] = bool(status)
    return state


def load_filter_tool(path=None):
    try:
        if path is not None:
            contents = path.read_bytes()
        else:
            with urllib.request.urlopen(FILTER_URL, timeout=60) as response:
                contents = response.read()
    except Exception:
        raise ExportError("Could not load the pinned history filter.") from None
    if hashlib.sha256(contents).hexdigest() != FILTER_SHA256:
        raise ExportError("History filter checksum mismatch; nothing was executed.")
    return contents


def author(source):
    fields = git(source, "show", "-s", "--format=%an%x00%ae", "HEAD").rstrip(b"\n").split(b"\0")
    if len(fields) != 2 or any(not field or b"\n" in field for field in fields):
        raise ExportError("The source HEAD has no usable author identity.")
    return [os.fsdecode(field) for field in fields]


def verify_history(output, replacements):
    if git(output, "remote").strip():
        raise ExportError("The export unexpectedly retained a remote.")
    refs = git(output, "for-each-ref", "--format=%(refname)").splitlines()
    if refs != [b"refs/heads/main"]:
        raise ExportError("The export must contain only its main branch.")
    if git(output, "fsck", "--full", "--no-reflogs", "--unreachable").strip():
        raise ExportError("Unreachable Git objects remain in the export; it is not ready to publish.")
    for revision in git(output, "rev-list", "HEAD").splitlines():
        for name in git(output, "ls-tree", "-r", "--name-only", "-z", revision.decode()).split(b"\0"):
            if name and SCANNER.private_filename(os.fsdecode(name)):
                raise ExportError("A private filename remains in exported history; the export is not ready to publish.")
    needles = [old.encode() for old, _new in replacements]
    if needles:
        for oid, kind in SCANNER.object_inventory(output, None):
            payload = git(output, "cat-file", kind, oid)
            if any(needle in payload for needle in needles):
                raise ExportError("A requested private-text replacement remains in exported history.")


def scan_export(output):
    script = output / "scripts/security-scan.py"
    if not script.is_file() or script.is_symlink():
        raise ExportError("The exported repository must contain the security scanner.")
    execute([sys.executable, str(script)], cwd=output, timeout=1800)
    try:
        report = json.loads((output / "artifacts/security/summary.json").read_text())
        valid = (report["passed"] is True and report["history_scanned"] is True
                 and report["revision"] == git(output, "rev-parse", "HEAD").decode().strip()
                 and report["ref"] == "--all")
    except (OSError, KeyError, ValueError):
        valid = False
    if not valid:
        raise ExportError("The full exported-history secret scan did not produce a valid passing receipt.")


def prepare(source, output, *, include_working_tree=False, replacements=(), filter_tool=None):
    source = source_root(source)
    output = validate_output(source, output)
    for old, new in replacements:
        if not old or not new or old == new or any(c in old + new for c in "\r\n\x00") or "==>" in old:
            raise ExportError("Text replacements must contain distinct, nonempty single-line values.")
    with tempfile.TemporaryDirectory(prefix="slate-public-source-") as temporary:
        temporary = Path(temporary)
        source_snapshot = temporary / "snapshot"
        source_snapshot.mkdir()
        initial = snapshot(source, source_snapshot)
        if initial["dirty"] and not include_working_tree:
            raise ExportError("The source has uncommitted files; use --include-working-tree to explicitly export them.")
        if snapshot(source)["fingerprint"] != initial["fingerprint"]:
            raise ExportError("The source changed during its snapshot; retry after edits finish.")
        tool = temporary / "git-filter-repo"
        tool.write_bytes(load_filter_tool(filter_tool))
        replacement_file = temporary / "replacements"
        replacement_file.write_text("".join(f"literal:{old}==>{new}\n" for old, new in replacements))
        output.parent.mkdir(parents=True, exist_ok=True)
        output.mkdir(mode=0o700)
        execute(["git", "-c", "core.hooksPath=" + os.devnull, "clone", "--no-local", "--single-branch",
                 "--no-tags", "--no-checkout", str(source), str(output)])
        # The new repository stays private on disk, including after a failed scan.
        output.chmod(0o700)
        if git(output, "rev-parse", "HEAD").decode().strip() != initial["head"]:
            raise ExportError("Source HEAD changed while cloning; the export is not ready to publish.")
        git(output, "remote", "remove", "origin")
        # A deleted tracking branch can leave a dangling symbolic remote HEAD.
        git(output, "update-ref", "--no-deref", "-d", "refs/remotes/origin/HEAD")
        git(output, "symbolic-ref", "HEAD", "refs/heads/main")
        git(output, "update-ref", "refs/heads/main", initial["head"])
        for ref in git(output, "for-each-ref", "--format=%(refname)").splitlines():
            if ref != b"refs/heads/main":
                git(output, "update-ref", "--no-deref", "-d", ref.decode())
        git(output, "read-tree", "HEAD")
        for entry in source_snapshot.iterdir():
            target = output / entry.name
            if entry.is_symlink():
                target.symlink_to(os.readlink(entry))
            elif entry.is_dir():
                shutil.copytree(entry, target, symlinks=True)
            else:
                shutil.copy2(entry, target)
        git(output, "add", "--all")
        if git(output, "diff", "--cached", "--name-only"):
            name, email = author(source)
            git(output, "-c", "user.name=" + name, "-c", "user.email=" + email,
                "commit", "-m", "Prepare source for public release")
        # This force applies only to the newly created standalone repository.
        command = [sys.executable, str(tool), "--force", "--path-regex", r"(^|/)xcuserdata(/|$)", "--invert-paths"]
        if replacements:
            command += ["--replace-text", str(replacement_file), "--replace-message", str(replacement_file)]
        execute(command, cwd=output, timeout=1800)
        verify_history(output, replacements)
        if snapshot(source)["fingerprint"] != initial["fingerprint"]:
            raise ExportError("The source changed during export; the output is not ready to publish.")
        scan_export(output)
        if snapshot(source)["fingerprint"] != initial["fingerprint"]:
            raise ExportError("The source changed during verification; the output is not ready to publish.")
        receipt = {"source_head": initial["head"], "source_fingerprint": initial["fingerprint"],
                   "export_head": git(output, "rev-parse", "HEAD").decode().strip(),
                   "included_working_tree": include_working_tree, "history_filter_commit": FILTER_COMMIT,
                   "secret_scan_passed": True}
        (output / ".git/public-source-export.json").write_text(json.dumps(receipt, indent=2) + "\n")
    return output


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="New standalone destination outside every source worktree")
    parser.add_argument("--source", type=Path, default=Path.cwd())
    parser.add_argument("--include-working-tree", action="store_true", help="Include tracked changes and nonignored new files")
    parser.add_argument("--replace-text", nargs=2, action="append", default=[], metavar=("OLD", "NEW"))
    parser.add_argument("--filter-repo", type=Path, help="Existing official pinned filter script, verified by SHA-256")
    args = parser.parse_args(argv)
    try:
        output = prepare(args.source, args.output, include_working_tree=args.include_working_tree,
                         replacements=args.replace_text, filter_tool=args.filter_repo)
    except (ExportError, SCANNER.ScanError, OSError, ValueError) as error:
        if isinstance(error, ExportError):
            print(str(error), file=sys.stderr)
        print("Public-source export failed. Any created output remains private and must not be published.", file=sys.stderr)
        return 1
    print(f"Prepared and scanned standalone public source: {output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
