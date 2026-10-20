#!/usr/bin/env python3
"""Assemble and sign Slate's self-contained, replaceable native runtime."""
import argparse
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

RUNTIME_NAME = 'SlateRuntime.framework'
RUNTIME_IDENTIFIER = 'com.slateterm.runtime'
TEAM_IDENTIFIER = 'YWRT8FQN6F'
TOOLS = ('slate-term', 'slate-layout-launcher')
SPARKLE_VERSION = '2.10.0'
SPARKLE_HELPERS = (
    'Versions/B/Autoupdate',
    'Versions/B/Updater.app/Contents/MacOS/Updater',
    'Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer',
    'Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader',
)


def run(*args):
    return subprocess.check_output([str(arg) for arg in args], text=True, stderr=subprocess.PIPE)


def runtime_path(app):
    return app / 'Contents' / 'Frameworks' / RUNTIME_NAME


def macho_files(root):
    magics = {b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'}
    result = []
    for path in root.rglob('*'):
        if path.is_file() and not path.is_symlink():
            with path.open('rb') as stream:
                if stream.read(4) in magics:
                    result.append(path)
    return result


def framework_dependencies(load_commands):
    return set(re.findall(r'^\s+@rpath/([^/]+\.framework)/', load_commands, re.MULTILINE))


def check_internal_links(root):
    if root.is_symlink():
        raise ValueError(f'Runtime root must not be a symbolic link: {root}')
    resolved = root.resolve()
    for path in root.rglob('*'):
        if path.is_symlink():
            try:
                path.resolve(strict=True).relative_to(resolved)
            except (OSError, ValueError) as error:
                raise ValueError(f'Runtime link escapes its bundle or is broken: {path}') from error


def add_rpath(binary, path):
    commands = run('otool', '-l', binary)
    if f'path {path} (offset ' not in commands:
        run('install_name_tool', '-add_rpath', path, binary)


def remove_build_rpaths(binary):
    commands = run('otool', '-l', binary)
    paths = re.findall(r'\bcmd LC_RPATH\s+cmdsize \d+\s+path (.+) \(offset \d+\)', commands)
    for path in paths:
        if path.startswith('/') and not path.startswith(('/usr/lib/', '/System/Library/')):
            run('install_name_tool', '-delete_rpath', path, binary)


def copy_bundle(source, destination):
    if destination.exists():
        shutil.rmtree(destination)
    run('ditto', source, destination)


def embed(app, products):
    source = products / RUNTIME_NAME
    if not source.is_dir():
        raise ValueError('Build SlateRuntime.framework before embedding it.')
    runtime = runtime_path(app)
    runtime.parent.mkdir(parents=True, exist_ok=True)
    copy_bundle(source, runtime)
    version = runtime / 'Versions' / 'A'
    helpers = version / 'Helpers'
    frameworks = version / 'Frameworks'
    helpers.mkdir(exist_ok=True)
    frameworks.mkdir(exist_ok=True)
    for name in ('Helpers', 'Frameworks'):
        link = runtime / name
        if not link.exists():
            link.symlink_to(f'Versions/Current/{name}')
    for name in TOOLS:
        source_tool = products / name
        if not source_tool.is_file():
            raise ValueError(f'Missing executable helper: {source_tool}')
        shutil.copy2(source_tool, helpers / name)
        # Debug linkers include build directories before the runtime's private dependencies.
        remove_build_rpaths(helpers / name)
        add_rpath(helpers / name, '@executable_path/../Frameworks')
    add_rpath(version / 'SlateRuntime', '@loader_path/Frameworks')
    # Follow the actual linked dependency closure, including helper-only dependencies.
    pending = macho_files(runtime)
    included = {RUNTIME_NAME}
    while pending:
        binary = pending.pop()
        for name in sorted(framework_dependencies(run('otool', '-L', binary)) - included):
            candidates = (products / name, products / 'PackageFrameworks' / name)
            dependency = next((path for path in candidates if path.is_dir()), None)
            if dependency is None:
                raise ValueError(f'Cannot locate private dependency {name} required by {binary.name}')
            destination = frameworks / name
            copy_bundle(dependency, destination)
            included.add(name)
            pending.extend(macho_files(destination))
    # Swift package resource bundles are versioned with their implementation.
    for resource in products.glob('*.bundle'):
        copy_bundle(resource, version / 'Resources' / resource.name)
    check_internal_links(runtime)
    # Helpers receive a new load command; the linker signature is now stale.
    sign_runtime(runtime, '-')
    validate(app)


def sign_runtime(runtime, identity, keychain=None, timestamp=False):
    command = ['codesign', '--force', '--sign', identity, '--options', 'runtime',
               '--timestamp' if timestamp else '--timestamp=none']
    if keychain:
        command += ['--keychain', keychain]
    bundles = [p for p in runtime.rglob('*') if p.is_dir() and not p.is_symlink()
               and p.suffix in ('.framework', '.app', '.xpc', '.appex', '.bundle')]
    development = plistlib.loads((runtime / 'Resources' / 'Info.plist').read_bytes()).get('SlateRuntimeDevelopment')
    helpers = {runtime / 'Versions' / 'A' / 'Helpers' / name for name in TOOLS}
    downloader = runtime / 'Versions/A/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc'

    def preserved_entitlements(path):
        # Sparkle supplies the downloader's sandbox permissions; retain them through both signing passes.
        return ['--preserve-metadata=entitlements'] if path == downloader or path.is_relative_to(downloader) else []

    with tempfile.TemporaryDirectory(prefix='slate-helper-sign-') as temporary:
        helper_options = []
        # Ad-hoc development helpers cannot satisfy hardened runtime library validation.
        if development in (True, 'YES') and identity == '-':
            entitlements = Path(temporary) / 'entitlements.plist'
            entitlements.write_bytes(plistlib.dumps({'com.apple.security.cs.disable-library-validation': True}))
            helper_options = ['--entitlements', str(entitlements)]
        for path in sorted(macho_files(runtime), key=lambda p: len(p.parts), reverse=True):
            run(*command, *preserved_entitlements(path), *(helper_options if path in helpers else []), path)
    for path in sorted(bundles, key=lambda p: len(p.parts), reverse=True):
        run(*command, *preserved_entitlements(path), path)
    # Newly generated Debug shells must accept later valid ad-hoc runtimes with this identity.
    requirements = ['--requirements', '=designated => identifier "' + RUNTIME_IDENTIFIER + '"'] if development in (True, 'YES', '1') and identity == '-' else []
    run(*command, '--identifier', RUNTIME_IDENTIFIER, *requirements, runtime)
    run('codesign', '--verify', '--deep', '--strict', runtime)


def validate(app, architecture=None):
    runtime = runtime_path(app)
    check_internal_links(runtime)
    info = plistlib.loads((runtime / 'Resources' / 'Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != RUNTIME_IDENTIFIER or str(info.get('SlateRuntimeABI')) != '1':
        raise ValueError('Runtime identity or bootstrap ABI is incorrect.')
    for name in TOOLS:
        helper = runtime / 'Versions' / 'A' / 'Helpers' / name
        if not os.access(helper, os.X_OK):
            raise ValueError(f'Missing executable runtime helper: {name}')
    for directory in ('ghostty', 'terminfo', 'skills'):
        if not (runtime / 'Resources' / directory).is_dir():
            raise ValueError(f'Missing runtime resources: {directory}')
    sparkle = runtime / 'Versions/A/Frameworks/Sparkle.framework'
    for relative in SPARKLE_HELPERS:
        helper = sparkle / relative
        if not helper.is_file() or not os.access(helper, os.X_OK):
            raise ValueError(f'Missing executable Sparkle component: {relative}')
    sparkle_info = plistlib.loads((sparkle / 'Resources/Info.plist').read_bytes())
    if sparkle_info.get('CFBundleShortVersionString') != SPARKLE_VERSION:
        raise ValueError('The embedded Sparkle version does not match the release pin.')
    for binary in macho_files(runtime):
        for name in framework_dependencies(run('otool', '-L', binary)) - {RUNTIME_NAME}:
            if not (runtime / 'Frameworks' / name).is_dir():
                raise ValueError(f'Runtime dependency is not private: {name}')
    if architecture:
        for binary in macho_files(app):
            architectures = set(run('lipo', '-archs', binary).split())
            allowed = ({architecture},)
            # Keep Sparkle's supplied universal binaries inside the Apple Silicon release.
            if architecture == 'arm64' and binary.is_relative_to(sparkle):
                allowed += ({'arm64', 'x86_64'},)
            if architectures not in allowed:
                raise ValueError(f'Expected {architecture} executable code: {binary}')
    run('codesign', '--verify', '--deep', '--strict', runtime)


def sign_app(app, identity, keychain=None, timestamp=False):
    runtime = runtime_path(app)
    development = plistlib.loads((app / 'Contents/Info.plist').read_bytes()).get('SlateRuntimeDevelopment')
    if development in (True, 'YES') and identity != '-':
        raise ValueError('A development bootstrap cannot be packaged with a publisher identity.')
    # Resource collection may have changed the old seal; establish the replacement signature first.
    check_internal_links(runtime)
    sign_runtime(runtime, identity, keychain, timestamp)
    validate(app)
    command = ['codesign', '--force', '--sign', identity, '--options', 'runtime',
               '--timestamp' if timestamp else '--timestamp=none']
    if keychain:
        command += ['--keychain', keychain]
    # Development shells use ad-hoc runtime code; this entitlement is never added to a release parent.
    with tempfile.TemporaryDirectory(prefix='slate-sign-') as temporary:
        if development in (True, 'YES'):
            entitlements = Path(temporary) / 'entitlements.plist'
            entitlements.write_bytes(plistlib.dumps({'com.apple.security.cs.disable-library-validation': True}))
            command += ['--entitlements', str(entitlements)]
        run(*command, app)
    run('codesign', '--verify', '--deep', '--strict', app)
    if identity != '-':
        requirement = f'anchor apple generic and certificate leaf[subject.OU] = "{TEAM_IDENTIFIER}" and identifier "{RUNTIME_IDENTIFIER}"'
        run('codesign', '--verify', '--strict', '-R', '=' + requirement, runtime)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('embed', 'verify', 'sign'))
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--products', type=Path)
    parser.add_argument('--identity', default='-')
    parser.add_argument('--keychain')
    parser.add_argument('--timestamp', action='store_true')
    parser.add_argument('--architecture')
    args = parser.parse_args()
    try:
        if args.action == 'embed':
            if args.products is None:
                parser.error('embed requires --products')
            embed(args.app, args.products)
        elif args.action == 'verify':
            validate(args.app, args.architecture)
        else:
            sign_app(args.app, args.identity, args.keychain, args.timestamp)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        message = error.stderr.strip() if isinstance(error, subprocess.CalledProcessError) else str(error)
        print(f'Runtime packaging failed: {message}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
