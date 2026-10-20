"""Copy only runnable products/resources; no SDKs, compiler caches or guest builds."""
import hashlib
import importlib.util
import json
import plistlib
import re
import stat
import os
from pathlib import Path
import shutil
import subprocess


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


APP_GUEST_PATH = '.derived/Build/Products/Debug/Slate Terminal.app'
UPGRADE_APPS = {
    'upgrade': ('.vm-fixtures/upgrade.app', 'SLATE_TERM_TEST_UPGRADE_APP'),
    'incompatible': ('.vm-fixtures/incompatible.app', 'SLATE_TERM_TEST_INCOMPATIBLE_APP'),
}


def selected_app(root, app):
    """Only repository-owned bundles with portable internal symlinks may be staged."""
    root = root.resolve()
    path = Path(app)
    if not path.is_absolute():
        raise ValueError('--app requires an absolute .app path inside the repository')
    path = path.resolve(strict=True)
    if not path.is_relative_to(root) or path.suffix != '.app' or not path.is_dir():
        raise ValueError('--app must name an existing .app directory inside the repository')
    for entry in path.rglob('*'):
        if entry.is_symlink():
            target = os.readlink(entry)
            try:
                portable = not os.path.isabs(target) and entry.resolve(strict=True).is_relative_to(path)
            except (OSError, RuntimeError):
                portable = False
            if not portable:
                raise ValueError('App bundle has a nonportable symlink: ' + str(entry))
    return path


def app_tree_hash(app):
    """Use the release build receipt's digest, including modes and symlink targets."""
    result = hashlib.sha256()
    for path in sorted(app.rglob('*'), key=lambda entry: entry.relative_to(app).as_posix()):
        name = path.relative_to(app).as_posix().encode()
        mode = str(stat.S_IMODE(path.lstat().st_mode)).encode()
        if path.is_symlink():
            kind, value = b'l', os.readlink(path).encode()
        elif path.is_file():
            kind, value = b'f', digest(path).encode()
        elif path.is_dir():
            kind, value = b'd', b''
        else:
            raise ValueError('App bundle contains an unsupported file type: ' + str(path))
        result.update(kind + b'\0' + name + b'\0' + mode + b'\0' + value + b'\n')
    return result.hexdigest()


def bounded_regular_file(base, relative, limit):
    """Read an owned evidence file without following any symlink components."""
    if (not isinstance(relative, str) or not relative or Path(relative).is_absolute()
            or any(part in ('', '.', '..') for part in relative.split('/'))):
        raise ValueError('Invalid source variant evidence path')
    path = base / relative
    for part in [path, *path.parents]:
        if part == base:
            break
        if part.is_symlink():
            raise ValueError('Source variant evidence must not traverse symlinks')
    if not path.resolve().is_relative_to(base.resolve()):
        raise ValueError('Source variant evidence escapes its app directory')
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, 'rb') as stream:
        before = os.fstat(stream.fileno())
        if not stat.S_ISREG(before.st_mode) or before.st_size > limit:
            raise ValueError('Source variant evidence must be a bounded regular file')
        content = stream.read(limit + 1)
        after = os.fstat(stream.fileno())
    current = path.lstat()
    def identity(value):
        return (value.st_dev, value.st_ino, value.st_mode, value.st_size, value.st_mtime_ns, value.st_ctime_ns)
    if len(content) > limit or identity(before) != identity(after) or identity(after) != identity(current):
        raise ValueError('Source variant evidence changed while reading')
    return content, stat.S_IMODE(before.st_mode)


