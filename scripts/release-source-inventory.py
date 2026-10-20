#!/usr/bin/env python3
"""Bind local release builds to the exact tracked and nonignored source inputs."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess


def inventory(root):
    root = Path(root).resolve()
    output = subprocess.check_output(
        ['git', '-C', str(root), 'ls-files', '--cached', '--others', '--exclude-standard', '-z'])
    names = sorted(set(os.fsdecode(name) for name in output.split(b'\0') if name))
    result = {}
    for name in names:
        path = root / name
        if Path(name).is_absolute() or '..' in Path(name).parts:
            raise ValueError('Source inventory contains an external path')
        for parent in path.relative_to(root).parents:
            if parent != Path('.') and (root / parent).is_symlink():
                raise ValueError(f'Source path traverses a directory symlink: {name!r}')
        try:
            metadata = path.lstat()
        except FileNotFoundError:
            result[name] = {'kind': 'missing'}
            continue
        mode = stat.S_IMODE(metadata.st_mode)
        if stat.S_ISLNK(metadata.st_mode):
            value = os.fsencode(os.readlink(path))
            result[name] = {'kind': 'symlink', 'mode': mode, 'sha256': hashlib.sha256(value).hexdigest()}
        elif stat.S_ISREG(metadata.st_mode):
            descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
            with os.fdopen(descriptor, 'rb') as stream:
                opened = os.fstat(stream.fileno())
                if not stat.S_ISREG(opened.st_mode):
                    raise ValueError(f'Source file changed while collecting inputs: {name!r}')
                hasher = hashlib.sha256()
                for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                    hasher.update(chunk)
                digest = hasher.hexdigest()
                after = os.fstat(stream.fileno())
            current = path.lstat()
            def identity(info):
                return (info.st_dev, info.st_ino, info.st_mode, info.st_size, info.st_mtime_ns, info.st_ctime_ns)
            if identity(metadata) != identity(opened) or identity(opened) != identity(after) or identity(after) != identity(current):
                raise ValueError(f'Source file changed while collecting inputs: {name!r}')
            result[name] = {'kind': 'file', 'mode': mode, 'sha256': digest}
        else:
            raise ValueError(f'Unsupported source file type: {name!r}')
    return result


def inventory_digest(files):
    encoded = json.dumps(files, sort_keys=True, separators=(',', ':')).encode()
    return hashlib.sha256(encoded).hexdigest()


def verify(root, expected):
    actual = inventory(root)
    if actual != expected:
        changed = sorted(name for name in set(actual) | set(expected) if actual.get(name) != expected.get(name))
        detail = ', '.join(repr(name) for name in changed[:8])
        if len(changed) > 8:
            detail += f', and {len(changed) - 8} more'
        raise ValueError(f'Source files changed since the build snapshot: {detail}')


def verify_receipt(root, receipt):
    files = receipt.get('source_files')
    if not isinstance(files, dict) or not files:
        raise ValueError('Build receipt has no source file inventory')
    if receipt.get('source_files_sha256') != inventory_digest(files):
        raise ValueError('Build receipt source inventory digest does not match')
    verify(root, files)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('capture', 'verify'))
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--snapshot', type=Path, required=True)
    args = parser.parse_args()
    if args.action == 'capture':
        files = inventory(args.root)
        snapshot = {'source_files': files, 'source_files_sha256': inventory_digest(files)}
        args.snapshot.write_text(json.dumps(snapshot, sort_keys=True, indent=2) + '\n')
    else:
        verify_receipt(args.root, json.loads(args.snapshot.read_text()))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit(f'Source inventory failed: {error}') from error
