#!/usr/bin/env python3
"""Run a release command with credentials scoped to one temporary keychain."""

from __future__ import annotations

import argparse
import base64
import binascii
import contextlib
import fcntl
import os
from pathlib import Path
import re
import secrets
import signal
import stat
import subprocess
import sys
import tempfile
import uuid


INPUTS = (
    "SLATE_RELEASE_CERTIFICATE_P12_BASE64",
    "SLATE_RELEASE_CERTIFICATE_PASSWORD",
    "SLATE_NOTARY_KEY_P8_BASE64",
    "SLATE_NOTARY_KEY_ID",
    "SLATE_NOTARY_ISSUER_ID",
)
PROFILE = "slate-release"
SECURITY = "/usr/bin/security"
XCRUN = "/usr/bin/xcrun"


class CredentialError(Exception):
    """A safe error message that contains no credential or subprocess output."""


class Interrupted(Exception):
    def __init__(self, signum):
        self.signum = signum


@contextlib.contextmanager
def interrupt_handlers():
    def interrupt(signum, _frame):
        raise Interrupted(signum)

    previous = {}
    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        previous[signum] = signal.signal(signum, interrupt)
    try:
        yield
    finally:
        for signum, handler in previous.items():
            signal.signal(signum, handler)


@contextlib.contextmanager
def defer_interrupts():
    previous = {}
    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        previous[signum] = signal.signal(signum, signal.SIG_IGN)
    try:
        yield
    finally:
        for signum, handler in previous.items():
            signal.signal(signum, handler)


def run(command, *, env=None, visible=False, timeout=60, label="Credential command"):
    """Keep credential tools quiet, and terminate owned processes before cleanup."""
    try:
        process = subprocess.Popen(
            command,
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=None if visible else subprocess.PIPE,
            stderr=None if visible else subprocess.PIPE,
            start_new_session=True,
        )
    except OSError:
        raise CredentialError(f"{label} could not start.") from None
    termination_signal = signal.SIGTERM
    try:
        stdout, _stderr = process.communicate(timeout=timeout)
        if not visible and process.returncode:
            raise CredentialError(f"{label} failed (exit {process.returncode}); output suppressed to protect credentials.")
        return process.returncode, stdout or b""
    except Interrupted as interrupted:
        termination_signal = interrupted.signum
        raise
    except subprocess.TimeoutExpired:
        raise CredentialError(f"{label} timed out; output suppressed to protect credentials.") from None
    finally:
        if process.poll() is None:
            with defer_interrupts():
                try:
                    os.killpg(process.pid, termination_signal)
                except ProcessLookupError:
                    pass
                try:
                    process.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.communicate()


@contextlib.contextmanager
def keychain_bookkeeping_lock():
    # Apple's create/delete commands update shared preferences; serialize just those updates.
    path = Path("/tmp") / f"slate-release-keychains-{os.getuid()}.lock"
    descriptor = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        metadata = os.fstat(descriptor)
        if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid()
                or stat.S_IMODE(metadata.st_mode) != 0o600):
            raise CredentialError("The release keychain lock must be a private file owned by you.")
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        os.close(descriptor)


def clean_environment(environment):
    return {
        name: value for name, value in environment.items()
        if name not in INPUTS and not name.startswith("OP_")
    }


def config_path(environment):
    root = Path(environment.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))).expanduser()
    if not root.is_absolute():
        raise CredentialError("XDG_CONFIG_HOME must be an absolute path.")
    return root / "slate-term" / "release.env.op"


def validate_env_file(path):
    """Only allow private reference files outside every Git checkout."""
    path = path.expanduser().absolute()
    try:
        metadata = path.lstat()
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid():
            raise CredentialError("The credential reference file must be a regular file owned by you.")
        if stat.S_IMODE(metadata.st_mode) not in (0o400, 0o600):
            raise CredentialError("The credential reference file must have mode 600 or 400.")
        path = path.resolve(strict=True)
        parent_metadata = path.parent.stat()
        if parent_metadata.st_uid != os.getuid() or parent_metadata.st_mode & 0o022:
            raise CredentialError("The credential reference directory must be owned by you and not writable by other users.")
        # Ancestor checks also cover linked worktrees, submodules, and other repositories.
        for ancestor in path.parents:
            if (ancestor / ".git").exists():
                raise CredentialError("Keep the credential reference file outside all Git checkouts.")
        result = subprocess.run(
            ["git", "-C", str(Path(__file__).resolve().parent.parent), "worktree", "list", "--porcelain", "-z"],
            check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=clean_environment(os.environ), timeout=10,
        )
        for entry in result.stdout.split(b"\0"):
            if entry.startswith(b"worktree "):
                root = Path(os.fsdecode(entry[9:])).resolve()
                if path == root or root in path.parents:
                    raise CredentialError("Keep the credential reference file outside all Git worktrees.")
        entries = {}
        for line in path.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            name, separator, reference = line.partition("=")
            reference = reference.strip()
            if len(reference) > 1 and reference[0] == reference[-1] and reference[0] in "\"'":
                reference = reference[1:-1]
            if (not separator or name not in INPUTS or name in entries
                    or not re.fullmatch(r"op://[^\r\n\x00]+/[^/]+/[^/]+", reference)):
                raise CredentialError("Use only the five expected release variables with op:// references in the credential file.")
            entries[name] = reference
        if set(entries) != set(INPUTS):
            raise CredentialError("The credential reference file must define all five release variables.")
    except (OSError, UnicodeError, subprocess.SubprocessError):
        raise CredentialError("Cannot safely read the credential reference file or enumerate Git worktrees.") from None
    return path