def upgrade_baseline_provenance(root, app, receipt, inventory):
    """Qualify an explicitly archived old source variant without certifying current source."""
    marker = app.parent / 'fixture-source-variant.json'
    encoded, _ = bounded_regular_file(app.parent, marker.name, 64 * 1024)
    value = json.loads(encoded)
    keys = {'schema', 'purpose', 'current_source_files_sha256', 'reference_source_files_sha256', 'changes'}
    if (not isinstance(value, dict) or set(value) != keys or type(value.get('schema')) is not int
            or value['schema'] != 1 or value['purpose'] != 'upgrade-baseline'):
        raise ValueError('Invalid upgrade baseline source variant')
    for key in ['current_source_files_sha256', 'reference_source_files_sha256']:
        if not isinstance(value[key], str) or re.fullmatch(r'[0-9a-f]{64}', value[key]) is None:
            raise ValueError('Invalid source variant inventory digest')
    reference = receipt.get('source_files')
    if not isinstance(reference, dict) or not reference:
        raise ValueError('Build receipt has no source file inventory')
    reference_digest = inventory.inventory_digest(reference)
    if (receipt.get('source_files_sha256') != reference_digest
            or value['reference_source_files_sha256'] != reference_digest):
        raise ValueError('Source variant reference does not match the build receipt inventory digest')
    current = inventory.inventory(root)
    if any(not isinstance(entry, dict) or entry.get('kind') == 'missing'
           for entry in [*reference.values(), *current.values()]):
        raise ValueError('Source variant cannot qualify missing source files')
    current_digest = inventory.inventory_digest(current)
    if value['current_source_files_sha256'] != current_digest:
        raise ValueError('Source variant current inventory digest does not match')
    changes = value['changes']
    if not isinstance(changes, dict) or not 1 <= len(changes) <= 16:
        raise ValueError('Source variant must record between 1 and 16 changed source files')
    changed = sorted(name for name in set(reference) | set(current) if reference.get(name) != current.get(name))
    if changed != sorted(changes):
        raise ValueError('Source variant changes do not match the exact source inventory delta')
    total = 0
    archives = {}
    for name in changed:
        old, new = reference.get(name), current.get(name)
        if (not isinstance(old, dict) or not isinstance(new, dict)
                or set(old) != {'kind', 'mode', 'sha256'} or set(new) != set(old)
                or old['kind'] != 'file' or new['kind'] != 'file'
                or old['mode'] != new['mode'] or old['sha256'] == new['sha256']):
            raise ValueError('Source variant requires existing regular files with content changes and unchanged modes')
        relative = changes[name]
        if not isinstance(relative, str) or not relative.startswith('baseline-source/'):
            raise ValueError('Source variant archives must be inside baseline-source')
        content, mode = bounded_regular_file(app.parent, relative, 8 * 1024 * 1024)
        total += len(content)
        if total > 32 * 1024 * 1024:
            raise ValueError('Source variant archives exceed the total size limit')
        archive_hash = hashlib.sha256(content).hexdigest()
        if mode != old['mode'] or archive_hash != old['sha256']:
            raise ValueError('Source variant archive does not match its reference source')
        archives[relative] = {'sha256': archive_hash, 'mode': mode}
    return {'purpose': 'upgrade-baseline', 'markerPath': str(marker),
            'markerSHA256': hashlib.sha256(encoded).hexdigest(), 'changedPaths': changed,
            'currentSourceFilesSHA256': current_digest, 'referenceSourceFilesSHA256': reference_digest,
            'archives': archives}


