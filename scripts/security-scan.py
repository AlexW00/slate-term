#!/usr/bin/env python3
"""Scan publishable files and every reachable Git object without printing secrets."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

VERSION = '8.30.1'
ARCHIVES = {
    ('Darwin', 'arm64'): ('darwin_arm64', 'b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5'),
    ('Linux', 'x86_64'): ('linux_x64', '551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb'),
}
SENSITIVE_SUFFIXES = ('.p12', '.pfx', '.p8', '.pem', '.key', '.keychain', '.keychain-db', '.mobileprovision', '.provisionprofile')
SAFE_REPORT_FIELDS = ('RuleID', 'File', 'StartLine', 'EndLine', 'Commit', 'Fingerprint')


class ScanError(Exception):
    pass


def git(root, *args, input=None):
    result = subprocess.run(['git', '-C', str(root), *args], input=input, capture_output=True)
    if result.returncode:
        raise ScanError('Git inspection failed; run this command from a complete repository.')
    return result.stdout


def scanner(root):
    """Install only the pinned executable after checking the archive digest."""
    key = (platform.system(), platform.machine())
    if key not in ARCHIVES:
        raise ScanError('The scanner supports Apple Silicon macOS and x64 Linux.')
    asset, digest = ARCHIVES[key]
    tools = root / '.tools' / ('gitleaks-' + VERSION)
    binary = tools / 'gitleaks'
    marker = tools / 'binary.sha256'
    if binary.is_file() and marker.is_file():
        if hashlib.sha256(binary.read_bytes()).hexdigest() == marker.read_text().strip():
            return binary
    tools.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='download-', dir=tools) as tmp:
        archive = Path(tmp) / 'gitleaks.tar.gz'
        url = f'https://github.com/gitleaks/gitleaks/releases/download/v{VERSION}/gitleaks_{VERSION}_{asset}.tar.gz'
        try:
            with urllib.request.urlopen(url, timeout=60) as response, archive.open('wb') as output:
                shutil.copyfileobj(response, output)
        except Exception:
            raise ScanError('Could not download the pinned scanner; no scan was completed.') from None
        if hashlib.sha256(archive.read_bytes()).hexdigest() != digest:
            raise ScanError('Scanner archive checksum mismatch.')
        with tarfile.open(archive) as source:
            member = source.getmember('gitleaks')
            if not member.isfile():
                raise ScanError('Unexpected scanner archive contents.')
            with source.extractfile(member) as content, binary.open('wb') as output:
                shutil.copyfileobj(content, output)
        binary.chmod(0o755)
        marker.write_text(hashlib.sha256(binary.read_bytes()).hexdigest() + '\n')
    return binary


def private_filename(path):
    p = Path(path)
    name = p.name.lower()
    return (any(part == 'xcuserdata' for part in p.parts)
            or name.endswith(SENSITIVE_SUFFIXES)
            or (name.startswith('.env') and not name.endswith(('.example', '.sample')))
            or name in ('id_rsa', 'id_ed25519', 'credentials', '.netrc'))


def source_path(root, name):
    relative = Path(name)
    if relative.is_absolute() or '..' in relative.parts:
        raise ScanError('A source path escapes the repository.')
    parent = root
    # Check parents from the root so inspecting a deeper path cannot follow a link.
    for component in relative.parts[:-1]:
        parent = parent / component
        if parent.is_symlink():
            raise ScanError('A source path traverses a symbolic link; inspect the checkout before scanning.')
    return root / relative


def publishable_paths(root, include_untracked):
    args = ['ls-files', '-z', '--cached']
    if include_untracked:
        args += ['--others', '--exclude-standard']
    names = set(os.fsdecode(path) for path in git(root, *args).split(b'\0') if path)
    selected = []
    for name in names:
        path = source_path(root, name)
        if path.exists() or path.is_symlink():
            selected.append(name)
    return sorted(selected)


def stage_files(root, destination, paths):
    for name in paths:
        source = source_path(root, name)
        if not source.exists() and not source.is_symlink():
            continue
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        # Scan a link's spelling, never a private file outside the checkout.
        if source.is_symlink():
            target.write_text(os.readlink(source))
        elif source.is_file():
            shutil.copyfile(source, target)
        else:
            raise ScanError('Nested repositories must be audited separately: ' + name)


def selected_revisions(root, revision):
    return ['--all'] if revision is None else [git(root, 'rev-parse', '--verify', revision + '^{commit}').decode().strip()]


def historical_private_paths(root, revision):
    # Binary credentials can evade text rules, so inspect names in every reachable tree.
    trees = set(git(root, 'log', '--format=%T', *selected_revisions(root, revision)).splitlines())
    blocked = set()
    for tree in trees:
        names = git(root, 'ls-tree', '-r', '--name-only', '-z', tree.decode()).split(b'\0')
        blocked.update(os.fsdecode(name) for name in names if name and private_filename(os.fsdecode(name)))
    return sorted(blocked)


def object_inventory(root, revision):
    rev = selected_revisions(root, revision)
    objects = git(root, 'rev-list', '--objects', *rev).splitlines()
    ids = sorted(set(line.split(b' ', 1)[0] for line in objects))
    checked = git(root, 'cat-file', '--batch-check=%(objectname) %(objecttype)', input=b'\n'.join(ids) + b'\n')
    return [(oid.decode(), kind.decode()) for oid, kind in (line.split() for line in checked.splitlines())
            if kind in (b'blob', b'commit')]


def scan(binary, config, root, arguments, report, objects=None):
    environment = dict(os.environ)
    for name in ('GITLEAKS_CONFIG', 'GITLEAKS_CONFIG_TOML'):
        environment.pop(name, None)
    with tempfile.TemporaryDirectory(prefix='slate-scan-') as tmp:
        raw = Path(tmp) / 'raw.json'
        command = [str(binary), *arguments, '--config', str(config), '--redact=100', '--no-banner',
                   '--exit-code', '1', '--report-format', 'json', '--report-path', str(raw)]
        if objects is None:
            result = subprocess.run(command, cwd=root, env=environment, capture_output=True)
            code = result.returncode
        else:
            # Keep scanner diagnostics private even on parse failures or detected credentials.
            with (Path(tmp) / 'diagnostics').open('wb') as diagnostics:
                process = subprocess.Popen(command, cwd=root, env=environment, stdin=subprocess.PIPE,
                                           stdout=diagnostics, stderr=diagnostics)
                try:
                    for oid, kind in objects:
                        payload = git(root, 'cat-file', kind, oid)
                        process.stdin.write(b'\nOBJECT ' + oid.encode() + b'\n' + payload + b'\n')
                    process.stdin.close()
                    code = process.wait()
                except BaseException:
                    process.kill()
                    process.wait()
                    raise
        if code not in (0, 1):
            raise ScanError('The scanner could not complete; diagnostic content was suppressed.')
        findings = json.loads(raw.read_text()) if raw.is_file() else []
        safe = [{field: finding[field] for field in SAFE_REPORT_FIELDS if field in finding} for finding in findings]
        report.write_text(json.dumps(safe, indent=2) + '\n')
        for finding in safe:
            print('Detected:', finding.get('RuleID', 'secret'), finding.get('File', ''),
                  'line', finding.get('StartLine', '?'), 'commit', finding.get('Commit', ''))
        return code == 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--include-untracked', action='store_true', help='Include nonignored new source files.')
    parser.add_argument('--tree-only', action='store_true', help='Skip historical objects (not a publication audit).')
    parser.add_argument('--ref', help='Scan only objects reachable from this ref; defaults to all local refs.')
    args = parser.parse_args(argv)
    root = Path(git(Path.cwd(), 'rev-parse', '--show-toplevel').decode().strip())
    if not args.tree_only and git(root, 'rev-parse', '--is-shallow-repository').strip() == b'true':
        raise ScanError('Fetch complete history before scanning: git fetch --unshallow.')
    paths = publishable_paths(root, args.include_untracked)
    blocked = [path for path in paths if private_filename(path)]
    if blocked:
        for path in blocked:
            print('Remove private/generated file from publishable source:', path)
        return 1
    if not args.tree_only:
        historical_blocked = historical_private_paths(root, args.ref)
        if historical_blocked:
            for path in historical_blocked:
                print('Remove private/generated file from publishable history:', path)
            return 1
    output = root / 'artifacts' / 'security'
    output.mkdir(parents=True, exist_ok=True)
    binary = scanner(root)
    config = root / '.gitleaks.toml'
    if not config.is_file():
        raise ScanError('The repository scanner configuration is missing.')
    with tempfile.TemporaryDirectory(prefix='slate-source-scan-') as tmp:
        tree = Path(tmp)
        stage_files(root, tree, paths)
        ok = scan(binary, config, root, ['dir', str(tree)], output / 'tree.json')
    count = 0
    if not args.tree_only:
        objects = object_inventory(root, args.ref)
        count = len(objects)
        ok = scan(binary, config, root, ['stdin'], output / 'objects.json', objects) and ok
    summary = {'passed': ok, 'scanner': VERSION, 'files': len(paths), 'historical_objects': count,
               'revision': git(root, 'rev-parse', 'HEAD').decode().strip(), 'ref': args.ref or '--all',
               'history_scanned': not args.tree_only, 'included_untracked': args.include_untracked}
    (output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(f'Secret scan {"passed" if ok else "FAILED"}: {len(paths)} files, {count} historical blobs/commits.')
    return 0 if ok else 1


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ScanError, OSError, ValueError, tarfile.TarError) as error:
        # Never format arbitrary subprocess output or decoded credential contents.
        print(str(error) if isinstance(error, ScanError) else 'Security scan failed before completion.', file=sys.stderr)
        sys.exit(2)
