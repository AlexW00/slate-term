"""Copy only runnable products/resources; no SDKs, compiler caches or guest builds."""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


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


def stage_products(root, bundle, selected, package_bin=None):
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
    if any(gate.requires_app for gate in selected):
        copy(root / '.derived/Build/Products/Debug/Slate Terminal.app', '.derived/Build/Products/Debug/Slate Terminal.app')
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