def local_vm_signing(app, receipt_path, receipt, tree_hash):
    sidecar_path = app.parent / 'vm-signing.json'
    if sidecar_path.is_symlink() or not sidecar_path.is_file():
        raise ValueError('VM signing sidecar must be a regular file')
    sidecar = json.loads(sidecar_path.read_text())
    keys = {'schema', 'build_receipt_sha256', 'unsigned_app_tree_sha256', 'signed_app_tree_sha256',
            'signing_identity', 'signing_purpose'}
    if (not isinstance(sidecar, dict) or set(sidecar) != keys or type(sidecar.get('schema')) is not int
            or sidecar['schema'] != 1 or sidecar['signing_purpose'] != 'local-vm-test'
            or not isinstance(sidecar['signing_identity'], str)
            or re.fullmatch(r'[0-9a-fA-F]{40}', sidecar['signing_identity']) is None):
        raise ValueError('Invalid local VM signing sidecar')
    if any(not isinstance(sidecar[key], str) or re.fullmatch(r'[0-9a-f]{64}', sidecar[key]) is None
           for key in ['build_receipt_sha256', 'unsigned_app_tree_sha256', 'signed_app_tree_sha256']):
        raise ValueError('Invalid VM signing hash')
    if (sidecar['build_receipt_sha256'] != digest(receipt_path)
            or sidecar['unsigned_app_tree_sha256'] != receipt.get('app_tree_sha256')
            or sidecar['signed_app_tree_sha256'] != tree_hash):
        raise ValueError('VM signing hash chain does not match the build receipt and selected app')
    spec = importlib.util.spec_from_file_location('vm_runtime_packaging', Path(__file__).with_name('package-runtime.py'))
    packaging = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(packaging)
    identity = sidecar['signing_identity'].upper()
    team = packaging.TEAM_IDENTIFIER
    requirement = f'anchor apple generic and certificate leaf[subject.OU] = "{team}" and certificate leaf = H"{identity}"'
    runtime = packaging.runtime_path(app)
    if not runtime.is_dir():
        raise ValueError('Signed VM app is missing its Slate runtime')
    commands = [
        ['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)],
        ['/usr/bin/codesign', '--verify', '--strict', '-R', '=' + requirement, str(app)],
        ['/usr/bin/codesign', '--verify', '--strict', '-R',
         '=' + requirement + f' and identifier "{packaging.RUNTIME_IDENTIFIER}"', str(runtime)],
    ]
    try:
        for command in commands:
            subprocess.run(command, check=True, capture_output=True, text=True)
    except subprocess.CalledProcessError as error:
        raise ValueError('Local VM signing verification failed: ' + (error.stderr or str(error)).strip()) from error
    return {'purpose': 'local-vm-test', 'identity': identity, 'teamIdentifier': team,
            'verification': 'codesign-deep-strict-and-publisher-requirement',
            'sidecarPath': str(sidecar_path), 'sidecarSHA256': digest(sidecar_path),
            'unsignedTreeSHA256': sidecar['unsigned_app_tree_sha256'], 'signedTreeSHA256': tree_hash}


def app_provenance(root, app, configuration=None, guest_path=APP_GUEST_PATH):
    """Describe the selected bytes without treating a prebuilt bundle as a build gate."""
    root = root.resolve()
    app = selected_app(root, app)
    info_path = app / 'Contents/Info.plist'
    with info_path.open('rb') as source:
        info = plistlib.load(source)
    for key in ['CFBundleExecutable', 'CFBundleIdentifier', 'CFBundleShortVersionString', 'CFBundleVersion']:
        if not isinstance(info.get(key), str) or not info[key]:
            raise ValueError('App bundle is missing ' + key)
    executable_name = info['CFBundleExecutable']
    if Path(executable_name).name != executable_name or executable_name in ('.', '..'):
        raise ValueError('Invalid app executable name')
    executable = app / 'Contents/MacOS' / executable_name
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise ValueError('App bundle executable is missing or not executable: ' + str(executable))
    tree_hash = app_tree_hash(app)
    result = {
        'hostPath': str(app), 'guestPath': guest_path,
        'configuration': configuration or 'unknown',
        'configurationEvidence': 'runner-debug-build' if configuration == 'Debug' else 'not-recorded',
        'bundleIdentifier': info['CFBundleIdentifier'],
        'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion'],
        'treeSHA256': tree_hash,
        'executable': {'hostPath': str(executable),
                       'guestPath': guest_path + '/Contents/MacOS/' + executable_name,
                       'sha256': digest(executable)},
        'buildInfo': {key: info[key] for key in ['BuildMachineOSBuild', 'DTCompiler', 'DTPlatformBuild',
                     'DTPlatformVersion', 'DTSDKBuild', 'DTSDKName', 'DTXcode', 'DTXcodeBuild'] if key in info},
        'sourceHashValidation': 'not-recorded',
    }
    receipt_path = app.parent / 'build-source.json'
    signing_path = app.parent / 'vm-signing.json'
    signing_present = signing_path.exists() or signing_path.is_symlink()
    variant_path = app.parent / 'fixture-source-variant.json'
    variant_present = variant_path.exists() or variant_path.is_symlink()
    if variant_present and (configuration is not None or not receipt_path.is_file()):
        raise ValueError('Source variant requires a prebuilt app and its original build-source.json receipt')
    if configuration is None and signing_present and not receipt_path.is_file():
        raise ValueError('VM signing sidecar requires its original build-source.json receipt')
    if configuration is None and receipt_path.is_symlink():
        raise ValueError('App build receipt must be a regular file, not a symlink')
    if configuration is None and receipt_path.is_file():
        receipt = json.loads(receipt_path.read_text())
        if receipt.get('version') != result['version'] or receipt.get('build_number') != result['build']:
            raise ValueError('Prebuilt app does not match its build-source.json receipt')
        if signing_present:
            result['signing'] = local_vm_signing(app, receipt_path, receipt, tree_hash)
        elif receipt.get('app_tree_sha256') != tree_hash:
            raise ValueError('Prebuilt app does not match its build-source.json receipt')
        recorded_configuration = receipt.get('configuration', 'Release')
        if recorded_configuration not in ('Debug', 'Release'):
            raise ValueError('Unknown configuration in app build receipt')
        result['configuration'] = recorded_configuration
        result['configurationEvidence'] = 'build-source.json'
        result['buildReceipt'] = {'hostPath': str(receipt_path), 'sha256': digest(receipt_path),
                                  'sourceCommit': receipt.get('source_commit'),
                                  'sourceDirty': receipt.get('source_dirty'),
                                  'ghosttyRevision': receipt.get('ghostty_revision')}
        spec = importlib.util.spec_from_file_location('release_source_inventory', Path(__file__).with_name('release-source-inventory.py'))
        inventory = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(inventory)
        if variant_present:
            result['sourceVariant'] = upgrade_baseline_provenance(root, app, receipt, inventory)
            result['sourceHashValidation'] = 'matched-explicit-upgrade-baseline'
        else:
            inventory.verify_receipt(root, receipt)
            result['sourceHashValidation'] = 'matched-build-receipt'
        result['buildReceipt']['sourceFilesSHA256'] = receipt['source_files_sha256']
    return result


