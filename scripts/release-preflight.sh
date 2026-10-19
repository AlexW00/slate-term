#!/bin/bash
# Cheap checks before creating an immutable release tag. No build or publication.
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v shellcheck >/dev/null 2>&1; then
  echo 'Release preflight requires ShellCheck on PATH.' >&2
  exit 1
fi
python3 scripts/security-scan.py --include-untracked
python3 -m unittest discover -s Tests/Release -v
python3 -m unittest discover -s Tests/VMRunner -v
python3 scripts/check-workflows.py
