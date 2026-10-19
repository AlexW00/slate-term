#!/usr/bin/env python3
"""Inspect, verify, publish and reconcile a tag-built release. Never build or move tags."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import date
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def helper(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


updates = helper('release-updates')
source = helper('release-source')
require = updates.require


def run(*command, binary=False):
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=not binary, timeout=600)
    require(result.returncode == 0, 'Command failed: ' + ' '.join(str(x) for x in command[:3]))
    return result.stdout


def gh(*arguments):
    return json.loads(run('gh', *arguments))


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.replace(path)


def asset_identity(release):
    return sorted([{k: asset.get(k) for k in ('id', 'name', 'size', 'digest', 'updated_at')}
                   for asset in release['assets']], key=lambda asset: asset['name'])


def version_tuple(tag):
    require(re.fullmatch(r'v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)', tag), 'Expected stable vX.Y.Z tag')
    return tuple(map(int, tag[1:].split('.')))


def identity(args):
    version_tuple(args.tag)
    commit = run('git', 'rev-parse', args.tag + '^{commit}').strip()
    remote = gh('api', f'repos/{args.repository}/commits/{args.tag}')['sha']
    require(commit == remote, 'Local and remote release tags differ')
    runs = {}
    for workflow in ('ci.yml', 'release.yml'):
        matches = gh('run', 'list', '--repo', args.repository, '--commit', commit, '--event', 'push',
                     '--workflow', workflow, '--limit', '100', '--json', 'databaseId,headSha,headBranch,status,conclusion,url')
        matches = [item for item in matches if item['headBranch'] == args.tag and item['headSha'] == commit]
        runs[workflow] = matches[0] if matches else None
    return commit, runs


def candidate(args):
    commit, runs = identity(args)
    release = gh('api', f'repos/{args.repository}/releases/tags/{args.tag}')
    require(release['tag_name'] == args.tag and not release['prerelease'], 'Expected stable release candidate')
    return release, commit, runs


def require_runs(runs):
    require(set(runs) == {'ci.yml', 'release.yml'} and all(item and item['status'] == 'completed' and item['conclusion'] == 'success'
                for item in runs.values()), 'Both tag-triggered CI and Release must succeed; inspect status')


def layout(release, tag):
    archives = [asset['name'] for asset in release['assets'] if asset['name'].endswith('-arm64.zip')]
    require(len(archives) == 1, 'Expected one update archive')
    match = re.fullmatch(r'Slate-Terminal-' + re.escape(tag[1:]) + r'-([1-9][0-9]*)-arm64.zip', archives[0])
    require(match is not None, 'Archive version does not match tag')
    build = match[1]
    stem = f'Slate-Terminal-{tag[1:]}-{build}'
    names = {stem + '-arm64.zip', stem + '-arm64.dmg', stem + '-arm64.md', stem + '-source.tar.gz',
             'Slate-Terminal-arm64.dmg', 'appcast.xml', 'SHA256SUMS'}
    require(len(release['assets']) == len(names) and {a['name'] for a in release['assets']} == names,
            'Unexpected or missing release assets')
    return build, stem, names


def checksums(directory, names):
    expected = names - {'SHA256SUMS'}
    entries = {}
    for line in (directory / 'SHA256SUMS').read_text().splitlines():
        match = re.fullmatch(r'([0-9a-f]{64}) [ *](?:\./)?([^/]+)', line)
        require(match is not None, 'Malformed SHA256SUMS')
        value, name = match.groups()
        require(name in expected and name not in entries, 'Unexpected or duplicate checksum entry')
        path = directory / name
        require(path.is_file() and not path.is_symlink() and digest(path) == value, 'Checksum mismatch: ' + name)
        entries[name] = value
    require(set(entries) == expected, 'Incomplete SHA256SUMS')
    entries['SHA256SUMS'] = digest(directory / 'SHA256SUMS')
    return entries


def download_candidate(args, release, directory):
    directory.mkdir(parents=True, exist_ok=True)
    for asset in release['assets']:
        name = asset['name']
        expected = asset.get('digest', '')
        require(re.fullmatch(r'sha256:[0-9a-f]{64}', expected or ''), 'GitHub asset lacks SHA-256 digest: ' + name)
        path = directory / name
        require(not path.is_symlink(), 'Asset cache contains a symlink')
        if not path.is_file() or 'sha256:' + digest(path) != expected:
            run('gh', 'release', 'download', args.tag, '--repo', args.repository, '--dir', str(directory),
                '--pattern', name, '--clobber')
        require('sha256:' + digest(path) == expected, 'Downloaded asset differs from GitHub digest: ' + name)


def verify_signatures(directory, stem, public_key, signatures):
    feed = (directory / 'appcast.xml').read_bytes()
    content, separator, block = feed.rpartition(b'<!-- sparkle-signatures:\n')
    match = re.fullmatch(rb'([\s\S]*?)-->(?:\s*)', block)
    require(separator and match is not None, 'Missing signed feed footer')
    signature = re.search(rb'(?:^|\n)edSignature: ([A-Za-z0-9+/=]+)(?:\n|$)', match[1])
    length = re.search(rb'(?:^|\n)length: ([0-9]+)(?:\n|$)', match[1])
    require(signature is not None and length is not None and int(length[1]) == len(content), 'Invalid signed feed length')
    with tempfile.TemporaryDirectory(prefix='slate-signatures-') as temporary:
        path = Path(temporary) / 'feed.xml'
        path.write_bytes(content)
        files = [{'path': str(path), 'signature': signature[1].decode()}]
        files += [{'path': str(directory / (stem + suffix)), 'signature': sig}
                  for suffix, sig in zip(('-arm64.zip', '-arm64.md'), signatures)]
        result = subprocess.run(['swift', str(ROOT / 'scripts/verify-release-signatures.swift')],
                                input=json.dumps({'publicKey': public_key, 'files': files}),
                                text=True, capture_output=True, timeout=180)
        require(result.returncode == 0, 'Feed, archive or notes signature verification failed')


def verify_bundle(directory, stem, version, build, repository, public_key):
    archive = directory / (stem + '-arm64.zip')
    with zipfile.ZipFile(archive) as bundle:
        for name in bundle.namelist():
            require(not name.startswith('/') and '..' not in Path(name).parts, 'Unsafe app archive path')
    with tempfile.TemporaryDirectory(prefix='slate-release-app-') as temporary:
        run('ditto', '-x', '-k', str(archive), temporary)
        app = Path(temporary) / 'Slate Terminal.app'
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        require(info['CFBundleShortVersionString'] == version and str(info['CFBundleVersion']) == build,
                'Embedded app version/build mismatch')
        updates.validate_configuration(info, repository)
        require(info['SUPublicEDKey'] == public_key, 'Embedded update key mismatch')
        require(info.get('SUAutomaticallyUpdate') is False and info.get('SUAllowsAutomaticUpdates') is False,
                'Release must retain explicit update installation consent')
        run('codesign', '--verify', '--deep', '--strict', str(app))
        run('xcrun', 'stapler', 'validate', str(app))
        run('spctl', '--assess', '--type', 'execute', str(app))
        app_hash = source.app_tree_sha256(app)
    dmg = directory / (stem + '-arm64.dmg')
    run('codesign', '--verify', '--strict', str(dmg))
    run('xcrun', 'stapler', 'validate', str(dmg))
    verify_dmg_app(dmg, app_hash)


def verify_dmg_app(dmg, expected_hash):
    with tempfile.TemporaryDirectory(prefix='slate-release-dmg-') as temporary:
        mount = Path(temporary) / 'mount'
        mount.mkdir()
        run('hdiutil', 'attach', '-readonly', '-nobrowse', '-noautoopen', '-mountpoint', str(mount), str(dmg))
        try:
            app = mount / 'Slate Terminal.app'
            require(app.is_dir() and not app.is_symlink() and source.app_tree_sha256(app) == expected_hash,
                    'DMG app differs from the verified ZIP app')
        finally:
            run('hdiutil', 'detach', str(mount))


def verify_project_source(manifest, commit):
    entries = []
    for entry in run('git', 'ls-tree', '-rz', '--full-tree', commit, binary=True).split(b'\0'):
        if entry:
            metadata, name = entry.split(b'\t', 1)
            mode, kind, object_id = metadata.decode().split()
            require(kind == 'blob', 'Submodule source needs explicit verification')
            entries.append((name.decode(), mode, object_id))
    result = subprocess.run(['git', 'cat-file', '--batch'], cwd=ROOT,
                            input=''.join(oid + '\n' for _, _, oid in entries).encode(),
                            capture_output=True, timeout=120)
    require(result.returncode == 0, 'Could not read tagged source')
    stream = io.BytesIO(result.stdout)
    expected = {}
    for name, mode, oid in entries:
        header = stream.readline().decode().split()
        require(len(header) == 3 and header[:2] == [oid, 'blob'], 'Unexpected Git blob response')
        data = stream.read(int(header[2]))
        require(stream.read(1) == b'\n', 'Incomplete Git blob response')
        expected[name] = ({'symlink': data.decode(), 'mode': 0o777} if mode == '120000' else
                          {'sha256': hashlib.sha256(data).hexdigest(), 'mode': 0o755 if mode == '100755' else 0o644})
    files = manifest['files']
    require(all(files.get(name) == value for name, value in expected.items()),
            'Packaged project source differs from tagged Git tree')
    extra = set(files) - set(expected)
    require({'REBUILD.md', 'prepare-rebuild.py'} <= extra and
            all(name.startswith('vendor/') or name in ('REBUILD.md', 'prepare-rebuild.py') for name in extra),
            'Unexpected project source inventory')


def verify_dependency_inventory(manifest, commit):
    inventory = json.loads(run('git', 'show', f'{commit}:licenses/manifest.json'))
    require(manifest['ghostty_revision'] == inventory['ghostty_revision'] and
            manifest['zig_version'] == inventory['zig_version'], 'Packaged dependency versions differ from tagged pins')
    require({pin['identity']: pin['revision'] for pin in manifest['swift_packages']} == inventory['xcode_swift_pins'],
            'Packaged Swift dependencies differ from tagged pins')
    files = manifest['files']
    required_files = {'vendor/ghostty/build.zig', 'vendor/ghostty/src/main.zig',
                      'vendor/zig-runtime-source/LICENSE', 'vendor/zig-runtime-source/lib/compiler_rt.zig',
                      'vendor/zig-runtime-source/lib/ubsan_rt.zig'}
    require(required_files <= set(files), 'Missing vendored source files')
    prefixes = ['vendor/ghostty/src/', 'vendor/ghostty/pkg/']
    prefixes += [f'vendor/swift/{identity}/' for identity in inventory['xcode_swift_pins']]
    prefixes += [f'vendor/zig-runtime-source/lib/{name}/'
                 for name in ('std', 'compiler_rt', 'libcxx', 'libcxxabi', 'libunwind')]
    declared_hashes = {entry['source']['zig_content_hash'] for entries in inventory['components'].values()
                       for entry in entries if 'zig_content_hash' in entry.get('source', {})}
    require(manifest['zig_packages'] and declared_hashes <= set(manifest['zig_packages']),
            'Missing pinned Zig source packages')
    prefixes += [f'vendor/ghostty/zig-pkg/{package}/' for package in manifest['zig_packages']]
    require(all(any(name.startswith(prefix) and 'sha256' in value for name, value in files.items())
                for prefix in prefixes), 'Missing vendored source component')


def verify(args):
    release, commit, runs = candidate(args)
    require_runs(runs)
    build, stem, names = layout(release, args.tag)
    directory = args.output / 'assets'
    download_candidate(args, release, directory)
    hashes = checksums(directory, names)
    require(hashes[stem + '-arm64.dmg'] == hashes['Slate-Terminal-arm64.dmg'], 'Installer alias differs')
    notes = run('git', 'show', f'{commit}:docs/releases/{args.tag}.md', binary=True)
    require((directory / (stem + '-arm64.md')).read_bytes() == notes, 'Signed notes differ from tagged source')
    require(release['body'].replace('\r\n', '\n').strip() == notes.decode().strip(), 'GitHub notes differ from tagged source')
    key = gh('api', f'repos/{args.repository}/environments/release/variables/SPARKLE_PUBLIC_ED_KEY')['value']
    feed = gh('api', f'repos/{args.repository}/environments/release/variables/SPARKLE_FEED_URL')['value']
    updates.validate_public_configuration(key, feed, args.repository)
    signatures = updates.inspect_appcast(directory / 'appcast.xml', directory / (stem + '-arm64.zip'),
                                         directory / (stem + '-arm64.md'), args.repository, args.tag[1:], build)
    verify_signatures(directory, stem, key, signatures)
    archive = directory / (stem + '-source.tar.gz')
    with tarfile.open(archive) as package:
        member = package.getmember(stem + '-source/SOURCE-MANIFEST.json')
        require(member.isfile() and member.size <= 16 * 1024 * 1024, 'Invalid source manifest')
        manifest = json.load(package.extractfile(member))
    require(manifest['source_commit'] == commit and manifest['version'] == args.tag[1:] and
            str(manifest['build_number']) == build, 'Corresponding source mismatch')
    source.verify_source_archive(archive, manifest)
    verify_project_source(manifest, commit)
    verify_dependency_inventory(manifest, commit)
    verify_bundle(directory, stem, args.tag[1:], build, args.repository, key)
    receipt = dict(repository=args.repository, tag=args.tag, commit=commit, build=build, releaseID=release['id'],
                   assets=asset_identity(release), sha256=hashes, publicKey=key, runs=runs,
                   checks=['checksums', 'signatures', 'notes', 'source', 'Apple signatures and notarization'],
                   native='Not established by artifact verification')
    write_json(args.output / 'verified.json', receipt)
    return receipt


def verified(args, release, commit):
    receipt = json.loads((args.output / 'verified.json').read_text())
    require((receipt['repository'], receipt['tag'], receipt['commit'], receipt['releaseID'], receipt['assets']) ==
            (args.repository, args.tag, commit, release['id'], asset_identity(release)),
            'Candidate changed since verification; run verify again')
    build, stem, names = layout(release, args.tag)
    require(receipt['build'] == build, 'Verified build differs from candidate')
    notes = (args.output / 'assets' / (stem + '-arm64.md')).read_text()
    require(release['body'].replace('\r\n', '\n').strip() == notes.strip(), 'Release notes changed since verification')
    require(checksums(args.output / 'assets', names) == receipt['sha256'], 'Verified local assets changed')
    return receipt


def latest(args):
    # Authenticated listing also works before the first stable release exists.
    releases = gh('api', '--paginate', '--slurp', f'repos/{args.repository}/releases?per_page=100')
    stable = [release for page in releases for release in page if not release['draft'] and not release['prerelease']]
    return max(stable, key=lambda release: version_tuple(release['tag_name'])) if stable else None


def publish(args):
    release, commit, runs = candidate(args)
    require_runs(runs)
    receipt = verified(args, release, commit)
    baseline = latest(args)
    if release['draft']:
        require(args.native_evidence or args.native_waiver, 'Record native evidence or an explicit maintainer waiver')
        if baseline:
            old_build, _, _ = layout(baseline, baseline['tag_name'])
            require(version_tuple(args.tag) > version_tuple(baseline['tag_name']) and int(receipt['build']) > int(old_build),
                    'Version and build must advance beyond published stable')
        write_json(args.output / 'publication-intent.json', dict(tag=args.tag, commit=commit,
                   nativeEvidence=args.native_evidence, nativeWaiver=args.native_waiver))
        run('gh', 'release', 'edit', args.tag, '--repo', args.repository, '--draft=false', '--prerelease=false', '--latest')
    else:
        require(baseline and baseline['id'] == release['id'], 'Already published release is no longer newest; refusing promotion')
    # A retry after successful publication continues readback without another remote mutation.
    return public(args)


def download_public(url, path, expected, mutable=False):
    require(not path.is_symlink(), 'Public asset cache contains a symlink')
    if not mutable and path.is_file() and digest(path) == expected:
        return
    # Deliberately use urllib without gh, cookies or authorization headers.
    for attempt in range(6):
        temporary = path.with_suffix(path.suffix + '.part')
        try:
            request = urllib.request.Request(url, headers={'User-Agent': 'Slate-release-verification'})
            with urllib.request.urlopen(request, timeout=90) as response, temporary.open('wb') as output:
                while block := response.read(1024 * 1024):
                    output.write(block)
            if digest(temporary) == expected:
                temporary.replace(path)
                return
            require(mutable, 'Published immutable asset differs from verified candidate: ' + path.name)
        except (urllib.error.URLError, TimeoutError):
            pass
        finally:
            temporary.unlink(missing_ok=True)
        if attempt < 5:
            time.sleep(10)
    raise ValueError('Public asset unavailable or mismatched after bounded retries: ' + path.name)


def public(args):
    release, commit, _ = candidate(args)
    require(not release['draft'], 'Release is still a draft')
    receipt = verified(args, release, commit)
    directory = args.output / 'public'
    directory.mkdir(parents=True, exist_ok=True)
    prefix = f'https://github.com/{args.repository}/releases/'
    def fetch(item):
        name, expected = item
        route = 'latest/download/' if name in ('appcast.xml', 'Slate-Terminal-arm64.dmg') else f'download/{args.tag}/'
        download_public(prefix + route + name, directory / name, expected,
                        mutable=name in ('appcast.xml', 'Slate-Terminal-arm64.dmg'))
    with ThreadPoolExecutor(max_workers=4) as pool:
        list(pool.map(fetch, receipt['sha256'].items()))
    result = dict(tag=args.tag, commit=commit, releaseID=release['id'], publishedAt=release['published_at'],
                  url=release['html_url'], unauthenticated=True, sha256=receipt['sha256'])
    write_json(args.output / 'public.json', result)
    return result


def reconcile_text(text, version, published_at):
    published_date = date.fromisoformat(published_at[:10]).isoformat()
    pending = f'## {version} — Pending publication'
    completed = f'## {version} — {published_date}'
    lines = text.splitlines(keepends=True)
    require(sum(line.rstrip('\r\n') in (pending, completed) for line in lines) == 1,
            'Expected one exact candidate or published ledger heading')
    return ''.join(completed + line[len(pending):] if line.rstrip('\r\n') == pending else line for line in lines)


def reconcile(args):
    release, commit, _ = candidate(args)
    require(not release['draft'] and release['published_at'], 'Cannot date an unpublished release')
    receipt = verified(args, release, commit)
    delivery = json.loads((args.output / 'public.json').read_text())
    require(delivery['releaseID'] == release['id'] and delivery['commit'] == commit and delivery['sha256'] == receipt['sha256'],
            'Run public readback before ledger reconciliation')
    original = args.ledger.read_bytes()
    text = original.decode('utf-8')
    updated = reconcile_text(text, args.tag[1:], release['published_at'])
    if text != updated:
        require(args.ledger.read_bytes() == original, 'Ledger changed during reconciliation')
        args.ledger.write_bytes(updated.encode('utf-8'))
    return dict(ledger=str(args.ledger), publishedAt=release['published_at'], changed=text != updated)


def status(args):
    commit, runs = identity(args)
    pages = gh('api', '--paginate', '--slurp', f'repos/{args.repository}/releases?per_page=100')
    releases = [release for page in pages for release in page]
    release = next((release for release in releases if release['tag_name'] == args.tag), None)
    return dict(tag=args.tag, commit=commit, draft=release['draft'] if release else None,
                url=release['html_url'] if release else None, runs=runs)


def watch(args):
    deadline = time.monotonic() + args.timeout
    previous = None
    while True:
        value = status(args)
        encoded = json.dumps(value, sort_keys=True)
        if encoded != previous:
            print(json.dumps(value, indent=2), flush=True)
            previous = encoded
        runs = value['runs']
        require(not any(item and item['status'] == 'completed' and item['conclusion'] != 'success'
                        for item in runs.values()), 'Tag workflow failed; inspect its run URL before retrying')
        if all(item and item['status'] == 'completed' for item in runs.values()) and value['url']:
            require_runs(runs)
            return value
        require(time.monotonic() < deadline, 'Timed out waiting; rerun watch to resume')
        time.sleep(min(15, max(0, deadline - time.monotonic())))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('status', 'watch', 'verify', 'publish', 'public', 'reconcile'))
    parser.add_argument('--repository', default='AlexW00/slate-term')
    parser.add_argument('--tag', required=True)
    parser.add_argument('--output', type=Path, help='Receipt/cache directory; defaults to artifacts/releases/TAG')
    parser.add_argument('--native-evidence', help='Native test evidence reference (publish only)')
    parser.add_argument('--native-waiver', help='Explicit maintainer waiver and reason (publish only)')
    parser.add_argument('--timeout', type=int, default=3600, help='Bounded watch duration in seconds')
    parser.add_argument('--ledger', type=Path, default=ROOT / 'CHANGELOG.md')
    args = parser.parse_args()
    version_tuple(args.tag)
    require(re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', args.repository), 'Invalid repository')
    args.output = (args.output or ROOT / 'artifacts/releases' / args.tag).resolve()
    result = globals()[args.command](args)
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, subprocess.SubprocessError, tarfile.TarError, zipfile.BadZipFile) as error:
        print('Release operation failed: ' + str(error), file=sys.stderr)
        sys.exit(1)