def verify_native_links(directory, executable):
    """Gate-local @rpath dylibs must travel beside the executable, not host temp paths."""
    for path in [directory / executable, *directory.glob('*.dylib')]:
        output = subprocess.check_output(['otool', '-L', str(path)], text=True)
        for line in output.splitlines():
            if not line.startswith('\t'):
                continue
            library = line.strip().split(' (compatibility version', 1)[0]
            if library.startswith(('/System/', '/usr/lib/')):
                continue
            if library.startswith('@rpath/'):
                local = directory / library.removeprefix('@rpath/')
            elif library.startswith('@loader_path/'):
                local = directory / library.removeprefix('@loader_path/')
            else:
                raise RuntimeError('Nonportable native dependency: ' + str(path) + ' -> ' + library)
            if not local.is_file() or not local.resolve().is_relative_to(directory.resolve()):
                raise RuntimeError('Missing gate-local dependency: ' + str(local))


def stage_products(root, bundle, selected, package_bin=None, app=None, upgrade_apps=None):
    root, bundle = root.resolve(), bundle.resolve()
    guest_hashes, host_hashes = {}, {}

    def copy(source, relative):
        target = bundle / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        if source.is_dir():
            shutil.copytree(source, target, symlinks=True)
            files = [path for path in source.rglob('*') if path.is_file()]
        else:
            shutil.copy2(source, target)
            files = [source]
        for path in files:
            destination = target / path.relative_to(source) if source.is_dir() else target
            name = str(destination.relative_to(bundle))
            guest_hashes[name] = digest(destination)
            host_hashes[str(path.relative_to(root))] = digest(path)
            if guest_hashes[name] != host_hashes[str(path.relative_to(root))]:
                raise RuntimeError('Product changed while staging: ' + str(path))

    native = [gate for gate in selected if gate.native]
    for gate in native:
        directory = root / gate.native_directory
        verify_native_links(directory, gate.native.executable)
        # Modules, .dSYM and module-cache directories are compilation inputs, not runtime dependencies.
        products = [directory / gate.native.executable, *directory.glob('*.dylib')]
        manifest = directory / 'build-manifest.txt'
        if manifest.exists():
            products.append(manifest)
        for source in products:
            copy(source, str(source.relative_to(root)))
    def copy_app(source, destination, sidecar_prefix=None):
        source = selected_app(root, source)
        variant_path = source.parent / 'fixture-source-variant.json'
        variant = None
        if variant_path.exists() or variant_path.is_symlink():
            variant = app_provenance(root, source)['sourceVariant']
            if sidecar_prefix is None:
                raise ValueError('Source variants require explicit prebuilt app staging')
        before = app_tree_hash(source)
        copy(source, destination)
        if app_tree_hash(source) != before or app_tree_hash(bundle / destination) != before:
            raise RuntimeError('App bundle changed while staging')
        if sidecar_prefix is not None:
            for name, suffix in [('build-source.json', '-build-source.json'), ('vm-signing.json', '-signing.json')]:
                sidecar = source.parent / name
                if sidecar.is_symlink():
                    raise ValueError('App provenance sidecars must not be symlinks')
                if sidecar.is_file():
                    copy(sidecar, sidecar_prefix + suffix)
            if variant is not None:
                marker_destination = sidecar_prefix + '-fixture-source-variant.json'
                copy(variant_path, marker_destination)
                if guest_hashes[marker_destination] != variant['markerSHA256']:
                    raise RuntimeError('Source variant marker changed while staging')
                for relative, evidence in variant['archives'].items():
                    content, mode = bounded_regular_file(source.parent, relative, 8 * 1024 * 1024)
                    if hashlib.sha256(content).hexdigest() != evidence['sha256'] or mode != evidence['mode']:
                        raise RuntimeError('Source variant archive changed while staging')
                    target = sidecar_prefix + '-' + relative
                    copy(source.parent / relative, target)
                    if (guest_hashes[target] != evidence['sha256']
                            or stat.S_IMODE((bundle / target).stat().st_mode) != evidence['mode']):
                        raise RuntimeError('Source variant archive changed while staging')

    if any(gate.requires_app for gate in selected):
        copy_app(app or root / APP_GUEST_PATH, APP_GUEST_PATH, '.vm-app' if app is not None else None)
    for role, source in (upgrade_apps or {}).items():
        destination, _ = UPGRADE_APPS[role]
        copy_app(source, destination, '.vm-fixtures/' + role)
    if any(gate.native and gate.native.ghostty for gate in selected):
        copy(root / '.build/bootstrap/ghostty/zig-out/share/ghostty', '.build/bootstrap/ghostty/zig-out/share/ghostty')
    if any(gate.native and gate.native.cli for gate in selected):
        if package_bin is None:
            raise RuntimeError('Package CLI directory is required by selected native gates')
        copy(package_bin / 'slate-term', '.build/vm-support/slate-term')
    if any(gate.name in ('shell-hooks', 'shells') for gate in selected):
        # Built on the host by scripts/build-test-shells.sh; the guest has only Apple's bash 3.2.
        shells = root / '.build/test-shells'
        for name, executable in [('bash-5.2', 'bash'), ('bash-5.3', 'bash'), ('fish-4', 'fish')]:
            source = shells / name / executable
            if not source.is_file():
                if name == 'fish-4' and os.environ.get('SLATE_TEST_SHELLS_WITHOUT_FISH') == '1':
                    # An explicit, visible opt-out; the guest gates report it instead of passing silently.
                    marker = bundle / '.build/test-shells/WITHOUT_FISH'
                    marker.parent.mkdir(parents=True, exist_ok=True)
                    marker.write_text('fish was not built for this run\n')
                    continue
                raise RuntimeError('Missing test shell ' + str(source) + '; run scripts/build-test-shells.sh')
            copy(source, str(source.relative_to(root)))
    if any(gate.name == 'web' for gate in selected):
        copy(root / '.build/vm-tests/check-screenshot', '.build/vm-tests/check-screenshot')
    return guest_hashes, host_hashes
