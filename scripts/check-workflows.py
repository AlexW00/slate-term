#!/usr/bin/env python3
"""Validate GitHub Actions with a checksum-pinned actionlint executable."""
import hashlib
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

VERSION = '1.7.12'
ARCHIVES = {
    ('Darwin', 'arm64'): ('darwin_arm64', 'aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f'),
    ('Linux', 'x86_64'): ('linux_amd64', '8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8'),
}


def main():
    root = Path(__file__).resolve().parents[1]
    asset, expected = ARCHIVES[(platform.system(), platform.machine())]
    directory = root / '.tools' / ('actionlint-' + VERSION)
    directory.mkdir(parents=True, exist_ok=True)
    binary = directory / 'actionlint'
    marker = directory / 'binary.sha256'
    valid = binary.is_file() and marker.is_file() and hashlib.sha256(binary.read_bytes()).hexdigest() == marker.read_text().strip()
    if not valid:
        with tempfile.TemporaryDirectory(dir=directory) as temp:
            archive = Path(temp) / 'download.tar.gz'
            url = f'https://github.com/rhysd/actionlint/releases/download/v{VERSION}/actionlint_{VERSION}_{asset}.tar.gz'
            with urllib.request.urlopen(url, timeout=60) as response, archive.open('wb') as output:
                shutil.copyfileobj(response, output)
            if hashlib.sha256(archive.read_bytes()).hexdigest() != expected:
                raise RuntimeError('actionlint archive checksum mismatch')
            with tarfile.open(archive) as source:
                member = source.getmember('actionlint')
                if not member.isfile():
                    raise RuntimeError('Unexpected actionlint archive contents')
                with source.extractfile(member) as content, binary.open('wb') as output:
                    shutil.copyfileobj(content, output)
            binary.chmod(0o755)
            marker.write_text(hashlib.sha256(binary.read_bytes()).hexdigest() + '\n')
    command = [str(binary), '-color']
    if shutil.which('shellcheck') is None:
        command += ['-shellcheck=']
        print('ShellCheck is unavailable; actionlint still validates workflow structure and expressions.', flush=True)
    return subprocess.run(command, cwd=root).returncode


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (KeyError, OSError, RuntimeError, tarfile.TarError) as error:
        print('Workflow validation could not complete: ' + str(error), file=sys.stderr)
        sys.exit(2)
