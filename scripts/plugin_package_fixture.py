"""TEST ONLY: author ZIP packages from integration fixture manifests and resources.

Call this at fixture construction/registration sites, never in an RPC transport.
Only fixture-owned static roots, working directories and script arguments are
relocated. External executables, signal/output arguments and environments stay
literal. The returned ZIP is a snapshot; changing authoring files does not change
an installed package. Tests injecting runtime faults must use its packageRoot.
"""
import copy
import json
import pathlib
import stat
import uuid
import zipfile


def package_fixture(manifest, root):
    """Return an absolute ZIP path, with a portable root plugin.json.

    ``manifest`` is a fixture dict or a fixture JSON file. ``root`` owns generated
    archives and is the fixture's former default working directory. Script-file
    arguments beneath root are bundled; other arguments (including directories
    used for external IPC/output) are intentionally not rewritten.
    """
    root = pathlib.Path(root).absolute()
    if isinstance(manifest, (str, pathlib.Path)):
        manifest = json.loads(pathlib.Path(manifest).read_text())
    portable = copy.deepcopy(manifest)
    entries = {}
    relocated = {}

    def add(path, destination):
        path = pathlib.Path(path)
        if path.is_symlink():
            raise ValueError(f'Fixture package cannot contain a symlink: {path}')
        if path.is_dir():
            entries[destination + '/'] = None
            for child in sorted(path.iterdir()):
                add(child, destination + '/' + child.name)
        elif path.is_file():
            entries[destination] = path
        else:
            raise ValueError(f'Fixture package resource is not a regular file/directory: {path}')

    def bundle(path, category):
        path = pathlib.Path(path).absolute()
        for original, destination in relocated.items():
            if path == original or original.is_dir() and path.is_relative_to(original):
                suffix = path.relative_to(original).as_posix()
                return destination if suffix == '.' else destination + '/' + suffix
        if not path.is_relative_to(root):
            raise ValueError(f'Not a fixture-owned resource beneath {root}: {path}')
        destination = category + '/' + str(len(relocated)) + '-' + path.name
        add(path, destination)
        relocated[path] = destination
        return destination

    source = portable.get('source', {})
    if source.get('kind') == 'directory' and pathlib.Path(source['path']).is_absolute():
        source['path'] = bundle(source['path'], 'web')

    specs = [portable[key] for key in ('process', 'service') if key in portable]
    specs += portable.get('commands', [])
    for spec in specs:
        directory = spec.get('directory')
        if directory and pathlib.Path(directory).is_absolute():
            spec['directory'] = '.' if pathlib.Path(directory).absolute() == root else bundle(directory, 'work')
        arguments = spec.get('arguments', [])
        for index, argument in enumerate(arguments):
            path = pathlib.Path(argument)
            # Do not infer resources from arbitrary absolute data/output paths.
            if (path.is_absolute() and path.is_relative_to(root)
                    and path.suffix in ('.py', '.sh', '.js', '.mjs') and path.is_file()):
                arguments[index] = '{pluginRoot}/' + bundle(path, 'scripts')
        executable = spec.get('executable', '')
        path = pathlib.Path(executable)
        if path.is_absolute() and path.is_relative_to(root) and path.is_file():
            spec['executable'] = './' + bundle(path, 'bin')

    output = root / 'fixture-packages'
    output.mkdir(exist_ok=True)
    archive = output / (str(uuid.uuid4()) + '.zip')
    with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED) as package:
        package.writestr('plugin.json', json.dumps(portable))
        for destination, path in sorted(entries.items()):
            info = zipfile.ZipInfo(destination)
            info.create_system = 3
            mode = (stat.S_IFDIR | 0o700) if path is None else (stat.S_IFREG | 0o600 | (path.stat().st_mode & 0o100))
            info.external_attr = mode << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            package.writestr(info, b'' if path is None else path.read_bytes())
    return str(archive)