def decoded(environment, name):
    try:
        value = base64.b64decode(environment[name], validate=True)
    except (ValueError, binascii.Error):
        raise CredentialError(f"{name} must contain single-line base64.") from None
    if not value or len(value) > 1024 * 1024:
        raise CredentialError(f"{name} must decode to between 1 byte and 1 MiB.")
    return value


def private_file(path, contents):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(contents)


def with_credentials(command, environment, *, runner=run):
    for name in INPUTS:
        if name not in environment or (not environment[name] and name != INPUTS[1]):
            raise CredentialError(f"Missing release input: {name}.")
    certificate = decoded(environment, INPUTS[0])
    key = decoded(environment, INPUTS[2])
    if not key.startswith(b"-----BEGIN PRIVATE KEY-----\n") or not key.rstrip().endswith(b"-----END PRIVATE KEY-----"):
        raise CredentialError("The notarization key must be a PEM PKCS#8 private key.")
    key_id = environment[INPUTS[3]]
    if not re.fullmatch(r"[A-Za-z0-9]{10,}", key_id):
        raise CredentialError("The notarization key ID must contain at least ten letters or digits.")
    try:
        issuer = str(uuid.UUID(environment[INPUTS[4]]))
    except ValueError:
        raise CredentialError("The notarization issuer ID must be a UUID for a team API key.") from None
    child_env = clean_environment(environment)
    password = secrets.token_urlsafe(32)
    with tempfile.TemporaryDirectory(prefix="slate-release-") as temporary:
        directory = Path(temporary)
        directory.chmod(0o700)
        keychain = str(directory / "release.keychain-db")
        p12 = directory / "certificate.p12"
        p8 = directory / "notary.p8"
        private_file(p12, certificate)
        private_file(p8, key)
        try:
            # macOS maintains the owned entry; never replace a shared search list or default.
            with keychain_bookkeeping_lock():
                runner([SECURITY, "create-keychain", "-p", password, keychain], env=child_env, label="Create temporary keychain")
            runner([SECURITY, "set-keychain-settings", "-lut", "21600", keychain], env=child_env, label="Configure temporary keychain")
            runner([SECURITY, "unlock-keychain", "-p", password, keychain], env=child_env, label="Unlock temporary keychain")
            runner([SECURITY, "import", str(p12), "-k", keychain, "-P", environment[INPUTS[1]],
                    "-f", "pkcs12", "-x", "-T", "/usr/bin/codesign"], env=child_env, label="Import signing certificate")
            runner([SECURITY, "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", password, keychain],
                   env=child_env, label="Authorize signing tools")
            _, identities = runner([SECURITY, "find-identity", "-v", "-p", "codesigning", keychain],
                                   env=child_env, label="Find Developer ID identity")
            matches = re.findall(rb'\b([A-Fa-f0-9]{40}) "Developer ID Application: [^"\r\n]+"', identities)
            if len(matches) != 1:
                raise CredentialError("The release certificate must contain exactly one valid Developer ID Application identity.")
            runner([XCRUN, "notarytool", "store-credentials", PROFILE, "--keychain", keychain,
                    "--key", str(p8), "--key-id", key_id, "--issuer", issuer, "--no-validate"],
                   env=child_env, label="Store temporary notarization credentials")
            p12.unlink()
            p8.unlink()
            child_env.update({
                "SLATE_SIGNING_IDENTITY": matches[0].decode("ascii"),
                "SLATE_SIGNING_KEYCHAIN": keychain,
                "SLATE_NOTARY_PROFILE": PROFILE,
                "SLATE_NOTARY_KEYCHAIN": keychain,
            })
            return runner(command, env=child_env, visible=True, timeout=None, label="Release command")[0]
        finally:
            # Cleanup targets only this invocation, including partially failed imports.
            with defer_interrupts():
                try:
                    with keychain_bookkeeping_lock():
                        runner([SECURITY, "delete-keychain", keychain], env=child_env, label="Delete temporary keychain")
                except CredentialError:
                    raise CredentialError("macOS keychain cleanup failed; temporary files were removed, but its search-list entry may remain.") from None


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--env-file", type=Path, help="External mode-600 file containing only 1Password references")
    source.add_argument("--from-environment", action="store_true", help="Use inputs already injected by CI")
    parser.add_argument("command", nargs=argparse.REMAINDER, help="Command after --; no shell evaluation")
    args = parser.parse_args(argv)
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("provide a release command after --")
    try:
        with interrupt_handlers():
            if not args.from_environment:
                path = validate_env_file(args.env_file or config_path(os.environ))
                # op resolves references in memory and retains its default log masking.
                wrapped = ["op", "run", "--env-file", str(path), "--", sys.executable,
                           str(Path(__file__).resolve()), "--from-environment", "--", *command]
                op_environment = {name: value for name, value in os.environ.items() if name not in INPUTS}
                return run(wrapped, env=op_environment, visible=True, timeout=None, label="1Password injection")[0]
            return with_credentials(command, os.environ)
    except CredentialError as error:
        print(f"Release credentials: {error}", file=sys.stderr)
        return 1
    except Interrupted as error:
        print("Release interrupted; owned temporary credentials were cleaned up.", file=sys.stderr)
        return 128 + error.signum
    except (OSError, ValueError):
        print("Release credential setup failed; details suppressed to protect credentials.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
