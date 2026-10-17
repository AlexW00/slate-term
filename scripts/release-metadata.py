#!/usr/bin/env python3
"""Validate a release tag before allocating a signing runner."""
import argparse
import os
from pathlib import Path
import re
import subprocess
import sys


class ReleaseError(Exception):
    pass


def git(*args):
    result = subprocess.run(['git', *args], text=True, capture_output=True)
    if result.returncode:
        raise ReleaseError('Release Git validation failed; the tag and default branch must be fetched.')
    return result.stdout.strip()


def validate(tag, default_branch):
    if not re.fullmatch(r'v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)', tag):
        raise ReleaseError('Use a release tag such as v0.1.0 (no prerelease or shell syntax).')
    subprocess.run(['git', 'check-ref-format', 'refs/heads/' + default_branch], check=True, capture_output=True)
    commit = git('rev-parse', '--verify', 'refs/tags/' + tag + '^{commit}')
    if commit != git('rev-parse', 'HEAD'):
        raise ReleaseError('The checkout must match the selected release tag.')
    result = subprocess.run(['git', 'merge-base', '--is-ancestor', commit, 'refs/remotes/origin/' + default_branch], capture_output=True)
    if result.returncode:
        raise ReleaseError('Release tags must point to a commit on the default branch.')
    if git('status', '--porcelain', '--untracked-files=normal'):
        raise ReleaseError('Release builds require a clean source checkout.')
    for name in ('LICENSE', 'COPYING.md', 'THIRD_PARTY_NOTICES.md'):
        if not Path(name).is_file():
            raise ReleaseError('Required license files are missing.')
    return {'tag': tag, 'version': tag[1:], 'commit': commit}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--default-branch', required=True)
    args = parser.parse_args()
    metadata = validate(args.tag, args.default_branch)
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
            for key, value in metadata.items():
                output.write(f'{key}={value}\n')
    print('Validated release ' + metadata['tag'] + ' at ' + metadata['commit'])


if __name__ == '__main__':
    try:
        main()
    except (ReleaseError, subprocess.CalledProcessError) as error:
        print(str(error) if isinstance(error, ReleaseError) else 'Invalid default branch.', file=sys.stderr)
        sys.exit(1)
